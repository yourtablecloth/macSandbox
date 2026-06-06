// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (C) 2026 Nam Jung Hyun (rkttu) <rkttu.official@gmail.com>
//
// This file is part of MacSandbox, which is dual-licensed:
//   (1) under the GNU General Public License v3.0 or later (see LICENSE), or
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
@MainActor
final class SandboxRunner: ObservableObject {

    @Published private(set) var isRunning = false
    @Published private(set) var status: String = "대기"
    @Published private(set) var log: String = ""
    @Published var console: VMConsole?
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
            status = "사용 가능한 베이스라인이 없습니다."
            return
        }
        activeConfig = config
        isRunning = true
        log = ""
        defer { isRunning = false }

        let id = String(UUID().uuidString.prefix(8))
        let overlayPath = SandboxPaths.overlaysDir.appendingPathComponent("\(id).qcow2").path
        let efiVarsPath = SandboxPaths.overlaysDir.appendingPathComponent("\(id)-efi.fd").path
        var configDiskPath: String?

        do {
            try SandboxPaths.ensureBaseDirectories()
            cleanStaleOverlays()   // 이전 강제종료로 남은 일회용 오버레이 정리(단일 인스턴스 전제)

            // 1. COW 오버레이 + 신선한 UEFI 변수
            status = "샌드박스 디스크 준비..."
            try disk.createOverlay(basePath: meta.diskPath, overlayPath: overlayPath)
            guard let efiCode = SandboxPaths.edk2CodeFirmware(),
                  let varsTemplate = SandboxPaths.edk2VarsTemplate() else {
                throw BuildError.installFailed("UEFI 펌웨어를 찾을 수 없습니다.")
            }
            try fm.copyItem(atPath: varsTemplate.path, toPath: efiVarsPath)
            appendLog("COW 오버레이: \(overlayPath)")

            // 2. (선택) 설정 디스크 — LogonCommand 전달
            if !config.logonCommand.isEmpty {
                let path = SandboxPaths.overlaysDir.appendingPathComponent("\(id)-cfg.img").path
                try makeConfigDisk(logonCommand: config.logonCommand, at: path)
                configDiskPath = path
                appendLog("설정 디스크(LogonCommand): \(path)")
            }

            // 3. QEMU 실행 (부팅 모니터링용 VNC 콘솔) + RDP 포트포워딩
            status = "샌드박스 부팅 중"
            let qmpSocket = "/tmp/msbx-run-\(id).sock"
            let port = RDPSession.reserveLocalPort()
            self.rdpPort = port
            let args = runtime.buildSandboxArguments(
                overlayPath: overlayPath, efiCodePath: efiCode.path, efiVarsPath: efiVarsPath,
                config: config, configDiskPath: configDiskPath, rdpHostPort: port, qmpSocketPath: qmpSocket)
            appendLog("RDP 포워딩: 127.0.0.1:\(port) → 게스트 3389")

            let console = VMConsole(socketPath: qmpSocket, capturesFrames: true)
            self.console = console
            console.start()

            // QEMU를 백그라운드로 실행한다. 게스트 RDP는 인앱 임베드 뷰(RDPHostView)가
            // rdpPort로 연결해 렌더한다(외부 FreeRDP 창 없음). 임베드 엔진이 게스트 부팅을
            // 기다리며 연결을 재시도하므로 별도의 RDP 런처는 필요 없다.
            status = "샌드박스 부팅 중 (인앱 RDP 연결 대기)"
            let qemuTask = Task { () -> Int32 in
                try await self.runtime.runUntilExit(
                    arguments: args, qmpSocketPath: qmpSocket, timeoutSeconds: 24 * 60 * 60
                ) { [weak self] out in
                    Task { @MainActor in self?.appendLog(out) }
                }
            }

            // 샌드박스는 사용자가 종료하거나 게스트가 종료될 때까지 실행
            let exit = (try? await qemuTask.value) ?? -1
            console.stop()
            self.console = nil
            self.rdpPort = 0
            appendLog("QEMU 종료 (exit=\(exit))")
            status = "종료됨"
        } catch {
            console?.stop()
            console = nil
            status = "실패: \(error.localizedDescription)"
            appendLog("❌ \(error.localizedDescription)")
        }

        // 4. 일회용 정리
        if config.disposable {
            try? fm.removeItem(atPath: overlayPath)
            try? fm.removeItem(atPath: efiVarsPath)
            if let configDiskPath { try? fm.removeItem(atPath: configDiskPath) }
            appendLog("일회용: 오버레이/변수/설정 디스크 삭제됨")
        }
    }

    /// 샌드박스 종료 (disposable이므로 강제 종료해도 무방)
    func stop() {
        runtime.forceStop()
        appendLog("종료 요청")
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

    /// LogonCommand를 담은 작은 FAT16 설정 디스크 생성 (베이스라인 로그온 에이전트가 읽음)
    private func makeConfigDisk(logonCommand: String, at path: String) throws {
        if fm.fileExists(atPath: path) { try fm.removeItem(atPath: path) }
        guard fm.createFile(atPath: path, contents: nil) else {
            throw BuildError.installFailed("설정 디스크 생성 실패")
        }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.truncate(atOffset: 8 * 1024 * 1024)
        try handle.close()

        let dev = try shellCapture("/usr/bin/hdiutil",
            ["attach", "-nomount", "-imagekey", "diskimage-class=CRawDiskImage", path])
            .split(separator: "\n").first.flatMap { $0.split(separator: " ").first.map(String.init) } ?? ""
        guard dev.hasPrefix("/dev/") else { throw BuildError.installFailed("설정 디스크 attach 실패") }
        defer { _ = try? shell("/usr/bin/hdiutil", ["detach", "-force", dev]) }

        try shell("/sbin/newfs_msdos", ["-F", "16", "-v", "MSBXCFG", dev])
        _ = try shellCapture("/usr/sbin/diskutil", ["mount", dev])
        let info = try shellCapture("/usr/sbin/diskutil", ["info", dev])
        guard let mp = info.split(separator: "\n").first(where: { $0.contains("Mount Point") })?
            .split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces), !mp.isEmpty else {
            throw BuildError.installFailed("설정 디스크 마운트 실패")
        }
        let script = "@echo off\r\n\(logonCommand)\r\n"
        try script.write(toFile: (mp as NSString).appendingPathComponent("macsandbox-logon.cmd"),
                         atomically: true, encoding: .utf8)
        _ = try? shellCapture("/usr/sbin/diskutil", ["unmount", dev])
    }

    private func shell(_ path: String, _ args: [String]) throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        p.standardError = Pipe(); p.standardOutput = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
    }

    private func shellCapture(_ path: String, _ args: [String]) throws -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private func appendLog(_ m: String) {
        let t = m.trimmingCharacters(in: .newlines)
        guard !t.isEmpty else { return }
        log += t + "\n"
    }
}

extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }
}
