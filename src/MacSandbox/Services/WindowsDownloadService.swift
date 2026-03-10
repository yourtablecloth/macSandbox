import Foundation

/// Windows 11 ARM64 ISO/ESD 다운로드 서비스
///
/// Microsoft 공식 소프트웨어 다운로드 페이지에서 Windows 11 ARM64 ISO를 다운로드합니다.
/// 사용자가 직접 ISO를 제공하거나, 이 서비스를 통해 다운로드할 수 있습니다.
final class WindowsDownloadService: NSObject, ObservableObject, URLSessionDownloadDelegate {
    
    // MARK: - Published State
    
    @Published var isDownloading = false
    @Published var progress: Double = 0
    @Published var downloadedBytes: Int64 = 0
    @Published var totalBytes: Int64 = 0
    @Published var errorMessage: String?
    @Published var downloadedFilePath: String?
    
    // MARK: - Private
    
    private var downloadTask: URLSessionDownloadTask?
    private var session: URLSession?
    private var destinationURL: URL?
    private var completionHandler: ((Result<String, Error>) -> Void)?
    
    private let downloadDirectory: URL
    
    override init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.downloadDirectory = appSupport.appendingPathComponent("MacSandbox/iso", isDirectory: true)
        super.init()
    }
    
    // MARK: - Public API
    
    /// Microsoft 공식 사이트에서 Windows 11 ARM64 ISO 다운로드
    ///
    /// Windows 11 ARM64 ISO는 Microsoft 공식 다운로드 페이지에서 직접 다운로드하거나,
    /// Windows Insider Preview 페이지에서 ARM64 빌드를 선택하여 다운로드할 수 있습니다.
    ///
    /// 이 메서드는 사용자가 직접 제공한 URL에서 ISO를 다운로드합니다.
    func downloadISO(from url: URL, completion: @escaping (Result<String, Error>) -> Void) {
        guard !isDownloading else {
            completion(.failure(DownloadError.alreadyDownloading))
            return
        }
        
        do {
            try FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
        } catch {
            completion(.failure(error))
            return
        }
        
        let fileName = url.lastPathComponent.isEmpty ? "Windows11_ARM64.iso" : url.lastPathComponent
        let dest = downloadDirectory.appendingPathComponent(fileName)
        self.destinationURL = dest
        self.completionHandler = completion
        
        isDownloading = true
        progress = 0
        downloadedBytes = 0
        totalBytes = 0
        errorMessage = nil
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 7200  // 2시간 (대용량 파일)
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        
        downloadTask = session?.downloadTask(with: request)
        downloadTask?.resume()
    }
    
    /// 다운로드 취소
    func cancelDownload() {
        downloadTask?.cancel()
        isDownloading = false
        progress = 0
        errorMessage = "다운로드가 취소되었습니다."
    }
    
    /// 이미 다운로드된 ISO 파일 목록
    func listDownloadedISOs() -> [URL] {
        guard FileManager.default.fileExists(atPath: downloadDirectory.path) else { return [] }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: downloadDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        return contents.filter { $0.pathExtension.lowercased() == "iso" || $0.pathExtension.lowercased() == "esd" }
    }
    
    /// ISO 파일 삭제
    func deleteISO(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
    
    /// ISO 저장 디렉토리 경로
    var isoDirectory: URL { downloadDirectory }
    
    // MARK: - 포맷 헬퍼
    
    /// 바이트 수를 사람이 읽기 쉬운 문자열로 변환
    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
    
    // MARK: - URLSessionDownloadDelegate
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let dest = destinationURL else { return }
        
        do {
            // 기존 파일이 있으면 삭제
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: location, to: dest)
            
            isDownloading = false
            downloadedFilePath = dest.path
            completionHandler?(.success(dest.path))
        } catch {
            isDownloading = false
            errorMessage = "파일 저장 실패: \(error.localizedDescription)"
            completionHandler?(.failure(error))
        }
        
        completionHandler = nil
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        downloadedBytes = totalBytesWritten
        totalBytes = totalBytesExpectedToWrite
        if totalBytesExpectedToWrite > 0 {
            progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error as? URLError, error.code == .cancelled {
            return  // 사용자가 취소한 경우
        }
        if let error {
            isDownloading = false
            errorMessage = "다운로드 실패: \(error.localizedDescription)"
            completionHandler?(.failure(error))
            completionHandler = nil
        }
    }
}

// MARK: - Errors

enum DownloadError: LocalizedError {
    case alreadyDownloading
    case invalidURL
    case downloadFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .alreadyDownloading:
            return "이미 다운로드가 진행 중입니다."
        case .invalidURL:
            return "유효하지 않은 다운로드 URL입니다."
        case .downloadFailed(let reason):
            return "다운로드 실패: \(reason)"
        }
    }
}
