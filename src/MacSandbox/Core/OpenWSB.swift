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

/// Coordinator that funnels `.wsb` file opening into one place.
///
/// Both the Finder file association (app delegate `application(_:open:)`) and the in-app "Configuration (.wsb)..." button
/// call here. ContentView observes changes to `token`, and on successful parsing immediately starts a new
/// sandbox (baseline ready + when not running), or shows an error on failure.
@MainActor
final class OpenWSB: ObservableObject {
    static let shared = OpenWSB()
    private init() {}

    /// Open-request token. Monotonically increasing — lets ContentView handle re-opening the same file again.
    @Published private(set) var token = 0
    /// Parsing result of the last request (only one of the two is valid).
    private(set) var pendingConfig: SandboxConfig?
    private(set) var errorMessage: String?

    /// Parses a `.wsb` URL and publishes the result (success=pendingConfig, failure=errorMessage). Notifies by incrementing the token.
    func open(_ urls: [URL]) {
        let wsb = urls.first { $0.pathExtension.lowercased() == "wsb" } ?? urls.first
        guard let url = wsb else { return }
        do {
            let cfg = try WSBConfig.load(path: url.path)
            pendingConfig = cfg
            errorMessage = nil
            AppLaunch.shared.markExplicit(cfg)   // so effectiveConfig() uses this configuration (including the launch path)
        } catch {
            pendingConfig = nil
            errorMessage = error.localizedDescription
        }
        token &+= 1
    }
}
