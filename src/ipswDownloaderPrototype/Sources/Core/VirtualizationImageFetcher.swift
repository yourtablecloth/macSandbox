import Foundation
import Virtualization

@available(macOS 12.0, *)
class VirtualizationImageFetcher {
    
    struct RestoreImageInfo {
        let version: OperatingSystemVersion
        let url: URL
        let buildVersion: String?
        let requirements: VZMacOSConfigurationRequirements?
        let isSupported: Bool
    }
    
    /// Virtualization framework를 사용하여 최신 지원 복구 이미지 가져오기
    func fetchLatestSupportedImage() async throws -> RestoreImageInfo {
        do {
            let restoreImage = try await VZMacOSRestoreImage.latestSupported
            
            return RestoreImageInfo(
                version: restoreImage.operatingSystemVersion,
                url: restoreImage.url,
                buildVersion: restoreImage.buildVersion,
                requirements: restoreImage.mostFeaturefulSupportedConfiguration,
                isSupported: restoreImage.isSupported
            )
        } catch let error as NSError {
            // 상세한 오류 정보 출력
            print("  NSError domain: \(error.domain)")
            print("  NSError code: \(error.code)")
            print("  NSError userInfo: \(error.userInfo)")
            throw VirtualizationError.fetchFailed(error.localizedDescription)
        } catch {
            throw VirtualizationError.fetchFailed(error.localizedDescription)
        }
    }
    
    /// 특정 URL에서 복구 이미지 정보 가져오기
    func loadImage(from url: URL) async throws -> RestoreImageInfo {
        do {
            let restoreImage = try await VZMacOSRestoreImage.image(from: url)
            
            return RestoreImageInfo(
                version: restoreImage.operatingSystemVersion,
                url: restoreImage.url,
                buildVersion: restoreImage.buildVersion,
                requirements: restoreImage.mostFeaturefulSupportedConfiguration,
                isSupported: restoreImage.isSupported
            )
        } catch {
            throw VirtualizationError.loadFailed(error.localizedDescription)
        }
    }
    
    /// RestoreImageInfo를 IPSWImage로 변환
    func convertToIPSWImage(_ info: RestoreImageInfo) async -> IPSWImage {
        let version = "\(info.version.majorVersion).\(info.version.minorVersion).\(info.version.patchVersion)"
        let build = info.buildVersion ?? "Unknown"
        let name = "macOS \(getOSName(for: info.version)) \(version)"
        
        // HTTP HEAD 요청으로 실제 파일 크기 가져오기
        let size = await getFileSize(from: info.url)
        
        return IPSWImage(
            name: name,
            version: version,
            build: build,
            url: info.url.absoluteString,
            size: size,
            releaseDate: nil
        )
    }
    
    /// HTTP HEAD 요청으로 파일 크기 가져오기
    private func getFileSize(from url: URL) async -> Int64 {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse,
               let contentLength = httpResponse.value(forHTTPHeaderField: "Content-Length"),
               let size = Int64(contentLength) {
                return size
            }
        } catch {
            print("  ⚠️  파일 크기 가져오기 실패: \(error.localizedDescription)")
        }
        
        return 0
    }
    
    private func getOSName(for version: OperatingSystemVersion) -> String {
        switch version.majorVersion {
        case 15: return "Sequoia"
        case 14: return "Sonoma"
        case 13: return "Ventura"
        case 12: return "Monterey"
        case 11: return "Big Sur"
        default: return "macOS"
        }
    }
}

enum VirtualizationError: Error, CustomStringConvertible {
    case fetchFailed(String)
    case loadFailed(String)
    case notSupported
    
    var description: String {
        switch self {
        case .fetchFailed(let message):
            return "Failed to fetch restore image: \(message)"
        case .loadFailed(let message):
            return "Failed to load restore image: \(message)"
        case .notSupported:
            return "Virtualization framework is not supported on this system"
        }
    }
}
