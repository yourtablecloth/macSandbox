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

/// 베이스라인 1-round 설치에 사용하는 설정.
/// 기본값은 시중 표준 맥북 에어 사양(8코어 · 16GB · 256GB)을 기준으로 잡는다.
struct InstallConfig {
    var isoPath: String
    var diskSizeGB: Int = 256
    var cpuCores: Int = 8
    var memoryMB: Int = 16384
    var locale: String = "ko-KR"
    /// DISM이 적용할 install.wim 에디션 이름 (`dism /Name`). WIM 이미지 이름은 보통 영어 고정.
    var imageEdition: String = "Windows 11 Pro"
}

/// 단일 베이스라인 메타데이터 (metadata.json으로 저장)
struct BaselineMetadata: Codable {
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

/// 베이스라인 빌드 진행 단계
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
