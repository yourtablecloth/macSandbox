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

/// `.wsb` 파일 열기를 한 곳으로 모으는 코디네이터.
///
/// Finder 파일 연결(앱 델리게이트 `application(_:open:)`)과 인앱 "구성(.wsb)..." 버튼이
/// 모두 여기를 호출한다. ContentView가 `token` 변화를 관찰해, 파싱에 성공하면 곧바로 새
/// 샌드박스를 시작(베이스라인 준비 + 미실행 시)하고, 실패하면 오류를 표시한다.
@MainActor
final class OpenWSB: ObservableObject {
    static let shared = OpenWSB()
    private init() {}

    /// 열기 요청 토큰. 단조 증가 — 같은 파일을 다시 열어도 ContentView가 처리하게 한다.
    @Published private(set) var token = 0
    /// 마지막 요청의 파싱 결과(둘 중 하나만 유효).
    private(set) var pendingConfig: SandboxConfig?
    private(set) var errorMessage: String?

    /// `.wsb` URL을 파싱해 결과를 게시(성공=pendingConfig, 실패=errorMessage). 토큰 증가로 통지.
    func open(_ urls: [URL]) {
        let wsb = urls.first { $0.pathExtension.lowercased() == "wsb" } ?? urls.first
        guard let url = wsb else { return }
        do {
            let cfg = try WSBConfig.load(path: url.path)
            pendingConfig = cfg
            errorMessage = nil
            AppLaunch.shared.markExplicit(cfg)   // effectiveConfig()가 이 구성을 쓰도록(런치 경로 포함)
        } catch {
            pendingConfig = nil
            errorMessage = error.localizedDescription
        }
        token &+= 1
    }
}
