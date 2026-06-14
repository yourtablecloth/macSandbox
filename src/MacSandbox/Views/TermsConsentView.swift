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

/// 사용 약관 동의 시트 — 최초 실행/약관 버전 상승 시 표시. 동의 전엔 앱을 쓸 수 없다.
/// 약관 본문은 현재 언어의 번들된 마크다운(Terms.md)을 적당히 렌더링해 보여준다.
struct TermsConsentView: View {
    /// 동의(체크 + 계속) 시 호출 — 호출자가 기록·게이트 해제를 수행한다.
    let onAgree: () -> Void

    @State private var agreed = false

    private var terms: String {
        ConsentStore.termsMarkdown() ?? L("consent.unavailable")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L("consent.title")).font(.title2).fontWeight(.semibold)
                Text(L("consent.version", ConsentStore.currentVersion))
                    .font(.callout).foregroundStyle(.secondary)
            }

            ScrollView {
                MarkdownView(markdown: terms)
                    .padding(.trailing, 6)
            }
            .frame(height: 360)
            .padding(12)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))

            Toggle(isOn: $agreed) {
                Text(L("consent.checkbox"))
            }
            .toggleStyle(.checkbox)

            HStack {
                Button(L("consent.quit")) { NSApp.terminate(nil) }
                Spacer()
                Button(L("consent.continue")) { onAgree() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!agreed)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 620)
        .interactiveDismissDisabled(true)   // 동의/종료 외 경로로 닫히지 않게
    }
}
