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
    /// Terms consent state changed (consent/withdrawal) — ContentView re-evaluates the gate.
    static let msbxConsentChanged = Notification.Name("msbx.consentChanged")
}

/// Terms of Use consent gate + record.
///
/// - The terms text is bundled as per-language markdown (`Terms/<lang>.md`). **The current version is
///   automatically extracted from the "Version X.Y" notation in the English edition (`Terms/en.md`)**, so when
///   revising the terms, just bump the version in the markdown to re-request consent from existing consenters
///   without code changes (prevents version drift).
/// - On first run (or when the terms version is bumped), consent is required (`needsConsent`).
/// - On consent/withdrawal: record the version and timestamp in **UserDefaults** (for the gate decision) and an
///   **append-only audit log in Application Support** (durable record), and announce the change (`.msbxConsentChanged`).
/// - **Withdrawing** (`withdraw`) from the options clears the record and immediately re-shows the consent gate.
enum ConsentStore {
    /// Current terms version — extracted from "Version X.Y" in the English terms (`Terms/en.md`) (falls back if parsing fails).
    /// If it differs from an existing consenter's `agreedVersion`, re-consent is requested.
    static let currentVersion: String = parsedTermsVersion() ?? fallbackVersion

    /// Version to use if parsing fails — kept in sync with the bundled terms' current notation (parsing almost always succeeds).
    private static let fallbackVersion = "1.1"

    /// Extracts just the version number from a notation like "Version 1.1" in `Terms/en.md`.
    private static func parsedTermsVersion() -> String? {
        guard let md = bundledMarkdown(inSubdirectory: "Terms", language: "en"),
              let r = md.range(of: #"Version\s+[0-9]+(\.[0-9]+)*"#, options: .regularExpression)
        else { return nil }
        let v = md[r].replacingOccurrences(of: "Version", with: "").trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }

    private static let kVersion = "consent.termsVersion"
    private static let kDate = "consent.agreedAt"

    /// Last agreed terms version (nil if none).
    static var agreedVersion: String? { UserDefaults.standard.string(forKey: kVersion) }
    /// Last consent timestamp (ISO8601, nil if none).
    static var agreedAt: String? { UserDefaults.standard.string(forKey: kDate) }
    /// Last consent timestamp (Date, nil if none) — for UI display.
    static var agreedAtDate: Date? { agreedAt.flatMap { ISO8601DateFormatter().date(from: $0) } }

    /// True if there is no record of consenting to the current version of the terms (first run / version bump / after withdrawal).
    static var needsConsent: Bool { agreedVersion != currentVersion }

    /// The terms markdown for the current language (nil if none — the UI shows fallback guidance).
    /// The body is bundled as `Terms/<lang>.md` (separate from the `.lproj` UI strings, Package.swift `.copy("Terms")`).
    static func termsMarkdown() -> String? { bundledMarkdown(inSubdirectory: "Terms") }

    /// Record consent — UserDefaults + audit log file + change notification.
    static func recordAgreement() {
        let iso = ISO8601DateFormatter().string(from: Date())
        let d = UserDefaults.standard
        d.set(currentVersion, forKey: kVersion)
        d.set(iso, forKey: kDate)
        appendAuditRecord(event: "terms_agreed", version: currentVersion, at: iso)
        NotificationCenter.default.post(name: .msbxConsentChanged, object: nil)
    }

    /// Withdraw consent — clear the record, leave a withdrawal entry in the audit log, then announce the change.
    /// Afterward `needsConsent` becomes true and the consent gate is shown again (called from the options).
    static func withdraw() {
        let prev = agreedVersion
        let iso = ISO8601DateFormatter().string(from: Date())
        let d = UserDefaults.standard
        d.removeObject(forKey: kVersion)
        d.removeObject(forKey: kDate)
        appendAuditRecord(event: "terms_withdrawn", version: prev ?? "", at: iso)
        NotificationCenter.default.post(name: .msbxConsentChanged, object: nil)
    }

    /// Appends one line (JSON) to Application Support/MacSandbox/consent-log.jsonl.
    /// Preserves the consent/withdrawal history until the app is deleted (for audit/dispute purposes). Even if this fails, the state remains in UserDefaults.
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
