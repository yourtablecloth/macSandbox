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

/// Builder for WinPE-based DISM deployment media (a GPT FAT32 boot disk).
///
/// The core of fully deterministic installation:
/// - Edit the ISO's WinPE (boot.wim, image 2) with wimlib so it runs a deployment script (deploy.cmd) instead of setup.exe
/// - Package bootmgfw.efi + (the ISO's) BCD + boot.sdi + the edited boot.wim onto a GPT-partitioned FAT32 disk
///
/// Booting from this disk brings up WinPE **without the El Torito "Press any key" prompt and without any key press**, and it
/// deterministically deploys Windows via `diskpart` → `dism /Apply-Image` → `bcdboot`.
///
/// (Why GPT: bootmgr must map the `[boot]` device to a real partition, so a superfloppy FAT fails with "No mapping".)
enum WinPEDeployMediaBuilder {

    enum DeployMediaError: LocalizedError {
        case toolNotFound(String)
        case isoMountFailed(String)
        case commandFailed(String)
        case parseFailed(String)
        var errorDescription: String? {
            switch self {
            case .toolNotFound(let t): return "Required tool not found: \(t)"
            case .isoMountFailed(let m): return "ISO mount failed: \(m)"
            case .commandFailed(let m): return "Command failed: \(m)"
            case .parseFailed(let m): return "Output parse failed: \(m)"
            }
        }
    }

    /// Parameters for creating the deployment media
    struct Inputs {
        var isoPath: String
        var imageEdition: String          // dism /Name (e.g. "Windows 11 Pro")
        var pantherUnattendXML: String    // specialize/oobe answer to be copied to W:\Windows\Panther\unattend.xml after deployment
        var provisioningPowerShell: String // first-logon script copied to C:\ProgramData\MacSandbox\Provision.ps1
        var bootDiskPath: String          // path of the GPT FAT32 disk image to create
    }

