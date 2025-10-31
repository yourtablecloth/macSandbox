import Foundation

public struct SystemInfo {
    public let model: String
    public let architecture: String
    public let boardId: String
    
    public static func current() throws -> SystemInfo {
        let model = try getSystemProperty("hw.model")
        let architecture = try getSystemProperty("hw.machine")
        let boardId = try getBoardId()
        
        return SystemInfo(
            model: model,
            architecture: architecture,
            boardId: boardId
        )
    }
    
    private static func getSystemProperty(_ property: String) throws -> String {
        let process = Process()
        let pipe = Pipe()
        
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl")
        process.arguments = ["-n", property]
        process.standardOutput = pipe
        
        try process.run()
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw SystemInfoError.failedToRetrieve(property)
        }
        
        return output
    }
    
    private static func getBoardId() throws -> String {
        let process = Process()
        let pipe = Pipe()
        
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        process.arguments = ["-l"]
        process.standardOutput = pipe
        
        try process.run()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        
        guard let output = String(data: data, encoding: .utf8) else {
            throw SystemInfoError.failedToRetrieve("board-id")
        }
        
        // board-id 찾기
        if let range = output.range(of: #""board-id" = <"([^"]+)""#, options: .regularExpression) {
            let match = output[range]
            if let idRange = match.range(of: #"<"([^"]+)""#, options: .regularExpression) {
                let idMatch = match[idRange]
                let boardId = String(idMatch.dropFirst(2).dropLast(1))
                return boardId
            }
        }
        
        // 대체 방법: product name 사용
        if let range = output.range(of: #""product-name" = <"([^"]+)""#, options: .regularExpression) {
            let match = output[range]
            if let nameRange = match.range(of: #"<"([^"]+)""#, options: .regularExpression) {
                let nameMatch = match[nameRange]
                let productName = String(nameMatch.dropFirst(2).dropLast(1))
                return productName
            }
        }
        
        return "Unknown"
    }
}

enum SystemInfoError: Error, CustomStringConvertible {
    case failedToRetrieve(String)
    
    var description: String {
        switch self {
        case .failedToRetrieve(let property):
            return "Failed to retrieve system property: \(property)"
        }
    }
}
