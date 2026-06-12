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
import Darwin

/// FreeRDP(sdl-freerdp) 기반 샌드박스 상호작용 세션.
///
/// RDP 하이브리드: 부팅 모니터링은 VNC 콘솔로, 사용자 상호작용은 FreeRDP 창으로 한다.
/// FreeRDP가 폴더 공유(`/drive`)·클립보드(`+clipboard`)·마이크(`/microphone`)·
/// 프린터(`/printer`)·오디오 출력(`/sound`) 리다이렉션을 제공한다.
/// (웹캠 리다이렉션은 이 FreeRDP 빌드에서 미지원 — RDPECAM 채널 없음.)
@MainActor
final class RDPSession {

    private var process: Process?
    private(set) var port: Int = 0

    /// 게스트 RDP 서버 로그온 계정(베이스라인이 WDAGUtilityAccount 자동 로그온/RDP 허용으로 구성됨)
    static let user = "WDAGUtilityAccount"

    // MARK: - 포트 예약

    /// 127.0.0.1에서 바인드 가능한(사용 가능한) TCP 포트를 찾는다. 기본 13389부터 탐색.
    static func reserveLocalPort(preferred: Int = 13389) -> Int {
        for candidate in preferred..<(preferred + 64) {
            if isPortFree(candidate) { return candidate }
        }
        return preferred
    }

    private static func isPortFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bound == 0
    }

    // MARK: - 인자 빌드

    /// SandboxConfig → FreeRDP 인자. blank-password RDP(NLA off)로 자동 로그온한다.
    static func buildArgs(config: SandboxConfig, port: Int) -> [String] {
        var args: [String] = []
        args.append("/v:127.0.0.1:\(port)")
        args.append("/u:\(SandboxCreds.username)")
        args.append("/p:\(SandboxCreds.password)")  // 고정 내부 암호 — 신뢰성 있는 credential auto-logon
        args.append("/sec:tls")             // TLS 보안 — 서버가 RDP-only는 SSL_REQUIRED로 거부, NLA는 우회
        args.append("/cert:ignore")
        // 고정 크기 창으로 띄운다. /dynamic-resolution은 SDL 클라이언트에서 디스플레이 전체 크기로
        // 열렸다가 축소되는 전체화면 전환을 유발하므로 쓰지 않는다. +smart-sizing으로 창 리사이즈 시 스케일.
        args.append("/w:1440")
        args.append("/h:900")
        args.append("+smart-sizing")
        args.append("/title:MacSandbox")

        // 클립보드
        if config.clipboardEnabled { args.append("+clipboard") } else { args.append("-clipboard") }

        // 공유 폴더 — 각 매핑을 named drive로. 게스트에서 \\tsclient\<name> 또는 리다이렉트 드라이브로 보임.
        for (idx, folder) in config.mappedFolders.enumerated() where !folder.hostPath.isEmpty {
            let name = shareName(for: folder, index: idx)
            args.append("/drive:\(name),\(folder.hostPath)")
        }

        // 마이크(오디오 입력) + 오디오 출력
        if config.audioInputEnabled {
            args.append("/microphone")
            args.append("/sound")
        }

        // 프린터 리다이렉트
        if config.printerEnabled { args.append("/printer") }

        return args
    }

    /// 매핑 폴더의 RDP 공유 이름 (게스트에서 보일 이름). 호스트 폴더명 기반, 충돌 시 인덱스 부가.
    private static func shareName(for folder: MappedFolder, index: Int) -> String {
        let base = (folder.hostPath as NSString).lastPathComponent
        let cleaned = base.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
        return cleaned.isEmpty ? "Shared\(index + 1)" : cleaned
    }

    // MARK: - 실행

    private var stopped = false

    /// FreeRDP를 한 번 실행하고 종료 코드를 반환한다(프로세스 종료까지 await).
    /// - onConnected: 실제 RDP 세션이 확립된 시점(동적 채널 로드)에 1회 호출. 부팅 화면→RDP 전환 신호.
    func run(config: SandboxConfig, port: Int,
             onLog: @escaping (String) -> Void,
             onConnected: (() -> Void)? = nil) async throws -> Int32 {
        guard let bin = SandboxPaths.freerdpBinary() else {
            throw BuildError.installFailed("FreeRDP (sdl-freerdp) not found. Run `brew install freerdp` and try again.")
        }
        self.port = port
        let args = Self.buildArgs(config: config, port: port)
        onLog("FreeRDP: \(bin.lastPathComponent) \(args.joined(separator: " "))")

        let proc = Process()
        proc.executableURL = bin
        proc.arguments = args
        let out = Pipe(); let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        // 세션 확립 감지: 동적 가상 채널 로드(rdpgfx 등) 라인이 보이면 연결된 것으로 간주.
        let connected = OneShotFlag()
        let sink: (String) -> Void = { t in
            onLog("[rdp] \(t)")
            if let onConnected,
               t.contains("Loading Dynamic Virtual Channel") || t.contains("rdpgfx") {
                if connected.set() { onConnected() }
            }
        }
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty, let s = String(data: d, encoding: .utf8) {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { sink(t) }
            }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty, let s = String(data: d, encoding: .utf8) {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { sink(t) }
            }
        }

        self.process = proc
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
            let once = OneShotFlag()
            proc.terminationHandler = { p in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                if once.set() { cont.resume(returning: p.terminationStatus) }
            }
            do {
                try proc.run()
            } catch {
                if once.set() { cont.resume(throwing: error) }
            }
        }
    }

    /// FreeRDP 창 강제 종료. 이후 재시도 루프가 멈추도록 stopped 플래그를 세운다.
    func stop() {
        stopped = true
        process?.terminate()
        process = nil
    }

    var isStopped: Bool { stopped }
    var isRunning: Bool { process?.isRunning ?? false }
}
