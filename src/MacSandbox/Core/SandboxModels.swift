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

/// Settings used for the baseline 1-round installation.
/// Defaults are based on standard retail MacBook Air specs (8 cores · 16GB · 256GB).
struct InstallConfig {
    var isoPath: String
    var diskSizeGB: Int = 256
    var cpuCores: Int = 8
    var memoryMB: Int = 16384
    var locale: String = "ko-KR"
    /// install.wim edition name that DISM will apply (`dism /Name`). The WIM image name is usually fixed in English.
    var imageEdition: String = "Windows 11 Pro"
}

/// Single baseline metadata (saved as metadata.json)
struct BaselineMetadata: Codable {
    static let currentSchemaVersion = 3

    var schemaVersion: Int
    var credentialID: String
    var name: String
    var diskPath: String
    var efiVarsPath: String
    var createdAt: Date
    var diskSizeGB: Int
    var locale: String
    var status: Status

    enum Status: String, Codable {
        case creating, ready, error

        var label: String {
            switch self {
            case .creating: return L("baseline.status.creating")
            case .ready: return L("baseline.status.ready")
            case .error: return L("baseline.status.error")
            }
        }
    }
}

/// Baseline build progress phases
enum BuildPhase: Equatable {
    case idle
    case preparingDisk
    case preparingFirmware
    case generatingUnattend
    case installing
    case finalizing
    case completed
    case failed(String)

    var label: String {
        switch self {
        case .idle: return L("phase.idle")
        case .preparingDisk: return L("phase.preparingDisk")
        case .preparingFirmware: return L("phase.preparingFirmware")
        case .generatingUnattend: return L("phase.generatingUnattend")
        case .installing: return L("phase.installing")
        case .finalizing: return L("phase.finalizing")
        case .completed: return L("phase.completed")
        case .failed(let m): return L("phase.failed", m)
        }
    }

    var fraction: Double {
        switch self {
        case .idle: return 0
        case .preparingDisk: return 0.08
        case .preparingFirmware: return 0.14
        case .generatingUnattend: return 0.20
        case .installing: return 0.45
        case .finalizing: return 0.92
        case .completed: return 1.0
        case .failed: return 0
        }
    }
}
