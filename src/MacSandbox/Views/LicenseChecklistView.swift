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

/// Windows license confirmation checklist — shown every time a base image build is started.
///
/// Rationale (Microsoft licensing documents):
/// - Windows 11 EULA "Use in a virtualized environment": one license = one
///   instance on one device, physical or virtual. Additional virtual devices require separate licenses.
/// - OEM licenses are bound to the original hardware — generally no separate virtualization use rights.
/// - Retail (FPP) licenses may be used in a VM on a personal device assigned to a single user.
///   Organizational virtual desktop (VDI) access requires a separate license such as VDA or Microsoft 365 E3+.
struct LicenseChecklistView: View {
    @Environment(\.dismiss) private var dismiss
    /// Called when 'Agree and start build' is pressed after agreeing to all items.
    let onConfirm: () -> Void

    private static let itemKeys = [
        "license.item.noOS",        // This app does not provide an OS/key/usage rights
        "license.item.ownLicense",  // Official ISO + a valid license held
        "license.item.vmRights",    // 1 license = 1 instance; confirm OEM VM-usage restrictions
        "license.item.personalUse", // Personal retail is scoped to personal devices/home use; organizational VDI requires VDA, etc.
        "license.item.eula",        // Responsibility for EULA/activation compliance is the user's
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
