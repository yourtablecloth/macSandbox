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

import AppKit

/// 앱 수명 ↔ VM 수명 동기화 훅.
///
/// - 창 생성 시 VM 부팅(ContentView 자동 시작).
/// - 창 닫기/앱 종료 시도 시 **확인 다이얼로그** 후 VM 정지 + 정리 → 함께 종료.
/// - 앱이 강제종료/크래시되면 [QEMURuntime]의 부모-사망 워치독이 VM을 파괴(orphan 방지).
final class AppHooks {
    static let shared = AppHooks()
    weak var runner: SandboxRunner?
    private init() {}
}

/// 실행 중인 샌드박스가 있으면 확인을 받고, 승인 시 정지 후 종료를 진행한다.
/// 반환: true = 즉시 닫아도 됨(미실행), false = 닫기 보류(확인/정리 중).
@MainActor
private func confirmStopAndQuit() -> Bool {
    guard let runner = AppHooks.shared.runner, runner.isRunning else { return true }
    let alert = NSAlert()
    alert.messageText = "샌드박스를 종료할까요?"
    alert.informativeText = "창을 닫으면 실행 중인 일회용 샌드박스가 종료되고, 변경사항은 모두 폐기됩니다."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "종료")   // 기본(첫 번째)
    alert.addButton(withTitle: "취소")
    guard alert.runModal() == .alertFirstButtonReturn else { return false }
    runner.stop()
    Task { @MainActor in
        // 일회용 정리(오버레이 삭제 등)가 끝날 때까지 잠깐 기다린 뒤 앱 종료.
        for _ in 0..<50 {              // 최대 ~10초
            if !runner.isRunning { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        NSApp.terminate(nil)
    }
    return false
}

/// 메인 창의 닫기(빨간 버튼/⌘W)를 가로채 확인 다이얼로그를 띄운다.
final class CloseGuard: NSObject, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated { confirmStopAndQuit() }
    }
}

/// 일반 macOS 앱처럼 메뉴바·Dock에 표시되고(⌘Q·창 닫기로 수명 제어) 동작하게 한다.
final class SandboxAppDelegate: NSObject, NSApplicationDelegate {
    // CLI(헤드리스/테스트)가 아닌 GUI로 뜰 때 정식 앱(.regular)으로 — Dock 아이콘 + 메뉴바 표시.
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    // 단일 창을 닫으면 앱도 종료(아래 applicationShouldTerminate에서 확인 다이얼로그).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let runner = AppHooks.shared.runner, runner.isRunning else {
                return NSApplication.TerminateReply.terminateNow
            }
            let alert = NSAlert()
            alert.messageText = "샌드박스를 종료할까요?"
            alert.informativeText = "실행 중인 일회용 샌드박스가 종료되고, 변경사항은 모두 폐기됩니다."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "종료")
            alert.addButton(withTitle: "취소")
            guard alert.runModal() == .alertFirstButtonReturn else {
                return NSApplication.TerminateReply.terminateCancel
            }
            runner.stop()
            Task { @MainActor in
                for _ in 0..<50 {
                    if !runner.isRunning { break }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return NSApplication.TerminateReply.terminateLater
        }
    }
}
