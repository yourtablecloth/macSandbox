import Foundation

public struct IPSWImage: Codable {
    public let name: String
    public let version: String
    public let build: String
    public let url: String
    public let size: Int64
    public let releaseDate: String?
    
    public init(name: String, version: String, build: String, url: String, size: Int64, releaseDate: String?) {
        self.name = name
        self.version = version
        self.build = build
        self.url = url
        self.size = size
        self.releaseDate = releaseDate
    }
    
    enum CodingKeys: String, CodingKey {
        case name
        case version
        case build = "buildid"
        case url
        case size = "filesize"
        case releaseDate = "releasedate"
    }
}

struct IPSWDevice: Codable {
    let name: String
    let boardConfig: String
    let platform: String
    let firmwares: [IPSWImage]
    
    enum CodingKeys: String, CodingKey {
        case name
        case boardConfig = "BoardConfig"
        case platform
        case firmwares
    }
}

struct IPSWResponse: Codable {
    let devices: [IPSWDevice]
}

public class IPSWFetcher {
    public init() {}
    
    public func fetchCompatibleImages(for systemInfo: SystemInfo) async throws -> [IPSWImage] {
        var allImages: [IPSWImage] = []
        
        // 방법 1: Virtualization framework 사용 (macOS 12.0+, 가장 정확함)
        if #available(macOS 12.0, *) {
            do {
                let image = try await fetchFromVirtualizationFramework()
                print("✅ Virtualization framework에서 공식 이미지를 가져왔습니다.")
                allImages.append(image)
            } catch {
                print("⚠️  Virtualization framework 오류: \(error.localizedDescription)")
            }
        }
        
        // 방법 2: Apple의 공식 소프트웨어 업데이트 카탈로그
        if let images = try? await fetchFromAppleCatalog(systemInfo: systemInfo) {
            allImages.append(contentsOf: images)
        }
        
        // 테스트용 샘플 데이터 (실제 API에서 데이터를 못 가져올 경우)
        if allImages.isEmpty {
            print("⚠️  실제 API에서 데이터를 가져올 수 없어 샘플 데이터를 표시합니다.")
            allImages = getSampleImages(for: systemInfo)
        }
        
        // 중복 제거 (빌드 번호 기준)
        var uniqueImages: [String: IPSWImage] = [:]
        for image in allImages {
            uniqueImages[image.build] = image
        }
        
        let sortedImages = Array(uniqueImages.values).sorted { img1, img2 in
            // 버전 번호로 정렬 (최신순)
            return img1.version.compare(img2.version, options: .numeric) == .orderedDescending
        }
        
