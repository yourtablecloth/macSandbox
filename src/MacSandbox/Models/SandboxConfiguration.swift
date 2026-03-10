import Foundation

/// 샌드박스 VM 설정을 정의하는 모델 (.msb 파일에 대응)
struct SandboxConfiguration: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String = "Windows Sandbox"

    // 게스트 아키텍처
    var guestArch: GuestArchitecture = .aarch64

    // CPU / 메모리
    var cpuCores: Int = 2
    var memoryMB: Int = 4096

    // 디스크
    var baseImagePath: String = ""
    var diskSizeGB: Int = 40

    // 네트워킹
    var networkingEnabled: Bool = true
    var networkMode: NetworkMode = .userMode

    // 디스플레이
    var displayResolution: DisplayResolution = .hd1080
    var enableVGA: Bool = true

    // 공유 폴더
    var sharedFolders: [SharedFolder] = []

    // QEMU 옵션
    var enableKVM: Bool = false  // macOS에서는 HVF 사용
    var enableHVF: Bool = true
    var additionalQEMUArgs: [String] = []

    // 샌드박스 동작
    var disposable: Bool = true  // 종료 시 변경사항 폐기
    // Windows ESD/ISO
    var windowsISOPath: String = ""  // 다운로드된 Windows ARM64 ISO 경로

    enum GuestArchitecture: String, Codable, CaseIterable {
        case aarch64 = "aarch64"
        case x86_64 = "x86_64"

        var displayName: String {
            switch self {
            case .aarch64: return "ARM64 (HVF 네이티브)"
            case .x86_64: return "x86_64 (에뮬레이션)"
            }
        }

        var qemuBinaryName: String {
            switch self {
            case .aarch64: return "qemu-system-aarch64"
            case .x86_64: return "qemu-system-x86_64"
            }
        }
    }
    enum NetworkMode: String, Codable, CaseIterable {
        case userMode = "user"       // QEMU user-mode (SLIRP)
        case bridged = "bridged"     // 브릿지 네트워킹
        case none = "none"           // 네트워크 없음

        var displayName: String {
            switch self {
            case .userMode: return "NAT (User Mode)"
            case .bridged: return "브릿지"
            case .none: return "없음"
            }
        }
    }

    enum DisplayResolution: String, Codable, CaseIterable {
        case hd720 = "1280x720"
        case hd1080 = "1920x1080"
        case qhd = "2560x1440"

        var displayName: String {
            switch self {
            case .hd720: return "720p (1280×720)"
            case .hd1080: return "1080p (1920×1080)"
            case .qhd: return "1440p (2560×1440)"
            }
        }

        var width: Int {
            switch self {
            case .hd720: return 1280
            case .hd1080: return 1920
            case .qhd: return 2560
            }
        }

        var height: Int {
            switch self {
            case .hd720: return 720
            case .hd1080: return 1080
            case .qhd: return 1440
            }
        }
    }
}

/// 호스트 ↔ 게스트 공유 폴더
struct SharedFolder: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var hostPath: String
    var guestMountTag: String
    var readOnly: Bool = false
}
