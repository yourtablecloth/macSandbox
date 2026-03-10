import Foundation

/// Setup Mode의 단계별 진행 상태
enum SetupProgress: Equatable {
    case idle
    case downloadingISO
    case preparingDisk
    case preparingDrivers
    case generatingUnattend
    case installingWindows
    case waitingForCompletion
    case finalizingBaseline
    case completed
    case failed(String)

    var displayName: String {
        switch self {
        case .idle: return "대기"
        case .downloadingISO: return "ISO 다운로드 중"
        case .preparingDisk: return "디스크 생성 중"
        case .preparingDrivers: return "드라이버 준비 중"
        case .generatingUnattend: return "무인 설치 설정 생성 중"
        case .installingWindows: return "Windows 설치 진행 중"
        case .waitingForCompletion: return "설치 완료 대기 중"
        case .finalizingBaseline: return "베이스라인 마무리 중"
        case .completed: return "완료"
        case .failed(let message): return "실패: \(message)"
        }
    }

    var isInProgress: Bool {
        switch self {
        case .idle, .completed, .failed:
            return false
        default:
            return true
        }
    }
}
