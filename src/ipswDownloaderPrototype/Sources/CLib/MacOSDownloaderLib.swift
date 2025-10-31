import Foundation
import Virtualization
import SharedCore

// MARK: - C 호환 함수

/// 최신 macOS 복구 이미지 가져오기
/// - Parameters:
///   - outVersion: 버전 문자열 포인터의 포인터
///   - outBuild: 빌드 문자열 포인터의 포인터  
///   - outURL: URL 문자열 포인터의 포인터
///   - outSize: 파일 크기 포인터
/// - Returns: 0 = 성공, -1 = 지원되지 않는 버전, -2 = 오류
@_cdecl("macosdownloader_get_latest_image")
public func macosdownloader_get_latest_image(
    _ outVersion: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
    _ outBuild: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
    _ outURL: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
    _ outSize: UnsafeMutablePointer<Int64>?
) -> Int32 {
    guard #available(macOS 12.0, *) else {
        return -1
    }
    
    guard let outVersion = outVersion,
          let outBuild = outBuild,
          let outURL = outURL,
          let outSize = outSize else {
        return -2
    }
    
    let semaphore = DispatchSemaphore(value: 0)
    var result: Int32 = -2
    
    Task {
        do {
            let image = try await VZMacOSRestoreImage.latestSupported
            
            let version = "\(image.operatingSystemVersion.majorVersion).\(image.operatingSystemVersion.minorVersion).\(image.operatingSystemVersion.patchVersion)"
            let build = image.buildVersion
            let url = image.url.absoluteString
            
            // HTTP HEAD 요청으로 실제 파일 크기 가져오기
            var size: Int64 = 0
            do {
                var request = URLRequest(url: image.url)
                request.httpMethod = "HEAD"
                request.timeoutInterval = 10
                
                let (_, response) = try await URLSession.shared.data(for: request)
                if let httpResponse = response as? HTTPURLResponse,
                   let contentLength = httpResponse.value(forHTTPHeaderField: "Content-Length"),
                   let fileSize = Int64(contentLength) {
                    size = fileSize
                }
            } catch {
                NSLog("macosdownloader: Could not fetch file size: \(error.localizedDescription)")
            }
            
            outVersion.pointee = strdup(version)
            outBuild.pointee = strdup(build)
            outURL.pointee = strdup(url)
            outSize.pointee = size
            
            result = 0
        } catch {
            NSLog("macosdownloader: Error fetching image: \(error.localizedDescription)")
            result = -2
        }
        semaphore.signal()
    }
    
    semaphore.wait()
    return result
}

/// 현재 시스템 정보 가져오기
/// - Parameters:
///   - outModel: 모델 식별자 문자열 포인터의 포인터
///   - outArch: 아키텍처 문자열 포인터의 포인터
///   - outBoard: 보드 ID 문자열 포인터의 포인터
/// - Returns: 0 = 성공, -2 = 오류
@_cdecl("macosdownloader_get_system_info")
public func macosdownloader_get_system_info(
    _ outModel: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
    _ outArch: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
    _ outBoard: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
    guard let outModel = outModel,
          let outArch = outArch,
          let outBoard = outBoard else {
        return -2
    }
    
    do {
        let info = try SystemInfo.current()
        
        outModel.pointee = strdup(info.model)
        outArch.pointee = strdup(info.architecture)
        outBoard.pointee = strdup(info.boardId)
        
        return 0
    } catch {
        NSLog("macosdownloader: Error getting system info: \(error.localizedDescription)")
        return -2
    }
}

/// 문자열 메모리 해제
/// - Parameter str: 해제할 문자열 포인터
@_cdecl("macosdownloader_free_string")
public func macosdownloader_free_string(_ str: UnsafeMutablePointer<CChar>?) {
    if let ptr = str {
        free(ptr)
    }
}

/// 라이브러리 버전 가져오기
/// - Returns: 버전 문자열 포인터 (호출자가 macosdownloader_free_string으로 해제해야 함)
@_cdecl("macosdownloader_get_version")
public func macosdownloader_get_version() -> UnsafeMutablePointer<CChar>? {
    return strdup("1.0.0")
}

/// IPSW 이미지 다운로드 (간단한 버전)
/// - Parameters:
///   - url: 다운로드 URL (C 문자열)
///   - outputPath: 저장 경로 (C 문자열)
/// - Returns: 0 = 성공, -2 = 오류
@_cdecl("macosdownloader_download")
public func macosdownloader_download(
    _ url: UnsafePointer<CChar>?,
    _ outputPath: UnsafePointer<CChar>?
) -> Int32 {
    guard let urlCStr = url,
          let pathCStr = outputPath,
          let urlString = String(validatingUTF8: urlCStr),
          let outputPathString = String(validatingUTF8: pathCStr),
          let downloadURL = URL(string: urlString) else {
        return -2
    }
    
    let outputURL = URL(fileURLWithPath: outputPathString)
    let semaphore = DispatchSemaphore(value: 0)
    var result: Int32 = -2
    
    Task {
        do {
            let downloader = IPSWDownloader()
            
            try await downloader.download(
                image: IPSWImage(
                    name: "Download",
                    version: "1.0",
                    build: "1",
                    url: urlString,
                    size: 0,
                    releaseDate: nil
                ),
                to: outputURL.deletingLastPathComponent().path,
                verbose: false
            )
            
            result = 0
        } catch {
            NSLog("macosdownloader: Download error: \(error.localizedDescription)")
            result = -2
        }
        semaphore.signal()
    }
    
    semaphore.wait()
    return result
}
