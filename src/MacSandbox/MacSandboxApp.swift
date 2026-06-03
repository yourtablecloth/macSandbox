import SwiftUI

/// 진입점.
/// - GUI: 기본 (단일 창)
/// - 헤드리스: `MacSandbox --headless-build [ISO경로]` → GUI 없이 1-round 빌드 후 종료
@main
enum AppEntry {
    static func main() {
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--headless-build") {
            let isoArg = (idx + 1 < args.count && !args[idx + 1].hasPrefix("-")) ? args[idx + 1] : nil
            HeadlessRunner.run(isoPathArg: isoArg)   // 내부에서 exit()
        } else {
            MacSandboxGUIApp.main()
        }
    }
}

struct MacSandboxGUIApp: App {
    var body: some Scene {
        WindowGroup("MacSandbox") {
            ContentView()
        }
        .defaultSize(width: 720, height: 660)
        .windowResizability(.contentMinSize)
    }
}

/// 헤드리스 1-round 빌드 실행기 (CLI/검증용)
enum HeadlessRunner {
    static func run(isoPathArg: String?) {
        let isoPath = isoPathArg ?? SandboxPaths.defaultISO.path
        guard FileManager.default.fileExists(atPath: isoPath) else {
            FileHandle.standardError.write(Data("ISO를 찾을 수 없습니다: \(isoPath)\n".utf8))
            exit(2)
        }
        print("[MacSandbox] 헤드리스 베이스라인 빌드 시작 — ISO: \(isoPath)")

        // 메인 액터 Task로 빌드 실행. 메인 스레드는 RunLoop로 살려두어
        // @MainActor 작업과 QEMU 출력 콜백이 처리되게 한다. 완료 시 Task가 exit() 호출.
        Task { @MainActor in
            let builder = BaselineBuilder()
            builder.logHandler = { line in print("  \(line)") }
            let config = InstallConfig(isoPath: isoPath)
            await builder.build(config: config, headless: true)
            if case .completed = builder.phase {
                print("[MacSandbox] ✅ 완료")
                exit(0)
            } else {
                print("[MacSandbox] ❌ \(builder.phase.label)")
                exit(1)
            }
        }

        RunLoop.main.run()
    }
}
