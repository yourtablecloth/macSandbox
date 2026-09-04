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

/// Client that injects keyboard/mouse input into the guest over a QMP (QEMU Machine Protocol) Unix socket.
///
/// Automatically handles moments during installation that require a key press, such as
/// "Press any key to boot from CD or DVD...", and can send arbitrary key/mouse events as needed.
final class QMPInputInjector {
    private let socketPath: String
    private var sock: Int32 = -1

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    // MARK: - Connection

    /// Wait for QEMU to start, then connect + negotiate capabilities (cancelable)
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

        // QEMU can close the QMP socket between two console polling ticks when the guest
        // powers off. A plain write(2) to that closed socket raises SIGPIPE and terminates
        // the entire app before the baseline completion marker can be inspected. Keep the
        // failure local to this socket so send(2) returns EPIPE instead.
        var noSigPipe: Int32 = 1
        guard setsockopt(
            s, SOL_SOCKET, SO_NOSIGPIPE,
            &noSigPipe, socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            Darwin.close(s)
            return false
        }

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
        guard !readResponse().isEmpty else { return false } // QMP greeting
        guard sendRaw("{\"execute\":\"qmp_capabilities\"}\n") else { return false }
        guard !readResponse().isEmpty else { return false }
        return isConnected
    }

    var isConnected: Bool { sock >= 0 }

    func close() {
        guard sock >= 0 else { return }
        let closingSocket = sock
        sock = -1
        _ = Darwin.shutdown(closingSocket, SHUT_RDWR)
        Darwin.close(closingSocket)
    }

    // MARK: - Input events

    /// A single key (qcode examples: "spc", "ret", "esc", "up", "down")
    func sendKey(_ qcode: String) {
        sendKeyCombo([qcode])
    }

    /// Simultaneous key combo (e.g. ["ctrl","alt","delete"], ["shift","a"])
    func sendKeyCombo(_ qcodes: [String]) {
        guard !qcodes.isEmpty else { return }
        let keys = qcodes.map { "{\"type\":\"qcode\",\"data\":\"\($0)\"}" }.joined(separator: ",")
        _ = sendRaw("{\"execute\":\"send-key\",\"arguments\":{\"keys\":[\(keys)]}}\n")
        _ = readResponse()
    }

    /// Dump the current guest screen to a PNG file
    func screendump(to path: String) {
        _ = sendRaw("{\"execute\":\"screendump\",\"arguments\":{\"filename\":\"\(path)\",\"format\":\"png\"}}\n")
        _ = readResponse()
    }

    /// Mouse button click (absolute-coordinate pointing device; left/right/middle)
    func click(button: String = "left") {
        let down = "{\"type\":\"btn\",\"data\":{\"down\":true,\"button\":\"\(button)\"}}"
        let up = "{\"type\":\"btn\",\"data\":{\"down\":false,\"button\":\"\(button)\"}}"
        _ = sendRaw("{\"execute\":\"input-send-event\",\"arguments\":{\"events\":[\(down),\(up)]}}\n")
        _ = readResponse()
    }

    /// Absolute-coordinate move (usb-tablet, 0...32767 normalized coordinates)
    func moveAbsolute(x: Int, y: Int) {
        let ev = "[{\"type\":\"abs\",\"data\":{\"axis\":\"x\",\"value\":\(x)}},{\"type\":\"abs\",\"data\":{\"axis\":\"y\",\"value\":\(y)}}]"
        _ = sendRaw("{\"execute\":\"input-send-event\",\"arguments\":{\"events\":\(ev)}}\n")
        _ = readResponse()
    }

    // MARK: - Private

    @discardableResult
    private func sendRaw(_ string: String) -> Bool {
        guard sock >= 0 else { return false }
        let bytes = Array(string.utf8)
        let sentAll = bytes.withUnsafeBytes { rawBuffer -> Bool in
            guard let base = rawBuffer.baseAddress else { return true }
            var offset = 0
            while offset < rawBuffer.count {
                let sent = Darwin.send(sock, base.advanced(by: offset), rawBuffer.count - offset, 0)
                if sent > 0 {
                    offset += sent
                } else if sent < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
        if !sentAll { close() }
        return sentAll
    }

    @discardableResult
    private func readResponse() -> String {
        guard sock >= 0 else { return "" }
        var buffer = [UInt8](repeating: 0, count: 4096)
        var n: Int
        repeat {
            n = Darwin.read(sock, &buffer, buffer.count)
        } while n < 0 && errno == EINTR
        if n <= 0 {
            close()
            return ""
        }
        return String(bytes: buffer[0..<n], encoding: .utf8) ?? ""
    }
}
