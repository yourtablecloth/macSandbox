// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Copyright (C) 2026 Nam Jung Hyun (rkttu) <rkttu.official@gmail.com>
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

/// qcow2 디스크 생성 및 COW 오버레이 관리 (qemu-img 래퍼)
final class DiskService {

    enum DiskError: LocalizedError {
        case qemuImgNotFound
        case createFailed(String)

        var errorDescription: String? {
            switch self {
            case .qemuImgNotFound:
                return L("error.qemuImgNotFound")
            case .createFailed(let reason):
                return L("error.diskOp", reason)
            }
        }
    }

    /// 빈 qcow2 디스크 생성
    func createQcow2(at path: String, sizeGB: Int) throws {
        try runQemuImg(["create", "-f", "qcow2", path, "\(sizeGB)G"])
    }

    /// 베이스 이미지 위에 Copy-on-Write 오버레이 생성 (샌드박스 런타임용)
    func createOverlay(basePath: String, overlayPath: String) throws {
        try runQemuImg(["create", "-f", "qcow2", "-b", basePath, "-F", "qcow2", overlayPath])
    }

    // MARK: - Private

    private func runQemuImg(_ arguments: [String]) throws {
        guard let qemuImg = SandboxPaths.qemuImgBinary() else {
            throw DiskError.qemuImgNotFound
        }

        let process = Process()
        process.executableURL = qemuImg
        process.arguments = arguments
        process.environment = SandboxPaths.qemuEnvironment()

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "unknown error"
            throw DiskError.createFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
