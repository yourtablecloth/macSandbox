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
import Darwin

/// QMP(QEMU Machine Protocol) Unix 소켓으로 게스트에 키보드/마우스 입력을 주입하는 클라이언트.
///
/// 설치 중 "Press any key to boot from CD or DVD..." 같이 키 입력이 필요한 순간을 자동 처리하거나,
/// 필요 시 임의의 키/마우스 이벤트를 보낼 수 있다.
final class QMPInputInjector {
    private let socketPath: String
    private var sock: Int32 = -1

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    // MARK: - 연결

    /// QEMU 기동을 기다리며 연결 + capabilities 협상 (취소 가능)
    @discardableResult
    func connect(retries: Int = 120, retryDelay: TimeInterval = 0.5) -> Bool {
        for _ in 0..<retries {
            if Task.isCancelled { return false }
            if tryConnect() { return true }
            Thread.sleep(forTimeInterval: retryDelay)
        }
        return false
    }

    private func tryConnect() -> Bool {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return false }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= capacity else { Darwin.close(s); return false }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                for (i, b) in pathBytes.enumerated() where i < capacity { dst[i] = b }
            }
        }

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(s, $0, len) }
        }
        if result != 0 { Darwin.close(s); return false }

        self.sock = s
        _ = readResponse()                                  // QMP greeting
        _ = sendRaw("{\"execute\":\"qmp_capabilities\"}\n") // 명령 모드 진입
        _ = readResponse()
        return true
    }

    var isConnected: Bool { sock >= 0 }

    func close() {
        if sock >= 0 { Darwin.close(sock); sock = -1 }
    }

    // MARK: - 입력 이벤트

    /// 키 한 번 (qcode 예: "spc", "ret", "esc", "up", "down")
    func sendKey(_ qcode: String) {
        sendKeyCombo([qcode])
    }

    /// 조합키 동시 입력 (예: ["ctrl","alt","delete"], ["shift","a"])
    func sendKeyCombo(_ qcodes: [String]) {
        guard !qcodes.isEmpty else { return }
        let keys = qcodes.map { "{\"type\":\"qcode\",\"data\":\"\($0)\"}" }.joined(separator: ",")
        _ = sendRaw("{\"execute\":\"send-key\",\"arguments\":{\"keys\":[\(keys)]}}\n")
        _ = readResponse()
    }

    /// 현재 게스트 화면을 PNG 파일로 덤프
    func screendump(to path: String) {
        _ = sendRaw("{\"execute\":\"screendump\",\"arguments\":{\"filename\":\"\(path)\",\"format\":\"png\"}}\n")
        _ = readResponse()
    }

    /// 마우스 버튼 클릭 (절대좌표 포인팅 장치 기준; left/right/middle)
    func click(button: String = "left") {
        let down = "{\"type\":\"btn\",\"data\":{\"down\":true,\"button\":\"\(button)\"}}"
        let up = "{\"type\":\"btn\",\"data\":{\"down\":false,\"button\":\"\(button)\"}}"
        _ = sendRaw("{\"execute\":\"input-send-event\",\"arguments\":{\"events\":[\(down),\(up)]}}\n")
        _ = readResponse()
    }

    /// 절대좌표 이동 (usb-tablet 기준, 0...32767 정규화 좌표)
    func moveAbsolute(x: Int, y: Int) {
        let ev = "[{\"type\":\"abs\",\"data\":{\"axis\":\"x\",\"value\":\(x)}},{\"type\":\"abs\",\"data\":{\"axis\":\"y\",\"value\":\(y)}}]"
        _ = sendRaw("{\"execute\":\"input-send-event\",\"arguments\":{\"events\":\(ev)}}\n")
        _ = readResponse()
    }

    // MARK: - Private

    @discardableResult
    private func sendRaw(_ string: String) -> Bool {
        guard sock >= 0 else { return false }
        return string.withCString { write(sock, $0, strlen($0)) > 0 }
    }

    @discardableResult
    private func readResponse() -> String {
        guard sock >= 0 else { return "" }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = read(sock, &buffer, buffer.count)
        if n <= 0 { return "" }
        return String(bytes: buffer[0..<n], encoding: .utf8) ?? ""
    }
}
