import Foundation

/// qcow2 디스크 이미지 생성 및 관리 서비스
final class DiskImageService {
    private let sandboxDirectory: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.sandboxDirectory = appSupport.appendingPathComponent("MacSandbox", isDirectory: true)
    }

    /// 앱 데이터 디렉토리 확인/생성
    func ensureDirectories() throws {
        let dirs = [
            sandboxDirectory,
            sandboxDirectory.appendingPathComponent("images", isDirectory: true),
            sandboxDirectory.appendingPathComponent("overlays", isDirectory: true),
            sandboxDirectory.appendingPathComponent("configs", isDirectory: true)
        ]
        for dir in dirs {
            if !FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
    }

    /// 베이스 이미지 디렉토리 경로
    var imagesDirectory: URL {
        sandboxDirectory.appendingPathComponent("images", isDirectory: true)
    }

    /// 오버레이 디렉토리 경로
    var overlaysDirectory: URL {
        sandboxDirectory.appendingPathComponent("overlays", isDirectory: true)
    }

    /// 설정 파일 디렉토리 경로
    var configsDirectory: URL {
        sandboxDirectory.appendingPathComponent("configs", isDirectory: true)
    }

    /// 베이스 이미지 위에 Copy-on-Write 오버레이 생성
    /// 샌드박스의 핵심: 종료 시 이 오버레이만 삭제하면 원상복구
    func createOverlay(baseImagePath: String, sandboxId: String) throws -> String {
        guard let qemuImg = findQEMUImg() else {
            throw DiskImageError.qemuImgNotFound
        }
        guard FileManager.default.fileExists(atPath: baseImagePath) else {
            throw DiskImageError.baseImageNotFound(baseImagePath)
        }

        try ensureDirectories()
        let overlayPath = overlaysDirectory
            .appendingPathComponent("\(sandboxId).qcow2")
            .path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: qemuImg)
        process.arguments = [
            "create",
            "-f", "qcow2",
            "-b", baseImagePath,
            "-F", "qcow2",
            overlayPath
        ]

        let errorPipe = Pipe()
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMsg = String(data: errorData, encoding: .utf8) ?? "알 수 없는 오류"
            throw DiskImageError.overlayCreationFailed(errorMsg)
        }

        return overlayPath
    }

    /// 새 빈 디스크 이미지 생성 (Windows 설치용)
    func createBlankImage(name: String, sizeGB: Int) throws -> String {
        guard let qemuImg = findQEMUImg() else {
            throw DiskImageError.qemuImgNotFound
        }

        try ensureDirectories()
        let imagePath = imagesDirectory
            .appendingPathComponent("\(name).qcow2")
            .path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: qemuImg)
        process.arguments = [
            "create",
            "-f", "qcow2",
            imagePath,
            "\(sizeGB)G"
        ]

        let errorPipe = Pipe()
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMsg = String(data: errorData, encoding: .utf8) ?? "알 수 없는 오류"
            throw DiskImageError.imageCreationFailed(errorMsg)
        }

        return imagePath
    }

    /// 오버레이 삭제 (샌드박스 정리)
    func removeOverlay(sandboxId: String) {
        let overlayPath = overlaysDirectory
            .appendingPathComponent("\(sandboxId).qcow2")
            .path
        try? FileManager.default.removeItem(atPath: overlayPath)
    }

    /// 모든 오버레이 정리
    func cleanAllOverlays() throws {
        let contents = try FileManager.default.contentsOfDirectory(
            at: overlaysDirectory,
            includingPropertiesForKeys: nil
        )
        for file in contents where file.pathExtension == "qcow2" {
            try FileManager.default.removeItem(at: file)
        }
    }

    /// 사용 가능한 베이스 이미지 목록
    func listBaseImages() throws -> [URL] {
        try ensureDirectories()
        let contents = try FileManager.default.contentsOfDirectory(
            at: imagesDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        )
        return contents.filter { $0.pathExtension == "qcow2" || $0.pathExtension == "img" || $0.pathExtension == "iso" }
    }

    // MARK: - Private

    private func findQEMUImg() -> String? {
        // 1순위: 앱 번들에 내장된 qemu-img
        if let bundledPath = bundledBinaryPath("qemu-img") {
            return bundledPath
        }

        // 2순위: 시스템 설치
        let candidates = [
            "/opt/homebrew/bin/qemu-img",
            "/usr/local/bin/qemu-img",
            "/opt/local/bin/qemu-img"
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    private func bundledBinaryPath(_ name: String) -> String? {
        // 앱 번들 내부
        if let resourcePath = Bundle.main.resourcePath {
            let path = (resourcePath as NSString).appendingPathComponent("vendor/qemu/bin/\(name)")
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        // 개발 환경: 프로젝트 루트에서 탐색
        let execURL = Bundle.main.executableURL
        var searchDir = execURL?.deletingLastPathComponent()
        for _ in 0..<6 {
            guard let dir = searchDir else { break }
            let path = dir.appendingPathComponent("vendor/qemu/bin/\(name)").path
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
            searchDir = dir.deletingLastPathComponent()
        }
        return nil
    }
}

// MARK: - Errors

enum DiskImageError: LocalizedError {
    case qemuImgNotFound
    case baseImageNotFound(String)
    case overlayCreationFailed(String)
    case imageCreationFailed(String)

    var errorDescription: String? {
        switch self {
        case .qemuImgNotFound:
            return "qemu-img를 찾을 수 없습니다. vendor/qemu이 누락되었습니다."
        case .baseImageNotFound(let path):
            return "베이스 이미지를 찾을 수 없습니다: \(path)"
        case .overlayCreationFailed(let reason):
            return "오버레이 생성 실패: \(reason)"
        case .imageCreationFailed(let reason):
            return "디스크 이미지 생성 실패: \(reason)"
        }
    }
}
