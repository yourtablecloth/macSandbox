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

/// Windows 라이선스 확인 체크리스트 — 베이스 이미지 빌드를 시작할 때마다 표시한다.
///
/// 근거(Microsoft 라이선스 문서):
/// - Windows 11 EULA "가상 환경에서의 사용": 라이선스 1개 = 물리/가상 불문 장치 1대의
///   인스턴스 1개. 추가 가상 장치는 별도 라이선스 필요.
/// - OEM 라이선스는 원래 기기에 귀속 — 일반적으로 별도 가상화 사용권 없음.
/// - 리테일(FPP) 라이선스는 단일 사용자에게 할당된 개인 장치의 VM에 사용 가능.
///   조직의 가상 데스크톱(VDI) 접근은 VDA 또는 Microsoft 365 E3+ 등 별도 라이선스 필요.
struct LicenseChecklistView: View {
    @Environment(\.dismiss) private var dismiss
    /// 모든 항목 동의 후 '동의하고 빌드 시작'을 누르면 호출된다.
    let onConfirm: () -> Void

    private static let itemKeys = [
        "license.item.noOS",        // 이 앱은 OS/키/사용권을 제공하지 않음
        "license.item.ownLicense",  // 공식 ISO + 적법한 라이선스 보유
        "license.item.vmRights",    // 1라이선스=1인스턴스, OEM의 VM 사용 제약 확인
        "license.item.personalUse", // 개인 리테일은 개인 기기·가정 범위, 조직 VDI는 VDA 등 필요
        "license.item.eula",        // EULA·정품 인증 준수 책임은 사용자에게
    ]
    @State private var checked = Array(repeating: false, count: itemKeys.count)

    private var allChecked: Bool { checked.allSatisfy { $0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.shield")
                    .font(.title2).foregroundStyle(.tint)
                Text(L("license.title")).font(.title3).fontWeight(.semibold)
            }

            Text(L("license.intro"))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Self.itemKeys.indices, id: \.self) { i in
                    Toggle(isOn: $checked[i]) {
                        Text(L(Self.itemKeys[i]))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .padding(14)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

            Text(L("license.footer"))
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button(L("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(L("license.confirm")) {
                    dismiss()
                    onConfirm()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!allChecked)
            }
        }
        .padding(22)
        .frame(width: 560)
    }
}