    /// Create the GPT FAT32 deployment boot disk.
    static func build(_ inputs: Inputs, onLog: @escaping (String) -> Void) throws {
        guard let wimlib = SandboxPaths.wimlibBinary() else {
            throw DeployMediaError.toolNotFound("wimlib-imagex (brew install wimlib)")
        }

        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("macsandbox-wpe-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        // 1) Mount ISO
        onLog("Mounting ISO...")
        let mountPoint = try mountISO(inputs.isoPath)
        var isoDetached = false
        func detachISO() { if !isoDetached { _ = try? runCapture("/usr/bin/hdiutil", ["detach", mountPoint]); isoDetached = true } }
        defer { detachISO() }

        let installWim = (mountPoint as NSString).appendingPathComponent("sources/install.wim")
        let isoBootWim = (mountPoint as NSString).appendingPathComponent("sources/boot.wim")
        let isoBcd = (mountPoint as NSString).appendingPathComponent("efi/microsoft/boot/bcd")
        let isoBootSdi = (mountPoint as NSString).appendingPathComponent("boot/boot.sdi")
        let isoFonts = (mountPoint as NSString).appendingPathComponent("efi/microsoft/boot/fonts")

        // 2) Extract the general-purpose bootmgfw.efi (the ISO's \efi\boot\bootaa64.efi is cdboot, which can't boot from disk)
        onLog("Extracting bootmgfw.efi...")
        try run(wimlib.path, ["extract", installWim, "2", "/Windows/Boot/EFI/bootmgfw.efi",
                              "--dest-dir=\(work.path)", "--no-acls"])
        let bootmgfw = work.appendingPathComponent("bootmgfw.efi").path
        guard fm.fileExists(atPath: bootmgfw) else {
            throw DeployMediaError.commandFailed("bootmgfw.efi extraction produced no output")
        }

        // 3) Copy + edit boot.wim (image 2: winpeshl.ini → deploy.cmd)
        onLog("Editing WinPE (boot.wim)...")
        let editedWim = work.appendingPathComponent("boot.wim").path
        try fm.copyItem(atPath: isoBootWim, toPath: editedWim)
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: editedWim)

        let deployCmd = work.appendingPathComponent("deploy.cmd")
        let winpeshl = work.appendingPathComponent("winpeshl.ini")
        let diskpartTxt = work.appendingPathComponent("msbx-dp.txt")
        let pantherXml = work.appendingPathComponent("unattend.xml")
        let provisionPS1 = work.appendingPathComponent("provision.ps1")
        try deployCmdContent(imageEdition: inputs.imageEdition).write(to: deployCmd, atomically: true, encoding: .utf8)
        try winpeshlContent().write(to: winpeshl, atomically: true, encoding: .utf8)
        try diskpartScript().write(to: diskpartTxt, atomically: true, encoding: .utf8)
        try inputs.pantherUnattendXML.write(to: pantherXml, atomically: true, encoding: .utf8)
        try inputs.provisioningPowerShell.write(to: provisionPS1, atomically: true, encoding: .utf8)

        let updateCommands = """
        add \(deployCmd.path) /Windows/System32/deploy.cmd
        add \(winpeshl.path) /Windows/System32/winpeshl.ini
        add \(diskpartTxt.path) /Windows/System32/msbx-dp.txt
        add \(pantherXml.path) /unattend.xml
        add \(provisionPS1.path) /provision.ps1
        """
        try runWithStdin(wimlib.path, ["update", editedWim, "2"], stdin: updateCommands)

        // 4) Create the GPT FAT32 disk
        onLog("Creating GPT FAT32 boot disk...")
        try createBlankImage(at: inputs.bootDiskPath, sizeMB: 1300)
        let dev = try attachRawNoMount(inputs.bootDiskPath)
        var detached = false
        func detachDisk() { if !detached { _ = try? run("/usr/bin/hdiutil", ["detach", "-force", dev]); detached = true } }
        defer { detachDisk() }

        try run("/usr/sbin/diskutil", ["partitionDisk", dev, "1", "GPT", "MS-DOS FAT32", "WPEBOOT", "0"])
        let part = dev + "s1"
        _ = try runCapture("/usr/sbin/diskutil", ["mount", part])
        let mp = try mountPointOf(part)

        // 5) Copy boot files
        onLog("Copying boot files...")
        let fmCopy: (String, String) throws -> Void = { src, dstRel in
            let dst = (mp as NSString).appendingPathComponent(dstRel)
            try fm.createDirectory(atPath: (dst as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            if fm.fileExists(atPath: dst) { try fm.removeItem(atPath: dst) }
            try fm.copyItem(atPath: src, toPath: dst)
        }
        try fmCopy(bootmgfw, "EFI/BOOT/BOOTAA64.EFI")
        try fmCopy(isoBcd, "EFI/Microsoft/Boot/BCD")
        try fmCopy(isoBootSdi, "Boot/boot.sdi")
        try fmCopy(editedWim, "sources/boot.wim")
        if fm.fileExists(atPath: isoFonts) {
            try? fm.copyItem(atPath: isoFonts, toPath: (mp as NSString).appendingPathComponent("EFI/Microsoft/Boot/fonts"))
        }

        // Clean up macOS AppleDouble files
        if let enumerator = fm.enumerator(atPath: mp) {
            for case let f as String in enumerator where (f as NSString).lastPathComponent.hasPrefix("._") {
                try? fm.removeItem(atPath: (mp as NSString).appendingPathComponent(f))
            }
        }

        _ = try? runCapture("/usr/sbin/diskutil", ["unmount", part])
        detachDisk()
        detachISO()
        onLog("Deployment boot disk ready")
    }

    /// Return the list of installable editions (image Names) in the ISO's install.wim.
    static func listImageEditions(isoPath: String) throws -> [String] {
        guard let wimlib = SandboxPaths.wimlibBinary() else {
            throw DeployMediaError.toolNotFound("wimlib-imagex (brew install wimlib)")
        }
        let mountPoint = try mountISO(isoPath)
        defer { _ = try? runCapture("/usr/bin/hdiutil", ["detach", mountPoint]) }
        let installWim = (mountPoint as NSString).appendingPathComponent("sources/install.wim")
        let out = try runCapture(wimlib.path, ["info", installWim])
        var editions: [String] = []
        for line in out.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("Name:") else { continue }
            let name = String(t.dropFirst("Name:".count)).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty && !editions.contains(name) { editions.append(name) }
        }
        return editions
    }

    // MARK: - Script generation

    /// Keywords for built-in (provisioned) apps to remove — games/media/promotional ones.
    /// findstr /i's space-separated OR matching removes PackageName partial matches. Core apps (Store,
    /// DesktopAppInstaller, Photos, Paint, SnippingTool, Calculator, Notepad, Terminal) are preserved.
    static let removeAppxKeywords = [
        "Clipchamp",                  // video editor
        "SolitaireCollection",        // card game
        "GamingApp", "Xbox",          // all Xbox app/overlay/ID provider components
        "ZuneMusic", "ZuneVideo",     // media player / Movies & TV
        "BingNews", "BingWeather",    // news/weather
        "Teams", "MSTeams",           // Teams (consumer)
        "OfficeHub",                  // Office promotion
        "OutlookForWindows",          // new Outlook (promotional install)
        "FeedbackHub", "GetHelp", "Getstarted",  // feedback/help/tips
        "Todos", "People", "YourPhone",          // To Do/contacts/Phone Link
        "PowerAutomateDesktop", "DevHome", "QuickAssist",
        "SoundRecorder", "WindowsCamera",        // Sound Recorder/Camera
        "windowscommunicationsapps",             // legacy Mail/Calendar
        "549981C3F5F10",                         // Cortana (legacy remnant)
    ]

    static func deployCmdContent(imageEdition: String) -> String {
        let removeFilter = removeAppxKeywords.joined(separator: " ")
        // CRLF line breaks
        let lines = [
            "@echo off",
            "wpeinit",
            "echo === MacSandbox WinPE deploy ===",
            "diskpart /s X:\\Windows\\System32\\msbx-dp.txt",
            "set WIM=",
            "for %%d in (C D E F G H I) do if exist %%d:\\sources\\install.wim set WIM=%%d:\\sources\\install.wim",
            "dism /Apply-Image /ImageFile:%WIM% /Name:\"\(imageEdition)\" /ApplyDir:W:\\",
            "set VIRT=",
            "for %%d in (C D E F G H I J K) do if exist %%d:\\NetKVM set VIRT=%%d:",
            "if defined VIRT echo [virtio-win=%VIRT%] & dism /Image:W:\\ /Add-Driver /Driver:%VIRT%\\ /Recurse /ForceUnsigned",
            // Offline policy: disable the Edge first-run experience (FRE) — load the SOFTWARE hive and
            // inject HKLM\...\Policies\Microsoft\Edge!HideFirstRunExperience=1 (deterministic, applied before boot).
            "echo === Edge first-run policy ===",
            "reg load HKLM\\MSBXSOFT W:\\Windows\\System32\\config\\SOFTWARE",
            "reg add HKLM\\MSBXSOFT\\Policies\\Microsoft\\Edge /v HideFirstRunExperience /t REG_DWORD /d 1 /f",
            "reg unload HKLM\\MSBXSOFT || (ping -n 3 127.0.0.1 >nul & reg unload HKLM\\MSBXSOFT)",
            // Remove unwanted built-in apps (offline deprovisioning) — games/media/promotional ones.
            // Removed before the first logon, so they are never installed into the user profile (fast and deterministic).
            "echo === Remove provisioned inbox apps ===",
            "for /f \"tokens=3\" %%P in ('dism /English /Image:W:\\ /Get-ProvisionedAppxPackages ^| findstr /b /c:\"PackageName\" ^| findstr /i \"\(removeFilter)\"') do dism /Image:W:\\ /Remove-ProvisionedAppxPackage /PackageName:%%P",
            "md W:\\Windows\\Panther",
            "copy /Y X:\\unattend.xml W:\\Windows\\Panther\\unattend.xml",
            "md W:\\ProgramData\\MacSandbox",
            "copy /Y X:\\provision.ps1 W:\\ProgramData\\MacSandbox\\Provision.ps1",
            "bcdboot W:\\Windows /s S: /f UEFI",
            "copy /Y W:\\Windows\\Boot\\EFI\\bootmgfw.efi S:\\EFI\\BOOT\\BOOTAA64.EFI",
            "wpeutil shutdown"
        ]
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    static func winpeshlContent() -> String {
        "[LaunchApps]\r\ncmd.exe, /c X:\\Windows\\System32\\deploy.cmd\r\n"
    }

    static func diskpartScript() -> String {
        // Target = disk 0 (in QEMU the NVMe is enumerated first on PCI, so it's disk 0)
        let lines = [
            "select disk 0", "clean", "convert gpt",
            "create partition efi size=200", "format quick fs=fat32 label=ESP", "assign letter=S",
            "create partition msr size=16",
            "create partition primary", "format quick fs=ntfs label=Windows", "assign letter=W",
            "exit"
        ]
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: - macOS tool helpers

    private static func mountISO(_ isoPath: String) throws -> String {
        let out = try runCapture("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", isoPath])
        // Extract the last column (mount point) from a "/dev/diskN ... /Volumes/NAME" line
        for line in out.split(separator: "\n") {
            if let range = line.range(of: "/Volumes/") {
                return String(line[range.lowerBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        throw DeployMediaError.isoMountFailed(out)
    }

    private static func attachRawNoMount(_ path: String) throws -> String {
        let out = try runCapture("/usr/bin/hdiutil",
            ["attach", "-nomount", "-imagekey", "diskimage-class=CRawDiskImage", path])
        guard let dev = out.split(separator: "\n").first?
            .split(separator: " ").first.map(String.init), dev.hasPrefix("/dev/") else {
            throw DeployMediaError.parseFailed("attach: \(out)")
        }
        return dev
    }

    private static func mountPointOf(_ device: String) throws -> String {
        let info = try runCapture("/usr/sbin/diskutil", ["info", device])
        for line in info.split(separator: "\n") where line.contains("Mount Point") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                let mp = parts[1].trimmingCharacters(in: .whitespaces)
                if !mp.isEmpty { return mp }
            }
        }
        throw DeployMediaError.parseFailed("mount point: \(info)")
    }

    private static func createBlankImage(at path: String, sizeMB: Int) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) { try fm.removeItem(atPath: path) }
        guard fm.createFile(atPath: path, contents: nil) else {
            throw DeployMediaError.commandFailed("Image creation failed: \(path)")
        }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.truncate(atOffset: UInt64(sizeMB) * 1024 * 1024)
        try handle.close()
    }

    private static func run(_ path: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let err = Pipe(); p.standardError = err; p.standardOutput = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        if p.terminationStatus != 0 {
            let d = err.fileHandleForReading.readDataToEndOfFile()
            throw DeployMediaError.commandFailed("\((path as NSString).lastPathComponent): \(String(data: d, encoding: .utf8) ?? "")")
        }
    }

    private static func runCapture(_ path: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        let d = out.fileHandleForReading.readDataToEndOfFile()
        return String(data: d, encoding: .utf8) ?? ""
    }

    private static func runWithStdin(_ path: String, _ args: [String], stdin: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let inPipe = Pipe(); let err = Pipe()
        p.standardInput = inPipe; p.standardError = err; p.standardOutput = FileHandle.nullDevice
        try p.run()
        inPipe.fileHandleForWriting.write(stdin.data(using: .utf8)!)
        inPipe.fileHandleForWriting.closeFile()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let d = err.fileHandleForReading.readDataToEndOfFile()
            throw DeployMediaError.commandFailed("\((path as NSString).lastPathComponent): \(String(data: d, encoding: .utf8) ?? "")")
        }
    }
}
