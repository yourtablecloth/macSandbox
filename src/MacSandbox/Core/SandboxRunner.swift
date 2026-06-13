// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Copyright (C) 2026 Nam Jung Hyun (rkttu)
//
// This file is part of MacSandbox, which is dual-licensed:
//   (1) under the GNU Affero General Public License v3.0 or later (see LICENSE), or
//   (2) under a commercial license (see COMMERCIAL-LICENSE.md).
// You may use this file under the terms of either license.
//
// MacSandbox is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE.

import Foundation

/// 일회용 샌드박스 실행 오케스트레이터.
///
/// 베이스라인 → COW 오버레이 + 신선한 UEFI 변수 → (설정 디스크) → QEMU 부팅 →
/// 사용자 사용 → 종료 시 disposable이면 오버레이/변수/설정디스크 폐기.
/// 샌드박스 실행 상태. 뷰 라우팅/표시는 문자열 비교가 아닌 이 enum으로 판단한다(i18n 안전).
enum SandboxRunState: Equatable {
    case idle
    case preparing
    case booting
    case ended
    case failed(String)

    var label: String {
        switch self {
        case .idle: return L("run.state.idle")
        case .preparing: return L("run.state.preparing")
        case .booting: return L("run.state.booting")
        case .ended: return L("run.state.ended")
        case .failed(let reason): return L("run.state.failed", reason)
        }
    }
}

@MainActor
final class SandboxRunner: ObservableObject {

    @Published private(set) var isRunning = false
    @Published private(set) var state: SandboxRunState = .idle
    /// 부팅 시작 시각(경과 시간 표시용). booting 진입 시 설정.
    @Published private(set) var bootStartedAt: Date?
    @Published var console: VMConsole?
    /// 로그는 별도 스로틀링 스토어 — 러너를 관찰하는 뷰가 로그 줄마다 재렌더되지 않게 분리.
    let logBuffer = LogBuffer()

    var status: String { state.label }
    /// 현재 RDP 포워딩 포트(127.0.0.1:rdpPort → 게스트 3389). 0이면 미설정.
    /// 인앱 임베드 RDP 뷰(RDPHostView)가 이 포트로 연결한다.
    @Published private(set) var rdpPort: Int = 0
    /// 현재 실행 중 구성(.wsb 반영). RDP 뷰가 리다이렉션 기능 게이팅에 사용.
    @Published private(set) var activeConfig = SandboxConfig()

    private let disk = DiskService()
    private let runtime = QEMURuntime()
    private let fm = FileManager.default

    func hasBaseline() -> Bool {
        guard let data = try? Data(contentsOf: SandboxPaths.baselineMetadataPath),
              let meta = try? JSONDecoder.iso8601.decode(BaselineMetadata.self, from: data) else { return false }
        return meta.status == .ready && fm.fileExists(atPath: meta.diskPath)
    }

    // MARK: - 실행

