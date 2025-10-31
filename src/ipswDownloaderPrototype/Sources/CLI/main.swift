import Foundation
import ArgumentParser
import SharedCore

@available(macOS 10.15, *)
@main
struct MacOSDownloader: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macosdownloader",
        abstract: "macOS IPSW 이미지 다운로더",
        discussion: """
        현재 시스템과 호환되는 macOS IPSW 이미지를 다운로드합니다.
        Apple의 공식 IPSW API를 사용하여 이미지를 검색하고 다운로드합니다.
        """
    )
    
    @Option(name: .shortAndLong, help: "다운로드할 디렉토리 경로 (기본값: 현재 디렉토리)")
    var output: String = "."
    
    @Flag(name: .shortAndLong, help: "사용 가능한 IPSW 이미지 목록만 표시")
    var list: Bool = false
    
    @Flag(name: .long, help: "상세 정보 출력")
    var verbose: Bool = false
    
    func run() async throws {
        print("🍎 macOS IPSW 다운로더")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        // 시스템 정보 가져오기
        let systemInfo = try SystemInfo.current()
        if verbose {
            print("\n시스템 정보:")
            print("  모델: \(systemInfo.model)")
            print("  아키텍처: \(systemInfo.architecture)")
            print("  보드 ID: \(systemInfo.boardId)")
        }
        
        // IPSW 이미지 검색
        print("\n🔍 호환되는 IPSW 이미지를 검색 중...")
        let fetcher = IPSWFetcher()
        let images = try await fetcher.fetchCompatibleImages(for: systemInfo)
        
        if images.isEmpty {
            print("❌ 호환되는 IPSW 이미지를 찾을 수 없습니다.")
            throw ExitCode.failure
        }
        
        print("✅ \(images.count)개의 이미지를 찾았습니다.\n")
        
        // 목록 표시
        for (index, image) in images.enumerated() {
            print("[\(index + 1)] \(image.name)")
            print("    버전: \(image.version)")
            print("    빌드: \(image.build)")
            print("    크기: \(Utilities.formatBytes(image.size))")
            if verbose {
                print("    URL: \(image.url)")
            }
            print()
        }
        
        if list {
            return
        }
        
        // 다운로드할 이미지 선택
        print("다운로드할 이미지 번호를 입력하세요 (1-\(images.count)): ", terminator: "")
        fflush(stdout)
        
        guard let input = readLine(), let choice = Int(input), choice > 0 && choice <= images.count else {
            print("❌ 잘못된 선택입니다.")
            throw ExitCode.failure
        }
        
        let selectedImage = images[choice - 1]
        
        // 다운로드
        print("\n📥 다운로드 중: \(selectedImage.name)")
        let downloader = IPSWDownloader()
        try await downloader.download(image: selectedImage, to: output, verbose: verbose)
        
        print("✅ 다운로드 완료!")
    }
}
