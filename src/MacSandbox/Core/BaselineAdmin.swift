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

import AppKit

/// 베이스라인 관리(재구축/파기) 오케스트레이터.
///
/// - 재구축: 확인 → (실행 중이면) 샌드박스 정지 대기 → 빌드 화면으로 전환(`rebuildMode`).
///   실제 교체는 BaselineBuilder.build가 수행한다(기존 베이스라인 디렉토리 삭제 후 새로 설치).
/// - 파기: 확인 → 정지 대기 → 베이스라인 디렉토리 삭제 → 라우터가 자연히 빌드 화면을 띄운다.
@MainActor
final class BaselineAdmin: ObservableObject {

    /// true면 베이스라인이 준비돼 있어도 빌드 화면을 보여준다(재구축 진입).
    @Published var rebuildMode = false
    /// 정지 대기/삭제 진행 중 — 메뉴 중복 실행 방지.
    @Published private(set) var busy = false

    func hasBaseline() -> Bool {
        FileManager.default.fileExists(atPath: SandboxPaths.baselineMetadataPath.path)
    }

    /// 메뉴/버튼: 베이스라인 재구축. 확인 후 샌드박스를 정지하고 빌드 화면으로 전환한다.
    func requestRebuild(runner: SandboxRunner) {
        guard !busy, !rebuildMode else { return }
        guard confirm(title: L("admin.rebuild.title"),
                      message: L("admin.rebuild.message"),
                      confirmTitle: L("admin.rebuild.confirm")) else { return }
        busy = true
        Task { @MainActor in
            await self.stopAndWait(runner: runner)
            self.rebuildMode = true
            self.busy = false
        }
    }

    /// 메뉴/버튼: 베이스 이미지 파기. 확인 후 샌드박스를 정지하고 베이스라인 디렉토리를 삭제한다.
    func requestDestroy(runner: SandboxRunner) {
        guard !busy else { return }
        guard confirm(title: L("admin.destroy.title"),
                      message: L("admin.destroy.message"),
                      confirmTitle: L("admin.destroy.confirm"),
                      destructive: true) else { return }
        busy = true
        Task { @MainActor in
            await self.performDestroy(runner: runner)
            self.busy = false
        }
    }

    /// 약관 동의 철회: **확인 없이 즉시** 샌드박스를 정지하고 베이스 이미지를 삭제한다.
    /// (철회 확인 단계에서 이미 이 파괴적 결과를 경고하므로 추가 확인을 받지 않는다.)
    func destroyForConsentWithdrawal(runner: SandboxRunner) {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            await self.performDestroy(runner: runner)
            self.busy = false
        }
    }

    /// 정지 대기 + 베이스 이미지 삭제(공통). 호출자가 사용자 확인을 책임진다.
    private func performDestroy(runner: SandboxRunner) async {
        await stopAndWait(runner: runner)
        try? FileManager.default.removeItem(at: SandboxPaths.baselineDir)
        rebuildMode = true   // 라우터 갱신 트리거(베이스라인이 없으니 빌드 화면)
    }

    /// 빌드 완료/뒤로 가기 — 일반 라우팅(샌드박스 자동 시작)으로 복귀.
    func leaveRebuildMode() {
        rebuildMode = false
    }

    private func stopAndWait(runner: SandboxRunner) async {
        guard runner.isRunning else { return }
        runner.stop()
        for _ in 0..<50 {              // 최대 ~10초 (Lifecycle의 종료 대기와 동일)
            if !runner.isRunning { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func confirm(title: String, message: String, confirmTitle: String,
                         destructive: Bool = false) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = destructive ? .critical : .warning
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: L("common.cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}
