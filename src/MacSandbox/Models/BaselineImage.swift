import Foundation

/// 베이스라인 이미지의 상태
enum BaselineStatus: String, Codable {
    case creating = "creating"
    case ready = "ready"
    case error = "error"
    case deleted = "deleted"

    var displayName: String {
        switch self {
        case .creating: return "생성 중"
        case .ready: return "사용 가능"
        case .error: return "오류"
        case .deleted: return "삭제됨"
        }
    }
}

/// 설치 완료된 Windows 베이스라인 디스크 이미지 메타데이터
struct BaselineImage: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var diskPath: String
    var efiVarsPath: String
    var createdAt: Date = Date()
    var windowsVersion: String
    var diskSizeGB: Int
    var architecture: SandboxConfiguration.GuestArchitecture
    var status: BaselineStatus
}
