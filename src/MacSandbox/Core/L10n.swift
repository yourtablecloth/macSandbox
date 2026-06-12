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

import Foundation

/// 제품 브랜드 (로컬라이즈하지 않는 고정 명칭)
enum Brand {
    static let appName = "macSandbox for Windows"
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
/// `Bundle.module.localizedString`의 언어 선택은 **메인 번들이 선언한 로컬라이제이션**에
/// 제약된다 — bare 실행 파일(swift run)이나 CFBundleLocalizations가 없는 .app에서는
/// 시스템 언어가 한국어여도 개발 언어(en)로 떨어진다. 그래서 여기서는 직접
/// `Locale.preferredLanguages`(또는 옵션의 명시 언어)를 리소스 번들의 가용 언어와 매칭해
/// 해당 `.lproj` 번들을 로드한다. 언어 옵션 변경은 앱 재시작 후 적용(시작 시 1회 해석).
private final class L10nStore {
    static let shared = L10nStore()
    let bundle: Bundle

    private init() {
        let code = Self.resolvedCode()
        if code != "en",
           let path = Bundle.module.path(forResource: code, ofType: "lproj"),
           let lproj = Bundle(path: path) {
            bundle = lproj
        } else {
            bundle = .module   // en(개발 언어) — 모듈 기본 조회로 충분
        }
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
