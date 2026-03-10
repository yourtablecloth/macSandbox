import SwiftUI

@main
struct MacSandboxApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 900, height: 600)
        .commands {
            SandboxCommands()
        }
    }
}

/// 메뉴바 커맨드
struct SandboxCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("설정 파일 열기...") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.init(filenameExtension: "msb")!]
                panel.allowsMultipleSelection = false
                panel.runModal()
            }
            .keyboardShortcut("o", modifiers: .command)
        }
    }
}
