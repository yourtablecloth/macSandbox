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

/// Terms of use viewer — a read-only dialog that can be opened from the menu at any time (separate from the consent gate).
/// All bundled language versions (en/ko/ja/de/es/fr) can be viewed via the language selection menu.
struct TermsViewerView: View {
    @Environment(\.dismiss) private var dismiss
    /// Initially shown in the current app language; the user can switch it via the menu.
    @State private var language: String = currentLanguageCode()

    /// The list of languages the terms viewer offers (auto excluded — concrete languages only).
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
                    .id(language)   // Reset scroll to the top when the language changes
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
        // Resizing the window word-wraps the body to the width (readable defaults + free resizing).
        .frame(minWidth: 520, idealWidth: 700, maxWidth: .infinity,
               minHeight: 460, idealHeight: 640, maxHeight: .infinity)
    }
}
