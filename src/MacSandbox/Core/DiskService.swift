import Foundation

/// qcow2 디스크 생성 및 COW 오버레이 관리 (qemu-img 래퍼)
final class DiskService {

    enum DiskError: LocalizedError {
        case qemuImgNotFound
        case createFailed(String)

        var errorDescription: String? {
            switch self {
            case .qemuImgNotFound:
                return "qemu-img를 찾을 수 없습니다. vendor/qemu 번들을 확인하세요."
            case .createFailed(let reason):
                return "디스크 작업 실패: \(reason)"
            }
        }
    }

    /// 빈 qcow2 디스크 생성
    func createQcow2(at path: String, sizeGB: Int) throws {
        try runQemuImg(["create", "-f", "qcow2", path, "\(sizeGB)G"])
    }

    /// 베이스 이미지 위에 Copy-on-Write 오버레이 생성 (샌드박스 런타임용)
    func createOverlay(basePath: String, overlayPath: String) throws {
        try runQemuImg(["create", "-f", "qcow2", "-b", basePath, "-F", "qcow2", overlayPath])
    }

    // MARK: - Private

    private func runQemuImg(_ arguments: [String]) throws {
        guard let qemuImg = SandboxPaths.qemuImgBinary() else {
            throw DiskError.qemuImgNotFound
        }

        let process = Process()
        process.executableURL = qemuImg
        process.arguments = arguments
        process.environment = SandboxPaths.qemuEnvironment()

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "알 수 없는 오류"
            throw DiskError.createFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
