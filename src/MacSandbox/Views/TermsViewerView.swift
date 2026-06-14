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

/// 사용 약관 뷰어 — 메뉴에서 언제든 열 수 있는 읽기 전용 다이얼로그(동의 게이트와 별개).
/// 언어 선택 메뉴로 번들된 모든 언어 버전(en/ko/ja/de/es/fr)을 볼 수 있다.
struct TermsViewerView: View {
    @Environment(\.dismiss) private var dismiss
    /// 처음엔 현재 앱 언어로 표시, 사용자가 메뉴로 전환 가능.
    @State private var language: String = currentLanguageCode()

    /// 약관 뷰어가 제공하는 언어 목록(자동 제외 — 구체 언어만).
    private let languages = AppLanguage.allCases.filter { $0 != .auto }

    private var terms: String {
        bundledMarkdown(inSubdirectory: "Terms", language: language) ?? L("consent.unavailable")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
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

            HStack {
                Spacer()
                Button(L("common.close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        // 창 크기 조절로 본문이 폭에 맞춰 word-wrap된다(읽기 편한 기본값 + 자유 리사이즈).
        .frame(minWidth: 520, idealWidth: 700, maxWidth: .infinity,
               minHeight: 460, idealHeight: 640, maxHeight: .infinity)
    }
}
