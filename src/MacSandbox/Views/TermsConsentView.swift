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
/// 약관 본문은 언어 선택기로 번들된 모든 언어(en/ko/ja/de/es/fr) 전문을 볼 수 있다(처음엔 현재 앱 언어).
/// 동의는 언어와 무관하게 동일 버전의 약관에 대한 것이다(각 언어판은 실질적으로 동등).
struct TermsConsentView: View {
    /// 동의(체크 + 계속) 시 호출 — 호출자가 기록·게이트 해제를 수행한다.
    let onAgree: () -> Void

    @State private var agreed = false
    /// 읽기 언어 — 처음엔 현재 앱 언어, 사용자가 메뉴로 전환 가능(UI 문구는 앱 언어 유지).
    @State private var language: String = currentLanguageCode()

    private let languages = AppLanguage.allCases.filter { $0 != .auto }

    private var terms: String {
        bundledMarkdown(inSubdirectory: "Terms", language: language) ?? L("consent.unavailable")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("consent.title")).font(.title2).fontWeight(.semibold)
                    Text(L("consent.version", ConsentStore.currentVersion))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Picker(L("options.language"), selection: $language) {
                    ForEach(languages) { lang in
                        Text(lang.label).tag(lang.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 180)
            }

            ScrollView {
                MarkdownView(markdown: terms)
                    .padding(.trailing, 6)
                    .id(language)   // 언어 전환 시 스크롤을 맨 위로 리셋
            }
            .frame(maxHeight: .infinity)
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
        .padding(24)
        .frame(maxWidth: 760)                          // 카드 폭 상한
        .frame(maxWidth: .infinity, maxHeight: .infinity)  // 창 전체를 채우고 중앙 정렬
    }
}
