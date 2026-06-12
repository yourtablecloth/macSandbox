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

/// 앱 지원 디렉토리 및 번들 리소스(QEMU 바이너리/펌웨어) 경로 해석
///
/// 개발 환경에서는 실행 파일에서 상위로 올라가며 `vendor/qemu`를 찾고,
/// 배포(.app) 환경에서는 번들 리소스 내부를 우선 탐색합니다.
enum SandboxPaths {
    static let fileManager = FileManager.default

    // MARK: - App Support 디렉토리

    /// ~/Library/Application Support/MacSandbox
    static var appSupport: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("MacSandbox", isDirectory: true)
    }

    /// 단일 베이스라인 디렉토리 (고정 경로)
    static var baselineDir: URL { appSupport.appendingPathComponent("baseline", isDirectory: true) }
    /// 샌드박스 COW 오버레이 디렉토리 (런타임용, 향후 사용)
    static var overlaysDir: URL { appSupport.appendingPathComponent("overlays", isDirectory: true) }

    static var baselineDiskPath: URL { baselineDir.appendingPathComponent("baseline.qcow2") }
    static var baselineEfiVarsPath: URL { baselineDir.appendingPathComponent("efi-vars.fd") }
    static var baselineMetadataPath: URL { baselineDir.appendingPathComponent("metadata.json") }

    /// 기본 Windows ISO (사용자 다운로드 폴더)
    static var defaultISO: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/Win11_25H2_Korean_Arm64_v2.iso")
    }

    static func ensureBaseDirectories() throws {
        for dir in [appSupport, baselineDir, overlaysDir] where !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: - Vendor QEMU 해석

    /// vendor/qemu 디렉토리 (.app 번들 또는 개발 환경 프로젝트 루트)
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

    /// wimlib-imagex (WinPE 배포 매체 빌드에 필요, `brew install wimlib`)
    static func wimlibBinary() -> URL? { brewBinary("wimlib-imagex") }

    /// FreeRDP 클라이언트 (샌드박스 RDP 리다이렉션, `brew install freerdp`).
    /// macOS는 X11 없는 sdl-freerdp 우선.
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

    /// 게스트 드라이버 디렉토리 + virtio-win ISO 캐시 경로
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

    /// UEFI 코드 펌웨어 (읽기 전용 pflash)
    static func edk2CodeFirmware() -> URL? { firmware(named: "edk2-aarch64-code.fd") }
    /// UEFI 변수 템플릿 (복사해서 쓰기 가능 pflash로 사용)
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

    /// QEMU 실행 시 필요한 환경 변수 (번들 dylib/데이터 경로)
    static func qemuEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let vendor = vendorQemuDir() {
            env["DYLD_LIBRARY_PATH"] = vendor.appendingPathComponent("lib").path
            env["QEMU_DATADIR"] = vendor.appendingPathComponent("share/qemu").path
        }
        return env
    }
}
