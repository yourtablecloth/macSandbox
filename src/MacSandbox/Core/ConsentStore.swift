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

/// 사용 약관(Terms of Use) 동의 게이트 + 기록.
///
/// - 약관 본문은 언어별 마크다운(`Terms.md`)으로 번들링되고, 버전은 `currentVersion`으로 고정한다.
/// - 최초 실행(또는 약관 버전 상승) 시 동의가 필요하다(`needsConsent`).
/// - 동의 시: 동의한 버전·시점을 **UserDefaults**(게이트 판단용)와 **Application Support의
///   append-only 감사 로그**(durable 기록)에 남긴다.
enum ConsentStore {
    /// 번들된 약관 본문(`Terms.md` 상단 표기)과 일치시켜야 한다. 약관을 바꾸면 올린다.
    static let currentVersion = "1.0"

    private static let kVersion = "consent.termsVersion"
    private static let kDate = "consent.agreedAt"

    /// 마지막으로 동의한 약관 버전(없으면 nil).
    static var agreedVersion: String? { UserDefaults.standard.string(forKey: kVersion) }
    /// 마지막 동의 시점(ISO8601, 없으면 nil).
    static var agreedAt: String? { UserDefaults.standard.string(forKey: kDate) }

    /// 현재 버전 약관에 동의한 기록이 없으면 true(최초 실행 또는 버전 상승).
    static var needsConsent: Bool { agreedVersion != currentVersion }

    /// 현재 언어의 약관 마크다운(없으면 nil — UI는 폴백 안내를 표시).
    static func termsMarkdown() -> String? { localizedMarkdown("Terms") }

    /// 동의 기록 — UserDefaults + 감사 로그 파일.
    static func recordAgreement() {
        let iso = ISO8601DateFormatter().string(from: Date())
        let d = UserDefaults.standard
        d.set(currentVersion, forKey: kVersion)
        d.set(iso, forKey: kDate)
        appendAuditRecord(version: currentVersion, at: iso)
    }

    /// Application Support/MacSandbox/consent-log.jsonl 에 한 줄(JSON) append.
    /// 동의 이력을 앱 삭제 전까지 보존(감사/분쟁 대비). 실패해도 동의 자체는 UserDefaults에 남는다.
    private static func appendAuditRecord(version: String, at iso: String) {
        let appVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
        let record: [String: String] = [
            "event": "terms_agreed",
            "agreedAt": iso,
            "termsVersion": version,
            "appVersion": appVersion,
            "language": currentLanguageCode(),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: record),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"

        let fm = FileManager.default
        let dir = SandboxPaths.appSupport
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("consent-log.jsonl")
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url, options: .atomic)
        }
    }
}
