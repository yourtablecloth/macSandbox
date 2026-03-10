import Foundation

/// VM의 현재 상태를 나타내는 열거형
enum VMState: String, Codable {
    case stopped = "stopped"
    case starting = "starting"
    case running = "running"
    case stopping = "stopping"
    case error = "error"

    var displayName: String {
        switch self {
        case .stopped: return "정지됨"
        case .starting: return "시작 중..."
        case .running: return "실행 중"
        case .stopping: return "종료 중..."
        case .error: return "오류"
        }
    }

    var isTransitioning: Bool {
        self == .starting || self == .stopping
    }
}
