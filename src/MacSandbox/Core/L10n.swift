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

/// 제품 브랜드 (로컬라이즈하지 않는 고정 명칭)
enum Brand {
    static let appName = "macSandbox for Windows"
}

/// 외부 링크 (도움말 등). GitHub Pages 사이트에 호스팅.
enum HelpLinks {
    static let help = "https://yourtablecloth.github.io/macSandbox/help/"
}

/// 앱 표시 언어 옵션 — '자동(시스템 설정)'이 기본이며, 명시 선택 시 해당 언어로 고정.
enum AppLanguage: String, CaseIterable, Identifiable {
    case auto, en, ko, ja, de, es, fr
    var id: String { rawValue }

    /// 옵션 UI 표시명. 언어 고유 표기(native name)는 관례상 번역하지 않는다.
    var label: String {
        switch self {
        case .auto: return L("options.lang.auto")
        case .en: return "English"
        case .ko: return "한국어"
        case .ja: return "日本語"
        case .de: return "Deutsch"
        case .es: return "Español"
        case .fr: return "Français"
        }
    }
}

/// 로컬라이제이션 해석기.
///
/// 두 가지 이유로 `Bundle.module`을 쓰지 않고 리소스 번들을 직접 찾는다:
/// 1. `Bundle.module.localizedString`의 언어 선택은 메인 번들이 선언한 로컬라이제이션에
///    제약돼, 시스템이 한국어여도 개발 언어(en)로 떨어진다 → 직접 `.lproj`를 로드해 우회.
/// 2. SwiftPM이 생성하는 `Bundle.module` 접근자는 리소스 번들을 `Bundle.main.bundleURL`
///    (= .app 루트) 또는 **빌드 시점의 절대 .build 경로**에서 찾고, 못 찾으면 `fatalError`다.
///    수동 패키징한 .app은 번들을 `Contents/Resources/`에 두므로 접근자가 못 찾고, 폴백
///    .build 경로는 빌드한 개발 머신에만 존재한다 → **배포본을 다른 머신에서 실행하면 즉시
///    크래시**. 그래서 `Contents/Resources`·실행파일 디렉토리를 직접 탐색하고, 실패해도
///    `Bundle.main`으로 폴백(크래시 없음)한다.
/// 언어 옵션 변경은 앱 재시작 후 적용(시작 시 1회 해석).
private final class L10nStore {
    static let shared = L10nStore()
    let bundle: Bundle
    let code: String   // 해석된 언어 코드(en/ko/...) — 리소스 로드·감사 기록에 사용

    private init() {
        let base = Self.resourceBundle()
        let resolved = Self.resolvedCode()
        self.code = resolved
        if resolved != "en",
           let path = base.path(forResource: resolved, ofType: "lproj"),
           let lproj = Bundle(path: path) {
            bundle = lproj
        } else {
            bundle = base   // en(기본) 또는 번들 탐색 실패 시 폴백
        }
    }

    /// 번들 하위 폴더(`subdir`)에서 `<lang>.md`를 `codes` 순으로 찾아 읽는다(없으면 nil).
    /// 약관 등 언어별 마크다운은 `.lproj`(UI 문자열)와 분리된 전용 폴더(예: `Terms/`)에 두고
    /// Package.swift의 `.copy`로 번들에 동봉된다.
    static func markdown(inSubdirectory subdir: String, codes: [String]) -> String? {
        let root = resourceBundle()
        for code in codes {
            if let url = root.url(forResource: code, withExtension: "md", subdirectory: subdir),
               let text = try? String(contentsOf: url, encoding: .utf8) {
                return text
            }
        }
        return nil
    }

    /// SwiftPM 리소스 번들(`MacSandbox_MacSandbox.bundle`)을 직접 찾는다.
    /// .app(Contents/Resources)·CLI/swift run(실행파일 디렉토리)·번들 루트를 순서대로 탐색하고,
    /// 어디서도 못 찾으면 메인 번들로 폴백한다(절대 fatalError 하지 않음).
    private static func resourceBundle() -> Bundle {
        let name = "MacSandbox_MacSandbox.bundle"
        let candidates: [URL?] = [
            Bundle.main.resourceURL,                                  // .app/Contents/Resources
            Bundle.main.bundleURL,                                    // .app 루트 / CLI 디렉토리
            Bundle.main.executableURL?.deletingLastPathComponent(),  // swift run 실행파일 디렉토리
        ]
        for case let dir? in candidates {
            if let b = Bundle(url: dir.appendingPathComponent(name)) { return b }
        }
        return .main
    }

    private static func resolvedCode() -> String {
        let available = Set(AppLanguage.allCases.map(\.rawValue)).subtracting(["auto"])
        // 1) 옵션에서 명시 지정한 언어
        if let pref = UserDefaults.standard.string(forKey: AppOptions.kLanguage),
           pref != AppLanguage.auto.rawValue, available.contains(pref) {
            return pref
        }
        // 2) 자동 — OS 언어 설정 순서대로 매칭("ko-KR" → "ko")
        for lang in Locale.preferredLanguages {
            let code = String(lang.prefix(2)).lowercased()
            if available.contains(code) { return code }
        }
        return "en"
    }
}

/// UI 로컬라이제이션 헬퍼.
/// 기본 영어(en) + ko/ja/de/es/fr — 옵션 미지정 시 OS 언어 설정을 따른다.
func L(_ key: String) -> String {
    L10nStore.shared.bundle.localizedString(forKey: key, value: nil, table: nil)
}

/// 포맷 인자 버전 (`%@`, `%d` — 번역에서 순서가 바뀌면 `%1$@` 표기 사용)
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), locale: Locale.current, arguments: args)
}

/// 현재 해석된 언어 코드 (감사 기록 등).
func currentLanguageCode() -> String { L10nStore.shared.code }

/// 번들 하위 폴더(`subdir`)의 언어별 마크다운(`<lang>.md`)을 현재 언어로 읽는다(없으면 en, 그래도 없으면 nil).
func bundledMarkdown(inSubdirectory subdir: String) -> String? {
    L10nStore.markdown(inSubdirectory: subdir, codes: [currentLanguageCode(), "en"])
}

/// 지정한 언어(`code`)의 마크다운을 읽는다(없으면 en 폴백). 약관 뷰어의 언어 전환에 사용.
func bundledMarkdown(inSubdirectory subdir: String, language code: String) -> String? {
    L10nStore.markdown(inSubdirectory: subdir, codes: [code, "en"])
}
