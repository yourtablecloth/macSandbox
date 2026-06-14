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

extension Notification.Name {
    /// 약관 동의 상태가 바뀜(동의/철회) — ContentView가 게이트를 다시 평가한다.
    static let msbxConsentChanged = Notification.Name("msbx.consentChanged")
}

/// 사용 약관(Terms of Use) 동의 게이트 + 기록.
///
/// - 약관 본문은 언어별 마크다운(`Terms.md`)으로 번들링되고, 버전은 `currentVersion`으로 고정한다.
/// - 최초 실행(또는 약관 버전 상승) 시 동의가 필요하다(`needsConsent`).
/// - 동의/철회 시: 버전·시점을 **UserDefaults**(게이트 판단용)와 **Application Support의
///   append-only 감사 로그**(durable 기록)에 남기고, 변경을 알린다(`.msbxConsentChanged`).
/// - 옵션에서 **철회**(`withdraw`)하면 기록이 지워지고 즉시 동의 게이트가 다시 뜬다.
enum ConsentStore {
    /// 번들된 약관 본문(`Terms.md` 상단 표기)과 일치시켜야 한다. 약관을 바꾸면 올린다.
    static let currentVersion = "1.0"

    private static let kVersion = "consent.termsVersion"
    private static let kDate = "consent.agreedAt"

    /// 마지막으로 동의한 약관 버전(없으면 nil).
    static var agreedVersion: String? { UserDefaults.standard.string(forKey: kVersion) }
    /// 마지막 동의 시점(ISO8601, 없으면 nil).
    static var agreedAt: String? { UserDefaults.standard.string(forKey: kDate) }
    /// 마지막 동의 시점(Date, 없으면 nil) — UI 표시용.
    static var agreedAtDate: Date? { agreedAt.flatMap { ISO8601DateFormatter().date(from: $0) } }

    /// 현재 버전 약관에 동의한 기록이 없으면 true(최초 실행·버전 상승·철회 후).
    static var needsConsent: Bool { agreedVersion != currentVersion }

    /// 현재 언어의 약관 마크다운(없으면 nil — UI는 폴백 안내를 표시).
    /// 본문은 `Terms/<lang>.md`로 번들링(`.lproj`의 UI 문자열과 분리, Package.swift `.copy("Terms")`).
    static func termsMarkdown() -> String? { bundledMarkdown(inSubdirectory: "Terms") }

    /// 동의 기록 — UserDefaults + 감사 로그 파일 + 변경 통지.
    static func recordAgreement() {
        let iso = ISO8601DateFormatter().string(from: Date())
        let d = UserDefaults.standard
        d.set(currentVersion, forKey: kVersion)
        d.set(iso, forKey: kDate)
        appendAuditRecord(event: "terms_agreed", version: currentVersion, at: iso)
        NotificationCenter.default.post(name: .msbxConsentChanged, object: nil)
    }

    /// 동의 철회 — 기록을 지우고 감사 로그에 철회 이력을 남긴 뒤 변경을 알린다.
    /// 이후 `needsConsent`가 true가 되어 동의 게이트가 다시 표시된다(옵션에서 호출).
    static func withdraw() {
        let prev = agreedVersion
        let iso = ISO8601DateFormatter().string(from: Date())
        let d = UserDefaults.standard
        d.removeObject(forKey: kVersion)
        d.removeObject(forKey: kDate)
        appendAuditRecord(event: "terms_withdrawn", version: prev ?? "", at: iso)
        NotificationCenter.default.post(name: .msbxConsentChanged, object: nil)
    }

    /// Application Support/MacSandbox/consent-log.jsonl 에 한 줄(JSON) append.
    /// 동의/철회 이력을 앱 삭제 전까지 보존(감사/분쟁 대비). 실패해도 상태는 UserDefaults에 남는다.
    private static func appendAuditRecord(event: String, version: String, at iso: String) {
        let appVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
        let record: [String: String] = [
            "event": event,
            "at": iso,
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
