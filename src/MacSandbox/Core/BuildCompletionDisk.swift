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

/// A small writable FAT disk used as a one-way completion channel from the OOBE guest to the host.
/// QEMU returning zero only means that the virtual machine stopped; Windows Setup can also stop after
/// rejecting an answer file. The host marks a baseline ready only after reading the guest marker.
enum BuildCompletionDisk {
    static let volumeLabel = "MSBXSTATUS"
    static let successFileName = "COMPLETE.TXT"
    static let failureFileName = "FAILED.TXT"
    static let successToken = "macsandbox-baseline-v1"

    enum InspectionResult: Equatable {
        case success
        case failure(String)
        case missing
    }

    enum CompletionDiskError: LocalizedError {
        case commandFailed(String)
        case parseFailed(String)

        var errorDescription: String? {
            switch self {
            case .commandFailed(let reason):
                return "Baseline completion disk command failed: \(reason)"
            case .parseFailed(let reason):
                return "Could not inspect the baseline completion disk: \(reason)"
            }
        }
    }

    static func create(at path: String) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            try fm.removeItem(atPath: path)
        }
        guard fm.createFile(atPath: path, contents: nil) else {
            throw CompletionDiskError.commandFailed("image creation failed")
        }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.truncate(atOffset: 8 * 1_024 * 1_024)
        try handle.close()

        let device = try attach(path: path, readOnly: false)
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", "-force", device]) }
        try run("/sbin/newfs_msdos", ["-F", "16", "-v", volumeLabel, device])
    }

    static func inspect(at path: String) throws -> InspectionResult {
        let device = try attach(path: path, readOnly: true)
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", "-force", device]) }

        _ = try runCapture("/usr/sbin/diskutil", ["mount", "readOnly", device])
        defer { _ = try? runCapture("/usr/sbin/diskutil", ["unmount", device]) }
        let mountPoint = try mountedPath(of: device)

        let successPath = (mountPoint as NSString).appendingPathComponent(successFileName)
        if let value = try? String(contentsOfFile: successPath, encoding: .ascii),
           value.trimmingCharacters(in: .whitespacesAndNewlines) == successToken {
            return .success
        }

        let failurePath = (mountPoint as NSString).appendingPathComponent(failureFileName)
        if let value = try? String(contentsOfFile: failurePath, encoding: .ascii) {
            let message = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(message.isEmpty ? "Windows provisioning reported an unspecified failure." : message)
        }
        return .missing
    }

    private static func attach(path: String, readOnly: Bool) throws -> String {
        var arguments = ["attach", "-nomount"]
        if readOnly {
            arguments.append("-readonly")
        }
        arguments += ["-imagekey", "diskimage-class=CRawDiskImage", path]
        let output = try runCapture("/usr/bin/hdiutil", arguments)
        guard let device = output.split(separator: "\n").first?
            .split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init),
              device.hasPrefix("/dev/") else {
            throw CompletionDiskError.parseFailed("hdiutil attach returned: \(output)")
        }
        return device
    }

    private static func mountedPath(of device: String) throws -> String {
        let info = try runCapture("/usr/sbin/diskutil", ["info", device])
        for line in info.split(separator: "\n") where line.contains("Mount Point") {
            let fields = line.split(separator: ":", maxSplits: 1)
            if fields.count == 2 {
                let path = fields[1].trimmingCharacters(in: .whitespaces)
                if !path.isEmpty {
                    return path
                }
            }
        }
        throw CompletionDiskError.parseFailed("diskutil did not report a mount point for \(device)")
    }

    private static func run(_ executable: String, _ arguments: [String]) throws {
        _ = try runProcess(executable, arguments)
    }

    private static func runCapture(_ executable: String, _ arguments: [String]) throws -> String {
        let data = try runProcess(executable, arguments)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func runProcess(_ executable: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()

        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let reason = String(data: errorData, encoding: .utf8) ?? "exit \(process.terminationStatus)"
            throw CompletionDiskError.commandFailed("\((executable as NSString).lastPathComponent): \(reason)")
        }
        return outputData
    }
}
