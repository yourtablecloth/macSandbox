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

/// WinPE 기반 DISM 배포 매체(GPT FAT32 부트 디스크) 빌더.
///
/// 완전 결정론적 설치의 핵심:
/// - ISO의 WinPE(boot.wim, image 2)를 wimlib로 편집해 setup.exe 대신 배포 스크립트(deploy.cmd)를 실행
/// - GPT 파티션 FAT32 디스크에 bootmgfw.efi + (ISO의)BCD + boot.sdi + 편집된 boot.wim 패키징
///
/// 이 디스크로 부팅하면 **El Torito "Press any key" 프롬프트 없이, 키 입력 없이** WinPE가 떠서
/// `diskpart` → `dism /Apply-Image` → `bcdboot` 로 결정론적으로 Windows를 배포한다.
///
/// (왜 GPT인가: bootmgr는 `[boot]` 장치를 실제 파티션으로 매핑해야 하므로 슈퍼플로피 FAT은 "No mapping"으로 실패한다.)
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

    /// 배포 매체 생성 파라미터
    struct Inputs {
        var isoPath: String
        var imageEdition: String          // dism /Name (예: "Windows 11 Pro")
        var pantherUnattendXML: String    // 배포 후 W:\Windows\Panther\unattend.xml로 복사될 specialize/oobe 응답
        var bootDiskPath: String          // 생성할 GPT FAT32 디스크 이미지 경로
    }

    /// GPT FAT32 배포 부트 디스크를 생성한다.
    static func build(_ inputs: Inputs, onLog: @escaping (String) -> Void) throws {
        guard let wimlib = SandboxPaths.wimlibBinary() else {
            throw DeployMediaError.toolNotFound("wimlib-imagex (brew install wimlib)")
        }

        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("macsandbox-wpe-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        // 1) ISO 마운트
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

        // 2) 범용 bootmgfw.efi 추출 (ISO의 \efi\boot\bootaa64.efi는 cdboot라 디스크 부팅 불가)
        onLog("Extracting bootmgfw.efi...")
        try run(wimlib.path, ["extract", installWim, "2", "/Windows/Boot/EFI/bootmgfw.efi",
                              "--dest-dir=\(work.path)", "--no-acls"])
        let bootmgfw = work.appendingPathComponent("bootmgfw.efi").path
        guard fm.fileExists(atPath: bootmgfw) else {
            throw DeployMediaError.commandFailed("bootmgfw.efi extraction produced no output")
        }

        // 3) boot.wim 복사 + 편집 (image 2: winpeshl.ini → deploy.cmd)
        onLog("Editing WinPE (boot.wim)...")
        let editedWim = work.appendingPathComponent("boot.wim").path
        try fm.copyItem(atPath: isoBootWim, toPath: editedWim)
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: editedWim)

        let deployCmd = work.appendingPathComponent("deploy.cmd")
        let winpeshl = work.appendingPathComponent("winpeshl.ini")
        let diskpartTxt = work.appendingPathComponent("msbx-dp.txt")
        let pantherXml = work.appendingPathComponent("unattend.xml")
        try deployCmdContent(imageEdition: inputs.imageEdition).write(to: deployCmd, atomically: true, encoding: .utf8)
        try winpeshlContent().write(to: winpeshl, atomically: true, encoding: .utf8)
        try diskpartScript().write(to: diskpartTxt, atomically: true, encoding: .utf8)
        try inputs.pantherUnattendXML.write(to: pantherXml, atomically: true, encoding: .utf8)

        let updateCommands = """
        add \(deployCmd.path) /Windows/System32/deploy.cmd
        add \(winpeshl.path) /Windows/System32/winpeshl.ini
        add \(diskpartTxt.path) /Windows/System32/msbx-dp.txt
        add \(pantherXml.path) /unattend.xml
        """
        try runWithStdin(wimlib.path, ["update", editedWim, "2"], stdin: updateCommands)

        // 4) GPT FAT32 디스크 생성
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

        // 5) 부트 파일 복사
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

        // macOS AppleDouble 정리
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

    /// ISO 안 install.wim의 설치 가능한 에디션(이미지 Name) 목록을 반환한다.
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

    // MARK: - 스크립트 생성

    /// 제거할 기본 제공(프로비저닝) 앱 키워드 — 게임/미디어/프로모션류.
    /// findstr /i의 공백 구분 OR 매칭으로 PackageName 부분일치 제거. 핵심 앱(Store,
    /// DesktopAppInstaller, Photos, Paint, SnippingTool, Calculator, Notepad, Terminal)은 보존.
    static let removeAppxKeywords = [
        "Clipchamp",                  // 영상 편집기
        "SolitaireCollection",        // 카드 게임
        "GamingApp", "Xbox",          // Xbox 앱/오버레이/ID 공급자 일체
        "ZuneMusic", "ZuneVideo",     // 미디어 플레이어 / 영화 및 TV
        "BingNews", "BingWeather",    // 뉴스/날씨
        "Teams", "MSTeams",           // Teams 소비자용
        "OfficeHub",                  // Office 프로모션
        "OutlookForWindows",          // 새 Outlook(프로모션 설치)
        "FeedbackHub", "GetHelp", "Getstarted",  // 피드백/도움말/팁
        "Todos", "People", "YourPhone",          // To Do/연락처/휴대폰 연결
        "PowerAutomateDesktop", "DevHome", "QuickAssist",
        "SoundRecorder", "WindowsCamera",        // 녹음기/카메라
        "windowscommunicationsapps",             // 구 메일/캘린더
        "549981C3F5F10",                         // Cortana(구버전 잔재)
    ]

    static func deployCmdContent(imageEdition: String) -> String {
        let removeFilter = removeAppxKeywords.joined(separator: " ")
        // CRLF 줄바꿈
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
            // 오프라인 정책: Edge 최초 실행 경험(FRE) 비활성화 — SOFTWARE 하이브를 로드해
            // HKLM\...\Policies\Microsoft\Edge!HideFirstRunExperience=1 주입(결정론적, 부팅 전 적용).
            "echo === Edge first-run policy ===",
            "reg load HKLM\\MSBXSOFT W:\\Windows\\System32\\config\\SOFTWARE",
            "reg add HKLM\\MSBXSOFT\\Policies\\Microsoft\\Edge /v HideFirstRunExperience /t REG_DWORD /d 1 /f",
            "reg unload HKLM\\MSBXSOFT || (ping -n 3 127.0.0.1 >nul & reg unload HKLM\\MSBXSOFT)",
            // 기본 제공 불필요 앱 제거(오프라인 프로비저닝 해제) — 게임/미디어/프로모션류.
            // 첫 로그온 전에 제거하므로 사용자 프로필에 설치 자체가 안 된다(빠르고 결정론적).
            "echo === Remove provisioned inbox apps ===",
            "for /f \"tokens=3\" %%P in ('dism /English /Image:W:\\ /Get-ProvisionedAppxPackages ^| findstr /b /c:\"PackageName\" ^| findstr /i \"\(removeFilter)\"') do dism /Image:W:\\ /Remove-ProvisionedAppxPackage /PackageName:%%P",
            "md W:\\Windows\\Panther",
            "copy /Y X:\\unattend.xml W:\\Windows\\Panther\\unattend.xml",
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
        // 대상 = disk 0 (QEMU에서 NVMe가 PCI로 먼저 열거되어 disk 0)
        let lines = [
            "select disk 0", "clean", "convert gpt",
            "create partition efi size=200", "format quick fs=fat32 label=ESP", "assign letter=S",
            "create partition msr size=16",
            "create partition primary", "format quick fs=ntfs label=Windows", "assign letter=W",
            "exit"
        ]
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: - macOS 도구 헬퍼

    private static func mountISO(_ isoPath: String) throws -> String {
        let out = try runCapture("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", isoPath])
        // "/dev/diskN ... /Volumes/NAME" 형태에서 마지막 컬럼(마운트 지점) 추출
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
