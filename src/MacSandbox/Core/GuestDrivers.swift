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

/// 게스트(Windows ARM64) virtio 드라이버 제공.
/// virtio-win ISO를 캐시에 없으면 자동 다운로드한다(네트워킹/vGPU 등 virtio 장치 동작에 필요).
enum GuestDrivers {

    static let downloadURL =
        "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"

    /// virtio-win ISO 경로를 보장한다. 없으면 다운로드.
    static func ensureVirtioWinISO(onLog: @escaping (String) -> Void) throws -> String {
        let fm = FileManager.default
        let dest = SandboxPaths.virtioWinISO

        if fm.fileExists(atPath: dest.path),
           let size = (try? fm.attributesOfItem(atPath: dest.path))?[.size] as? Int64,
           size > 100_000_000 {
            onLog("virtio-win.iso 캐시 사용 (\(size / 1_000_000)MB)")
            return dest.path
        }

        try fm.createDirectory(at: SandboxPaths.driversDir, withIntermediateDirectories: true)
        onLog("virtio-win.iso 다운로드 중 (~700MB)...")

        let tmp = dest.path + ".part"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["-fL", "--retry", "3", "-o", tmp, downloadURL]
        let err = Pipe()
        process.standardError = err
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0, fm.fileExists(atPath: tmp) else {
            let d = err.fileHandleForReading.readDataToEndOfFile()
            throw BuildError.installFailed("virtio-win.iso 다운로드 실패: \(String(data: d, encoding: .utf8) ?? "")")
        }
        if fm.fileExists(atPath: dest.path) { try? fm.removeItem(atPath: dest.path) }
        try fm.moveItem(atPath: tmp, toPath: dest.path)
        onLog("virtio-win.iso 준비 완료")
        return dest.path
    }
}
