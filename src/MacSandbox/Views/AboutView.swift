// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Copyright (C) 2026 Nam Jung Hyun (rkttu) <rkttu.official@gmail.com>
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

/// '앱 정보' 대화상자 — 브랜드/버전/라이선스(이중 라이선스)/서드파티 구성요소를 보여준다.
struct AboutView: View {
    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (v, b) {
        case let (v?, b?) where v != b: return "\(v) (\(b))"
        case let (v?, _): return v
        default: return "dev"
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 76, height: 76)

            VStack(spacing: 3) {
                Text(Brand.appName).font(.title2).fontWeight(.semibold)
                Text(L("about.version", version)).font(.callout).foregroundStyle(.secondary)
            }

            Text(L("about.tagline"))
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                infoRow(title: L("about.license.title"), body: L("about.license.body"))
                infoRow(title: L("about.thirdparty.title"), body: L("about.thirdparty.body"))
            }

            Button(L("about.viewLicenses")) { openLicensingDocument() }
                .controlSize(.small)

            Text(verbatim: "© 2026 Nam Jung Hyun (rkttu)")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(width: 440)
    }

    private func infoRow(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
            Text(body).font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// LICENSING.md를 연다 — .app 번들 Resources 우선, 개발 환경은 실행 파일 상위에서 탐색.
    private func openLicensingDocument() {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("LICENSING.md"))
        }
        var dir = Bundle.main.executableURL?.deletingLastPathComponent()
        for _ in 0..<8 {
            guard let current = dir else { break }
            candidates.append(current.appendingPathComponent("LICENSING.md"))
            dir = current.deletingLastPathComponent()
        }
        if let found = candidates.first(where: { fm.fileExists(atPath: $0.path) }) {
            NSWorkspace.shared.open(found)
        }
    }
}
