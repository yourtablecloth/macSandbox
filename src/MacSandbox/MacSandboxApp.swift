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

import SwiftUI
import AppKit
import CFreeRDP

/// 진입점.
/// - GUI(기본): 베이스라인이 없으면 빌드 화면, 있으면 샌드박스 시작 화면.
/// - 헤드리스 빌드: `MacSandbox --headless-build [ISO경로]` → GUI 없이 1-round 빌드 후 종료.
/// - 샌드박스 실행 옵션(세부 설정): `.wsb` 파일 또는 커맨드라인 스위치로 지정. 베이스라인이
///   준비돼 있으면 GUI는 **곧바로 샌드박스를 시작**한다(시작 버튼 없음).
///   - `MacSandbox <config.wsb>` 또는 `MacSandbox --wsb <config.wsb>` → 구성대로 시작
///   - 스위치: `--memory <MB>` `--cpus <N>` `--networking on|off` `--vgpu on|off`
///            `--clipboard on|off` `--audio on|off` `--printer on|off`
///            `--folder <경로>[:ro]`(반복 가능) `--logon "<명령>"` (`--run`은 호환용 no-op)
///   - 스위치/`.wsb` 미지정 시 Windows Sandbox 표준 기본값으로 시작.
@main
enum AppEntry {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--freerdp-link-test") {
            if let c = cfreerdp_link_test() {
                print("[MacSandbox] FreeRDP link test: \(String(cString: c))")
            }
            exit(0)
        }
        if args.contains("--freerdp-fliptest") {
            exit(cfreerdp_fliptest())
        }
        if let idx = args.firstIndex(of: "--freerdp-view"), idx + 1 < args.count {
            let parts = args[idx + 1].split(separator: ":")
            RDPViewTest.host = String(parts[0])
            RDPViewTest.port = parts.count > 1 ? Int(parts[1]) ?? 3389 : 3389
            // 기능 게이팅 검증용 env(미지정 시 기본값): MSBX_CLIPBOARD/MSBX_MIC/MSBX_PRINTER = 0|1
            let env = ProcessInfo.processInfo.environment
            if let v = env["MSBX_CLIPBOARD"] { RDPViewTest.clipboard = (v != "0") }
            if let v = env["MSBX_MIC"] { RDPViewTest.mic = (v != "0") }
            if let v = env["MSBX_PRINTER"] { RDPViewTest.printer = (v != "0") }
            if let v = env["MSBX_DRIVE"], !v.isEmpty { RDPViewTest.drivePath = v }
            RDPViewTestApp.main()
            return
        }
        if let idx = args.firstIndex(of: "--freerdp-cliptest"), idx + 1 < args.count {
            let parts = args[idx + 1].split(separator: ":")
            let host = String(parts[0])
            let port = parts.count > 1 ? Int(parts[1]) ?? 3389 : 3389
            let rc = cfreerdp_cliptest(host, Int32(port))
            exit(rc)
        }
        if let idx = args.firstIndex(of: "--freerdp-filetest"), idx + 1 < args.count {
            let parts = args[idx + 1].split(separator: ":")
            let host = String(parts[0])
            let port = parts.count > 1 ? Int(parts[1]) ?? 3389 : 3389
            let rc = cfreerdp_filetest(host, Int32(port))
            exit(rc)
        }
        if let idx = args.firstIndex(of: "--freerdp-filetest3"), idx + 1 < args.count {
            let parts = args[idx + 1].split(separator: ":")
            let host = String(parts[0])
            let port = parts.count > 1 ? Int(parts[1]) ?? 3389 : 3389
            let rc = cfreerdp_filetest3(host, Int32(port))
            exit(rc)
        }
        if let idx = args.firstIndex(of: "--freerdp-restest"), idx + 1 < args.count {
            let parts = args[idx + 1].split(separator: ":")
            let host = String(parts[0])
            let port = parts.count > 1 ? Int(parts[1]) ?? 3389 : 3389
            let rc = cfreerdp_restest(host, Int32(port))
            exit(rc)
        }
        if let idx = args.firstIndex(of: "--freerdp-filetest2"), idx + 1 < args.count {
            let parts = args[idx + 1].split(separator: ":")
            let host = String(parts[0])
            let port = parts.count > 1 ? Int(parts[1]) ?? 3389 : 3389
            let rc = cfreerdp_filetest2(host, Int32(port))
            exit(rc)
        }
        if let idx = args.firstIndex(of: "--freerdp-capture"), idx + 2 < args.count {
            let hostport = args[idx + 1]
            let out = args[idx + 2]
            let parts = hostport.split(separator: ":")
            let host = String(parts[0])
            let port = parts.count > 1 ? Int(parts[1]) ?? 3389 : 3389
            print("[MacSandbox] FreeRDP capture: \(host):\(port) → \(out)")
            let rc = cfreerdp_capture(host, Int32(port), out)
            print("[MacSandbox] result: rc=\(rc) (0=success)")
            exit(rc == 0 ? 0 : 1)
        }
        if let idx = args.firstIndex(of: "--headless-build") {
            let isoArg = (idx + 1 < args.count && !args[idx + 1].hasPrefix("-")) ? args[idx + 1] : nil
            HeadlessRunner.run(isoPathArg: isoArg)   // 내부에서 exit()
        } else {
            AppLaunch.shared.configure(from: args)
            MacSandboxGUIApp.main()
        }
    }
}

