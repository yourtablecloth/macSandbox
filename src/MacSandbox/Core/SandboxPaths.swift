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

/// Resolves the app support directory and bundle resource (QEMU binaries/firmware) paths
///
/// In a development environment, it walks up from the executable to find `vendor/qemu`,
/// and in a distribution (.app) environment, it searches inside the bundle resources first.
enum SandboxPaths {
    static let fileManager = FileManager.default

    // MARK: - App Support directory

    /// ~/Library/Application Support/MacSandbox
    static var appSupport: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("MacSandbox", isDirectory: true)
    }

    /// Single baseline directory (fixed path)
    static var baselineDir: URL { appSupport.appendingPathComponent("baseline", isDirectory: true) }
    /// Sandbox COW overlay directory (for runtime, future use)
    static var overlaysDir: URL { appSupport.appendingPathComponent("overlays", isDirectory: true) }

    static var baselineDiskPath: URL { baselineDir.appendingPathComponent("baseline.qcow2") }
    static var baselineEfiVarsPath: URL { baselineDir.appendingPathComponent("efi-vars.fd") }
    static var baselineMetadataPath: URL { baselineDir.appendingPathComponent("metadata.json") }

    /// Default Windows ISO (user's Downloads folder)
    static var defaultISO: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/Win11_25H2_Korean_Arm64_v2.iso")
    }

    static func ensureBaseDirectories() throws {
        for dir in [appSupport, baselineDir, overlaysDir] where !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: - Vendor QEMU resolution

    /// vendor/qemu directory (.app bundle or development-environment project root)
    static func vendorQemuDir() -> URL? {
        if let resourcePath = Bundle.main.resourcePath {
            let inBundle = URL(fileURLWithPath: resourcePath).appendingPathComponent("vendor/qemu")
            if fileManager.fileExists(atPath: inBundle.path) { return inBundle }
        }
        var dir = Bundle.main.executableURL?.deletingLastPathComponent()
        for _ in 0..<8 {
            guard let current = dir else { break }
            let candidate = current.appendingPathComponent("vendor/qemu")
            if fileManager.fileExists(atPath: candidate.path) { return candidate }
            dir = current.deletingLastPathComponent()
        }
        return nil
    }

    static func qemuSystemBinary() -> URL? { binary(named: "qemu-system-aarch64") }
    static func qemuImgBinary() -> URL? { binary(named: "qemu-img") }

    /// wimlib-imagex (needed to build the WinPE deployment media, `brew install wimlib`)
    static func wimlibBinary() -> URL? { brewBinary("wimlib-imagex") }

    /// FreeRDP client (sandbox RDP redirection, `brew install freerdp`).
    /// On macOS, prefer the X11-free sdl-freerdp.
    static func freerdpBinary() -> URL? {
        for name in ["sdl-freerdp3", "sdl-freerdp", "xfreerdp3", "xfreerdp"] {
            if let url = brewBinary(name) { return url }
        }
        return nil
    }

    private static func brewBinary(_ name: String) -> URL? {
        if let vendor = vendorQemuDir() {
            let bundled = vendor.appendingPathComponent("bin/\(name)")
            if fileManager.isExecutableFile(atPath: bundled.path) { return bundled }
        }
        for p in ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
        where fileManager.isExecutableFile(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        return nil
    }

    /// Guest driver directory + virtio-win ISO cache path
    static var driversDir: URL { appSupport.appendingPathComponent("drivers", isDirectory: true) }
    static var virtioWinISO: URL { driversDir.appendingPathComponent("virtio-win.iso") }

    private static func binary(named name: String) -> URL? {
        if let vendor = vendorQemuDir() {
            let path = vendor.appendingPathComponent("bin/\(name)")
            if fileManager.isExecutableFile(atPath: path.path) { return path }
        }
        for p in ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
        where fileManager.isExecutableFile(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        return nil
    }

    /// UEFI code firmware (read-only pflash)
    static func edk2CodeFirmware() -> URL? { firmware(named: "edk2-aarch64-code.fd") }
    /// UEFI variable template (copied and used as a writable pflash)
    static func edk2VarsTemplate() -> URL? { firmware(named: "edk2-arm-vars.fd") }

    private static func firmware(named name: String) -> URL? {
        if let vendor = vendorQemuDir() {
            let path = vendor.appendingPathComponent("share/qemu/\(name)")
            if fileManager.fileExists(atPath: path.path) { return path }
        }
        for p in ["/opt/homebrew/share/qemu/\(name)", "/usr/local/share/qemu/\(name)"]
        where fileManager.fileExists(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        return nil
    }

    /// Environment variables needed when running QEMU (bundle dylib/data paths)
    static func qemuEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let vendor = vendorQemuDir() {
            env["DYLD_LIBRARY_PATH"] = vendor.appendingPathComponent("lib").path
            env["QEMU_DATADIR"] = vendor.appendingPathComponent("share/qemu").path
        }
        return env
    }
}
