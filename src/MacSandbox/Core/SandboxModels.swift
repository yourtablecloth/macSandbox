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
        case .idle: return "대기"
        case .preparingDisk: return "디스크 생성"
        case .preparingFirmware: return "UEFI 펌웨어 준비"
        case .generatingUnattend: return "무인 설치 미디어 생성"
        case .installing: return "Windows 무인 설치 진행 중"
        case .finalizing: return "베이스라인 마무리"
        case .completed: return "완료"
        case .failed(let m): return "실패: \(m)"
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
