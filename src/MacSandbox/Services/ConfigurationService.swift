import Foundation

/// 샌드박스 설정 파일(.msb) 로드/저장 서비스
final class ConfigurationService {
    private let diskImageService: DiskImageService

    init(diskImageService: DiskImageService) {
        self.diskImageService = diskImageService
    }

    /// .msb 파일에서 설정 로드
    func load(from url: URL) throws -> SandboxConfiguration {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode(SandboxConfiguration.self, from: data)
    }

    /// 설정을 .msb 파일로 저장
    func save(_ configuration: SandboxConfiguration, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(configuration)
        try data.write(to: url, options: .atomic)
    }

    /// 설정 디렉토리에 저장
    func saveToConfigsDirectory(_ configuration: SandboxConfiguration) throws -> URL {
        try diskImageService.ensureDirectories()
        let fileName = configuration.name
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        let url = diskImageService.configsDirectory
            .appendingPathComponent("\(fileName).msb")
        try save(configuration, to: url)
        return url
    }

    /// 저장된 설정 목록 불러오기
    func listSavedConfigurations() throws -> [(url: URL, config: SandboxConfiguration)] {
        try diskImageService.ensureDirectories()
        let contents = try FileManager.default.contentsOfDirectory(
            at: diskImageService.configsDirectory,
            includingPropertiesForKeys: nil
        )
        return contents
            .filter { $0.pathExtension == "msb" }
            .compactMap { url in
                guard let config = try? load(from: url) else { return nil }
                return (url: url, config: config)
            }
    }
}
