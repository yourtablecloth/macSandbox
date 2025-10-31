import Foundation

public class IPSWDownloader {
    public init() {}
    
    public func download(image: IPSWImage, to outputPath: String, verbose: Bool) async throws {
        guard let url = URL(string: image.url) else {
            throw DownloadError.invalidURL
        }
        
        // 출력 디렉토리 확인 및 생성
        let outputDir = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        
        // 파일명 추출
        let fileName = url.lastPathComponent
        let destinationURL = outputDir.appendingPathComponent(fileName)
        
        // 이미 존재하는 파일 확인
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            print("⚠️  파일이 이미 존재합니다: \(destinationURL.path)")
            print("덮어쓰시겠습니까? (y/n): ", terminator: "")
            fflush(stdout)
            
            guard let input = readLine(), input.lowercased() == "y" else {
                print("다운로드를 취소합니다.")
                return
            }
            
            try FileManager.default.removeItem(at: destinationURL)
        }
        
        if verbose {
            print("URL: \(url)")
            print("저장 위치: \(destinationURL.path)")
            print()
        }
        
        // 다운로드 세션 생성
        let session = URLSession(configuration: .default, delegate: nil, delegateQueue: nil)
        
        // 다운로드 요청
        var lastProgressUpdate = Date()
        let request = URLRequest(url: url)
        
        let (asyncBytes, response) = try await session.bytes(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw DownloadError.downloadFailed
        }
        
        let totalSize = image.size
        var downloadedSize: Int64 = 0
        var data = Data()
        data.reserveCapacity(Int(totalSize))
        
        print("진행률: 0%", terminator: "")
        fflush(stdout)
        
        for try await byte in asyncBytes {
            data.append(byte)
            downloadedSize += 1
            
            // 진행률 업데이트 (0.5초마다)
            let now = Date()
            if now.timeIntervalSince(lastProgressUpdate) >= 0.5 {
                let progress = Double(downloadedSize) / Double(totalSize) * 100
                let downloaded = Utilities.formatBytes(downloadedSize)
                let total = Utilities.formatBytes(totalSize)
                
                print("\r진행률: \(String(format: "%.1f", progress))% (\(downloaded) / \(total))", terminator: "")
                fflush(stdout)
                
                lastProgressUpdate = now
            }
        }
        
        // 최종 진행률
        print("\r진행률: 100.0% (\(Utilities.formatBytes(totalSize)) / \(Utilities.formatBytes(totalSize)))")
        
        // 파일 저장
        try data.write(to: destinationURL)
        
        print("\n📁 저장 완료: \(destinationURL.path)")
    }
}

enum DownloadError: Error, CustomStringConvertible {
    case invalidURL
    case downloadFailed
    case saveFailed
    
    var description: String {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .downloadFailed:
            return "Download failed"
        case .saveFailed:
            return "Failed to save file"
        }
    }
}