    func start(config: SandboxConfig) async {
        guard !isRunning else { return }
        guard let data = try? Data(contentsOf: SandboxPaths.baselineMetadataPath),
              let meta = try? JSONDecoder.iso8601.decode(BaselineMetadata.self, from: data),
              meta.status == .ready else {
            state = .failed(L("run.state.noBaseline"))
            return
        }
        activeConfig = config
        isRunning = true
        logBuffer.clear()
        defer { isRunning = false }

        let id = String(UUID().uuidString.prefix(8))
        let overlayPath = SandboxPaths.overlaysDir.appendingPathComponent("\(id).qcow2").path
        let efiVarsPath = SandboxPaths.overlaysDir.appendingPathComponent("\(id)-efi.fd").path
        var configDiskPath: String?

        do {
            try SandboxPaths.ensureBaseDirectories()
            cleanStaleOverlays()   // 이전 강제종료로 남은 일회용 오버레이 정리(단일 인스턴스 전제)

            // 1. COW 오버레이 + 신선한 UEFI 변수 (qemu-img — 메인 스레드 밖에서)
            state = .preparing
            let diskService = disk
            let basePath = meta.diskPath
            try await Task.detached(priority: .userInitiated) {
                try diskService.createOverlay(basePath: basePath, overlayPath: overlayPath)
            }.value
            guard let efiCode = SandboxPaths.edk2CodeFirmware(),
                  let varsTemplate = SandboxPaths.edk2VarsTemplate() else {
                throw BuildError.installFailed(L("error.firmwareNotFound"))
            }
            try fm.copyItem(atPath: varsTemplate.path, toPath: efiVarsPath)
            appendLog("COW overlay: \(overlayPath)")

            // 2. (선택) 설정 디스크 — 공유 폴더 자동 마운트(mklink) + LogonCommand 전달.
            //    hdiutil/newfs/diskutil 동기 작업(수 초) — 메인 스레드 밖에서.
            if !config.logonCommand.isEmpty || !config.mappedFolders.isEmpty {
                let path = SandboxPaths.overlaysDir.appendingPathComponent("\(id)-cfg.img").path
                let script = buildLogonScript(config: config)
                try await Task.detached(priority: .userInitiated) {
                    try Self.makeConfigDisk(script: script, at: path)
                }.value
                configDiskPath = path
                appendLog("Config disk: \(config.mappedFolders.count) mount(s), logon command \(config.logonCommand.isEmpty ? "absent" : "present")")
            }

            // 3. QEMU 실행 (부팅 모니터링용 VNC 콘솔) + RDP 포트포워딩
            state = .booting
            bootStartedAt = Date()
            let qmpSocket = "/tmp/msbx-run-\(id).sock"
            let port = RDPSession.reserveLocalPort()
            self.rdpPort = port
            let args = runtime.buildSandboxArguments(
                overlayPath: overlayPath, efiCodePath: efiCode.path, efiVarsPath: efiVarsPath,
                config: config, configDiskPath: configDiskPath, rdpHostPort: port, qmpSocketPath: qmpSocket)
            appendLog("RDP forwarding: 127.0.0.1:\(port) → guest 3389")

            let console = VMConsole(socketPath: qmpSocket, capturesFrames: true)
            self.console = console
            console.start()

            // QEMU를 백그라운드로 실행한다. 게스트 RDP는 인앱 임베드 뷰(RDPHostView)가
            // rdpPort로 연결해 렌더한다(외부 FreeRDP 창 없음). 임베드 엔진이 게스트 부팅을
            // 기다리며 연결을 재시도하므로 별도의 RDP 런처는 필요 없다.
            let qemuTask = Task { () -> Int32 in
                try await self.runtime.runUntilExit(
                    arguments: args, qmpSocketPath: qmpSocket, timeoutSeconds: 24 * 60 * 60
                ) { [weak self] out in
                    let me = self
                    Task { @MainActor in me?.appendLog(out) }
                }
            }

            // 샌드박스는 사용자가 종료하거나 게스트가 종료될 때까지 실행
            let exit = (try? await qemuTask.value) ?? -1
            console.stop()
            self.console = nil
            self.rdpPort = 0
            appendLog("QEMU exited (exit=\(exit))")
            state = .ended
        } catch {
            console?.stop()
            console = nil
            state = .failed(error.localizedDescription)
            appendLog("❌ \(error.localizedDescription)")
        }
        bootStartedAt = nil

        // 4. 일회용 정리
        if config.disposable {
            try? fm.removeItem(atPath: overlayPath)
            try? fm.removeItem(atPath: efiVarsPath)
            if let configDiskPath { try? fm.removeItem(atPath: configDiskPath) }
            appendLog("Disposable: overlay/vars/config disk removed")
        }
    }

    /// 샌드박스 종료 (disposable이므로 강제 종료해도 무방)
    func stop() {
        runtime.forceStop()
        appendLog("Stop requested")
    }

    // MARK: - Private

    /// 일회용 오버레이 디렉토리의 잔류 파일 정리. 앱이 강제종료/크래시되면 정상 정리 코드가
    /// 못 돌아 오버레이가 남으므로(워치독은 QEMU만 죽임), 다음 시작 때 비운다(단일 인스턴스 전제).
    private func cleanStaleOverlays() {
        let dir = SandboxPaths.overlaysDir
        guard let items = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        for item in items {
            try? fm.removeItem(atPath: dir.appendingPathComponent(item).path)
        }
    }

