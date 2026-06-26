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

/// Throttled log display pane.
/// It observes only the LogBuffer, so the parent views (boot overlay/build screen) are not re-rendered when the log updates.
struct LogPane: View {
    @ObservedObject var buffer: LogBuffer
    var height: CGFloat = 160

    var body: some View {
        GroupBox(L("common.log")) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(buffer.text.isEmpty ? L("common.log.empty") : buffer.text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("logbottom")
                }
                .frame(height: height)
                .onChange(of: buffer.text) { _, _ in
                    proxy.scrollTo("logbottom", anchor: .bottom)
                }
            }
            .padding(6)
        }
    }
}