struct MacSandboxGUIApp: App {
    // 메뉴바/Dock 표시 + 수명 제어(⌘Q·창 닫기 확인). 앱 델리게이트가 .regular 활성화.
    @NSApplicationDelegateAdaptor(SandboxAppDelegate.self) private var appDelegate
    // 샌드박스 러너/베이스라인 관리자는 App이 소유 — ContentView와 메뉴 커맨드가 공유한다.
    @StateObject private var runner = SandboxRunner()
    @StateObject private var admin = BaselineAdmin()

    var body: some Scene {
        // 단일 창(Window) — WindowGroup과 달리 새 창(⌘N)이 불가해 샌드박스 창을 하나로 제약.
        Window(Brand.appName, id: "sandbox") {
            ContentView(runner: runner, admin: admin)
        }
        .defaultSize(width: 1024, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { }   // "새 창" 제거(단일 창 제약)
            CommandGroup(replacing: .appInfo) { AboutMenuItem() }   // 커스텀 '앱 정보' 창
            CommandGroup(replacing: .help) {        // 기본 도움말 → 온라인 도움말(GitHub Pages)
                Button(L("menu.help")) {
                    if let url = URL(string: HelpLinks.help) { NSWorkspace.shared.open(url) }
                }
                .keyboardShortcut("?", modifiers: [.command])
                Divider()
                TermsMenuItem()   // 사용 약관 보기(언어 전환 가능한 읽기 전용 뷰어)
            }
            CommandMenu(L("menu.sandbox")) {
                Button(L("menu.stop")) { runner.stop() }
                    .keyboardShortcut(".", modifiers: [.command])
                    .disabled(!runner.isRunning)
                Divider()
                Button(L("menu.rebuild")) { admin.requestRebuild(runner: runner) }
                    .disabled(admin.busy || admin.rebuildMode)
                Button(L("menu.destroy")) { admin.requestDestroy(runner: runner) }
                    .disabled(admin.busy || !admin.hasBaseline())
            }
        }

        // '앱 정보' 대화상자 (앱 메뉴 › macSandbox for Windows 정보)
        Window(L("about.windowTitle"), id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commandsRemoved()   // 창 메뉴 목록에 노출하지 않음

        // '사용 약관' 뷰어 (도움말 메뉴에서 열기 — 언어 전환 가능)
        Window(L("consent.title"), id: "terms") {
            TermsViewerView()
        }
        .windowResizability(.contentMinSize)
        .defaultPosition(.center)
        .commandsRemoved()

        // '옵션' 대화상자 (앱 메뉴 › Settings…, ⌘,)
        Settings {
            OptionsView()
        }
    }
}

/// 앱 메뉴의 '… 정보' 항목 — 표준 About 패널 대신 커스텀 AboutView 창을 연다.
private struct AboutMenuItem: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button(L("about.menu")) { openWindow(id: "about") }
    }
}

/// 도움말 메뉴의 '사용 약관 보기' 항목 — 언어 전환 가능한 약관 뷰어 창을 연다.
private struct TermsMenuItem: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button(L("menu.terms")) { openWindow(id: "terms") }
    }
}

/// 실행 시점에 결정된 샌드박스 구성 (CLI/`.wsb`에서 파싱, GUI가 읽음).
/// GUI는 베이스라인이 준비돼 있으면 이 구성으로 곧바로 샌드박스를 시작한다.
final class AppLaunch {
    static let shared = AppLaunch()

    /// 샌드박스 구성(기본값 = 옵션 기반). CLI/`.wsb`로 덮어쓴다.
    private(set) var config = SandboxConfig()
    /// CLI/`.wsb`(또는 실행 중 .wsb 불러오기)로 **명시 지정된** 구성. nil이면 옵션 기본값 사용.
    private(set) var explicitConfig: SandboxConfig?
    /// 파싱 중 사용자에게 보일 메모(오류 등).
    private(set) var note: String?

    /// 실행 중 `.wsb`를 불러오면 명시 구성으로 전환(옵션 기본값 대신 이 구성 유지).
    func markExplicit(_ c: SandboxConfig) { explicitConfig = c }

    /// 다음 샌드박스 시작에 쓸 구성. 명시 구성이 없으면 옵션에서 매번 새로 산출
    /// (옵션 대화상자 변경이 다음 시작부터 반영).
    func effectiveConfig() -> SandboxConfig { explicitConfig ?? AppOptions.makeDefaultConfig() }