        return sortedImages
    }
    
    @available(macOS 12.0, *)
    private func fetchFromVirtualizationFramework() async throws -> IPSWImage {
        let fetcher = VirtualizationImageFetcher()
        let imageInfo = try await fetcher.fetchLatestSupportedImage()
        
        // URL에서 실제 파일 크기 가져오기 (HEAD 요청)
        var size: Int64 = 0
        if let fileSize = try? await getFileSize(from: imageInfo.url) {
            size = fileSize
        }
        
        let version = "\(imageInfo.version.majorVersion).\(imageInfo.version.minorVersion).\(imageInfo.version.patchVersion)"
        let build = imageInfo.buildVersion ?? "Unknown"
        let osName = getOSName(for: imageInfo.version)
        
        return IPSWImage(
            name: "macOS \(osName) \(version) (공식)",
            version: version,
            build: build,
            url: imageInfo.url.absoluteString,
            size: size,
            releaseDate: nil
        )
    }
    
    private func getFileSize(from url: URL) async throws -> Int64 {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        
        let (_, response) = try await URLSession.shared.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse,
           let contentLength = httpResponse.value(forHTTPHeaderField: "Content-Length"),
           let size = Int64(contentLength) {
            return size
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
    
    private func getSampleImages(for systemInfo: SystemInfo) -> [IPSWImage] {
        // 아키텍처에 따른 샘플 이미지
        let isAppleSilicon = systemInfo.architecture == "arm64"
        
        if isAppleSilicon {
            return [
                IPSWImage(
                    name: "macOS Sonoma 14.7.1",
                    version: "14.7.1",
                    build: "23H222",
                    url: "https://swdist.apple.com/content/downloads/30/24/062-26642-A_U9HXDOQ3T6/example1.pkg",
                    size: 13_421_772_800,
                    releaseDate: "2024-10-28"
                ),
                IPSWImage(
                    name: "macOS Sonoma 14.7",
                    version: "14.7",
                    build: "23H124",
                    url: "https://swdist.apple.com/content/downloads/29/23/062-24569-A_LW8PDOT2M5/example2.pkg",
                    size: 13_368_709_120,
                    releaseDate: "2024-09-16"
                ),
                IPSWImage(
                    name: "macOS Ventura 13.7.1",
                    version: "13.7.1",
                    build: "22H123",
                    url: "https://swdist.apple.com/content/downloads/28/22/062-24570-A_NX9QEPR4U7/example3.pkg",
                    size: 12_884_901_888,
                    releaseDate: "2024-10-28"
                )
            ]
        } else {
            return [
                IPSWImage(
                    name: "macOS Sonoma 14.7.1 (Intel)",
                    version: "14.7.1",
                    build: "23H222",
                    url: "https://swdist.apple.com/content/downloads/30/24/062-26642-A_U9HXDOQ3T6/example1-intel.pkg",
                    size: 13_421_772_800,
                    releaseDate: "2024-10-28"
                ),
                IPSWImage(
                    name: "macOS Ventura 13.7.1 (Intel)",
                    version: "13.7.1",
                    build: "22H123",
                    url: "https://swdist.apple.com/content/downloads/28/22/062-24570-A_NX9QEPR4U7/example3-intel.pkg",
                    size: 12_884_901_888,
                    releaseDate: "2024-10-28"
                )
            ]
        }
    }
    
    private func fetchFromAppleCatalog(systemInfo: SystemInfo) async throws -> [IPSWImage] {
        // Apple의 소프트웨어 업데이트 카탈로그 URL
        let catalogURLs = [
            "https://swscan.apple.com/content/catalogs/others/index-14-13-12-10.16-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog",
            "https://swdist.apple.com/content/catalogs/others/index-10.16-10.15-10.14-10.13-10.12-10.11-10.10-10.9.merged-1.sucatalog"
        ]
        
        var images: [IPSWImage] = []
        
        for catalogURL in catalogURLs {
            guard let url = URL(string: catalogURL) else { continue }
            
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    continue
                }
                
                // plist 파싱
                if let catalog = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                   let products = catalog["Products"] as? [String: [String: Any]] {
                    
                    for (_, product) in products {
                        // macOS 복구 이미지 찾기
                        if let distributions = product["Distributions"] as? [String: String],
                           let packages = product["Packages"] as? [[String: Any]],
                           let version = product["PostDate"] as? Date {
                            
                            // macOS 관련 패키지만 필터링
                            let isMacOS = distributions.keys.contains { $0.contains("macOS") || $0.contains("Mac") }
                            
                            if isMacOS {
                                for package in packages {
                                    if let url = package["URL"] as? String,
                                       let size = package["Size"] as? Int64,
                                       url.hasSuffix(".pkg") || url.hasSuffix(".dmg") {
                                        
                                        let buildId = extractBuildId(from: url) ?? "Unknown"
                                        let versionStr = extractVersion(from: url) ?? "Unknown"
                                        
                                        let image = IPSWImage(
                                            name: "macOS Recovery \(versionStr)",
                                            version: versionStr,
                                            build: buildId,
                                            url: url,
                                            size: size,
                                            releaseDate: ISO8601DateFormatter().string(from: version)
                                        )
                                        images.append(image)
                                    }
                                }
                            }
                        }
                    }
                }
            } catch {
                continue
            }
        }
        
        return images
    }
    
    private func extractBuildId(from url: String) -> String? {
        // URL에서 빌드 ID 추출 (예: 21A559)
        let pattern = #"(\d{2}[A-Z]\d{3,4}[a-z]?)"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) {
            if let range = Range(match.range, in: url) {
                return String(url[range])
            }
        }
        return nil
    }
    
    private func extractVersion(from url: String) -> String? {
        // URL에서 버전 추출 (예: 12.3.1)
        let pattern = #"(\d+\.\d+(?:\.\d+)?)"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) {
            if let range = Range(match.range, in: url) {
                return String(url[range])
            }
        }
        return nil
    }
}
