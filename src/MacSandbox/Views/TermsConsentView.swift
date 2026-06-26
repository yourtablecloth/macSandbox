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

/// Terms of use consent sheet — shown on first launch / when the terms version is raised. The app cannot be used before consent.
/// The terms body can be read in full in all bundled languages (en/ko/ja/de/es/fr) via the language picker (initially the current app language).
/// Consent applies to the same version of the terms regardless of language (each language edition is effectively equivalent).
struct TermsConsentView: View {
    /// Called on consent (check + continue) — the caller records it and dismisses the gate.
    let onAgree: () -> Void

    @State private var agreed = false
    /// Reading language — initially the current app language; the user can switch it via the menu (the UI wording stays in the app language).
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
                    .id(language)   // Reset scroll to the top when the language changes
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
        .frame(maxWidth: 760)                          // Card width cap
        .frame(maxWidth: .infinity, maxHeight: .infinity)  // Fill the whole window and center
    }
}