    func configure(from args: [String]) {
        var c = AppOptions.makeDefaultConfig()   // 미지정 항목은 옵션 기본값을 따른다
        var explicit = false
        var notes: [String] = []

        func loadWSB(_ path: String) {
            do { c = try WSBConfig.load(path: path); explicit = true }
            catch { notes.append(error.localizedDescription) }
        }

        var i = 1
        while i < args.count {
            let a = args[i]
            let next: String? = (i + 1 < args.count) ? args[i + 1] : nil
            func consume() { i += 1 }   // 값 1개 소비
            switch a {
            case "--run":
                break   // 호환용 — GUI는 항상 곧바로 시작한다
            case "--wsb":
                if let p = next { loadWSB(p); consume() }
            case "--memory", "--memory-mb":
                if let v = next, let m = Int(v) { c.memoryMB = m; explicit = true; consume() }
            case "--cpus", "--cpu", "--cores":
                if let v = next, let n = Int(v) { c.cpuCores = n; explicit = true; consume() }
            case "--networking", "--network", "--net":
                if let v = next { c.networkingEnabled = WSBConfig.boolFlag(v); explicit = true; consume() }
            case "--vgpu", "--gpu":
                if let v = next { c.vGpuEnabled = WSBConfig.boolFlag(v); explicit = true; consume() }
            case "--clipboard":
                if let v = next { c.clipboardEnabled = WSBConfig.boolFlag(v); explicit = true; consume() }
            case "--audio", "--microphone", "--mic":
                if let v = next { c.audioInputEnabled = WSBConfig.boolFlag(v); explicit = true; consume() }
            case "--printer":
                if let v = next { c.printerEnabled = WSBConfig.boolFlag(v); explicit = true; consume() }
            case "--folder", "--map":
                if let v = next { c.mappedFolders.append(Self.parseFolder(v)); explicit = true; consume() }
            case "--logon", "--logon-command":
                if let v = next { c.logonCommand = v; explicit = true; consume() }
            default:
                if a.lowercased().hasSuffix(".wsb") { loadWSB(a) }
            }
            i += 1
        }

        self.config = c
        self.explicitConfig = explicit ? c : nil
        self.note = notes.isEmpty ? nil : notes.joined(separator: "\n")

        // CLI/.wsb로 구성이 지정됐으면 터미널에 요약 피드백 (GUI는 별도로 표시).
        if args.count > 1 {
            var out = "[MacSandbox] Sandbox configuration (starts immediately once the baseline is ready):\n"
            for (k, v) in WSBConfig.summaryLines(c) { out += "  \(k): \(v)\n" }
            if let n = self.note { out += "  ⚠️ \(n)\n" }
            FileHandle.standardError.write(Data(out.utf8))
        }
    }

    /// `--folder <경로>[:ro]` → MappedFolder
    private static func parseFolder(_ spec: String) -> MappedFolder {
        var path = spec
        var readOnly = false
        if spec.lowercased().hasSuffix(":ro") {
            path = String(spec.dropLast(3)); readOnly = true
        } else if spec.lowercased().hasSuffix(":rw") {
            path = String(spec.dropLast(3))
        }
        return MappedFolder(hostPath: (path as NSString).expandingTildeInPath, readOnly: readOnly)
    }
}

/// 헤드리스 1-round 빌드 실행기 (CLI/검증용)
enum HeadlessRunner {
    static func run(isoPathArg: String?) {
        let isoPath = isoPathArg ?? SandboxPaths.defaultISO.path
        guard FileManager.default.fileExists(atPath: isoPath) else {
            FileHandle.standardError.write(Data("ISO not found: \(isoPath)\n".utf8))
            exit(2)
        }
        // GUI의 라이선스 체크리스트에 상응하는 CLI 고지(자동화 경로는 동의 절차 없이 고지만).
        print("""
        [MacSandbox] NOTICE: This tool does not provide Windows, a product key, or any usage \
        rights. One Windows license covers one instance on one device (physical or virtual); \
        OEM licenses are generally not usable in a VM. You are solely responsible for EULA \
        and activation compliance.
        """)
        print("[MacSandbox] Headless baseline build started — ISO: \(isoPath)")

        // 메인 액터 Task로 빌드 실행. 메인 스레드는 RunLoop로 살려두어
        // @MainActor 작업과 QEMU 출력 콜백이 처리되게 한다. 완료 시 Task가 exit() 호출.
        Task { @MainActor in
            let builder = BaselineBuilder()
            builder.logHandler = { line in print("  \(line)") }
            let config = InstallConfig(isoPath: isoPath)
            await builder.build(config: config, headless: true)
            if case .completed = builder.phase {
                print("[MacSandbox] ✅ Done")
                exit(0)
            } else {
                print("[MacSandbox] ❌ \(builder.phase.label)")
                exit(1)
            }
        }

        RunLoop.main.run()
    }
}