    /// 베이스라인 로그온 에이전트가 실행할 macsandbox-logon.cmd 본문 생성.
    /// 공유 폴더를 게스트에 마운트(mklink /D 바탕화면\리프 또는 SandboxFolder → \\tsclient\드라이브)한 뒤
    /// 사용자 LogonCommand를 실행한다(Windows Sandbox와 동일 순서: 폴더 매핑 → 로그온 명령).
    private func buildLogonScript(config: SandboxConfig) -> String {
        let mounts = config.resolvedMounts()
        var lines = ["@echo off"]
        for m in mounts {
            lines.append("call :mount \"\(m.driveName)\" \"\(m.guestLinkPath)\"")
        }
        if !config.logonCommand.isEmpty { lines.append(config.logonCommand) }
        if !mounts.isEmpty {
            // 서브루틴: rdpdr 드라이브가 준비될 때까지 대기 후 심볼릭 링크 생성(local→remote 심링크 평가는 기본 허용).
            lines += [
                "goto :eof", "",
                ":mount", "setlocal",
                "set \"SRC=\\\\tsclient\\%~1\"",
                "set /a n=0",
                ":w",
                "if exist \"%SRC%\\\" goto :l",
                "set /a n+=1",
                "if %n% geq 20 goto :e",
                "ping -n 2 127.0.0.1 >nul",
                "goto :w",
                ":l",
                // 심링크 우선(개발자 모드면 비상승도 가능 → 폴더처럼 마운트). 실패 시 바로가기(.lnk) 폴백.
                "if not exist \"%~2\" if not exist \"%~2.lnk\" mklink /D \"%~2\" \"%SRC%\" >nul 2>&1",
                "if not exist \"%~2\" if not exist \"%~2.lnk\" powershell -NoProfile -Command \"$s=(New-Object -ComObject WScript.Shell).CreateShortcut('%~2.lnk');$s.TargetPath='%SRC%';$s.Save()\"",
                ":e", "endlocal", "goto :eof",
            ]
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// 로그온 스크립트를 담은 작은 FAT16 설정 디스크 생성 (베이스라인 로그온 에이전트가 읽음).
    /// 셸 도구(hdiutil/newfs/diskutil)만 쓰는 순수 함수 — 백그라운드 태스크에서 호출된다.
    nonisolated private static func makeConfigDisk(script: String, at path: String) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) { try fm.removeItem(atPath: path) }
        guard fm.createFile(atPath: path, contents: nil) else {
            throw BuildError.installFailed("Failed to create config disk")
        }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.truncate(atOffset: 8 * 1024 * 1024)
        try handle.close()

        let dev = try shellCapture("/usr/bin/hdiutil",
            ["attach", "-nomount", "-imagekey", "diskimage-class=CRawDiskImage", path])
            .split(separator: "\n").first.flatMap { $0.split(separator: " ").first.map(String.init) } ?? ""
        guard dev.hasPrefix("/dev/") else { throw BuildError.installFailed("Failed to attach config disk") }
        defer { _ = try? shell("/usr/bin/hdiutil", ["detach", "-force", dev]) }

        try shell("/sbin/newfs_msdos", ["-F", "16", "-v", "MSBXCFG", dev])
        _ = try shellCapture("/usr/sbin/diskutil", ["mount", dev])
        let info = try shellCapture("/usr/sbin/diskutil", ["info", dev])
        guard let mp = info.split(separator: "\n").first(where: { $0.contains("Mount Point") })?
            .split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces), !mp.isEmpty else {
            throw BuildError.installFailed("Failed to mount config disk")
        }
        try script.write(toFile: (mp as NSString).appendingPathComponent("macsandbox-logon.cmd"),
                         atomically: true, encoding: .utf8)
        _ = try? shellCapture("/usr/sbin/diskutil", ["unmount", dev])
    }

    nonisolated private static func shell(_ path: String, _ args: [String]) throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        p.standardError = Pipe(); p.standardOutput = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
    }

    nonisolated private static func shellCapture(_ path: String, _ args: [String]) throws -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private func appendLog(_ m: String) {
        logBuffer.append(m)
    }
}

extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }
}
