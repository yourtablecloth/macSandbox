import Foundation

/// virtio-win 드라이버 ISO 관리 서비스
final class VirtioDriverService: NSObject, URLSessionDownloadDelegate {

    /// virtio-win 안정 버전 다운로드 URL
    private static let virtioWinURL = "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"

    private let driversDirectory: URL
    private var downloadTask: URLSessionDownloadTask?
    private var session: URLSession?
    private var downloadContinuation: CheckedContinuation<String, Error>?

    /// 다운로드 진행률 콜백 (0.0 ~ 1.0)
    var onProgress: ((Double) -> Void)?

    override init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.driversDirectory = appSupport.appendingPathComponent("MacSandbox/drivers", isDirectory: true)
        super.init()
    }

    /// virtio-win.iso 파일 경로 (다운로드 완료된 경우)
    var virtioWinISOPath: String {
        driversDirectory.appendingPathComponent("virtio-win.iso").path
    }

    /// virtio-win.iso가 이미 존재하는지 확인
    var isVirtioWinAvailable: Bool {
        FileManager.default.fileExists(atPath: virtioWinISOPath)
    }

    /// ARM64 virtio 드라이버 사용 가능 여부 확인
    /// virtio-win은 현재 ARM64 드라이버를 포함하지 않을 수 있음
    /// - Returns: ARM64 사용 가능 시 true, 아니면 false (NVMe 폴백 필요)
    var isARM64Supported: Bool {
        // virtio-win은 ARM64 드라이버를 포함하지 않음
        // ARM64에서는 NVMe 에뮬레이션(-device nvme)을 사용해야 함
        false
    }

    /// virtio-win ISO 다운로드 (이미 존재하면 즉시 반환)
    func ensureVirtioWinISO() async throws -> String {
        if isVirtioWinAvailable {
            return virtioWinISOPath
        }
        return try await downloadVirtioWinISO()
    }

    /// virtio-win ISO 강제 다운로드
    func downloadVirtioWinISO() async throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: driversDirectory, withIntermediateDirectories: true)

        guard let url = URL(string: Self.virtioWinURL) else {
            throw VirtioDriverError.invalidURL
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.downloadContinuation = continuation
            let config = URLSessionConfiguration.default
            self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            self.downloadTask = self.session?.downloadTask(with: url)
            self.downloadTask?.resume()
        }
    }

    /// 다운로드 취소
    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
    }

    /// 주어진 아키텍처에 최적의 디스크 디바이스 전략 반환
    /// - Returns: ARM64는 NVMe, x86_64는 virtio-blk
    func recommendedDiskDevice(for arch: SandboxConfiguration.GuestArchitecture) -> DiskDeviceStrategy {
        switch arch {
        case .aarch64:
            // ARM64: virtio-win에 ARM64 드라이버가 없으므로 NVMe 사용
            // Windows에 NVMe 기본 드라이버가 내장되어 있어 추가 드라이버 불필요
            return .nvme
        case .x86_64:
            return .virtioBlk
        }
    }

    /// 디스크 디바이스 전략
    enum DiskDeviceStrategy {
        case virtioBlk    // virtio-blk-pci (최고 성능, 드라이버 필요)
        case nvme         // NVMe 에뮬레이션 (Windows 기본 드라이버, 드라이버 불필요)

        /// QEMU -device 인자
        var qemuDeviceArgs: (driveArgs: String, deviceArgs: String) {
            switch self {
            case .virtioBlk:
                return ("if=none,id=hd0,format=qcow2", "virtio-blk-pci,drive=hd0")
            case .nvme:
                return ("if=none,id=hd0,format=qcow2", "nvme,drive=hd0,serial=baseline0")
            }
        }
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let destURL = URL(fileURLWithPath: virtioWinISOPath)
        do {
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.moveItem(at: location, to: destURL)
            downloadContinuation?.resume(returning: destURL.path)
        } catch {
            downloadContinuation?.resume(throwing: error)
        }
        downloadContinuation = nil
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            onProgress?(progress)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            downloadContinuation?.resume(throwing: error)
            downloadContinuation = nil
        }
    }
}

// MARK: - Errors

enum VirtioDriverError: LocalizedError {
    case invalidURL
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "virtio-win 다운로드 URL이 유효하지 않습니다."
        case .downloadFailed(let detail):
            return "virtio-win 다운로드 실패: \(detail)"
        }
    }
}
