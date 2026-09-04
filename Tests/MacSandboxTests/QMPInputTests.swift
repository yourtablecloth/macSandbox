import Darwin
import Foundation
import XCTest
@testable import MacSandbox

final class QMPInputTests: XCTestCase {
    func testPeerShutdownDoesNotTerminateProcessAndDisconnectsInjector() throws {
        let socketURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("msbx-qmp-test-\(UUID().uuidString.prefix(8)).sock")
        defer { try? FileManager.default.removeItem(at: socketURL) }

        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listener, 0)
        defer { Darwin.close(listener) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketURL.path.utf8CString
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        XCTAssertLessThanOrEqual(pathBytes.count, capacity)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                for (index, byte) in pathBytes.enumerated() where index < capacity {
                    destination[index] = byte
                }
            }
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bindResult, 0)
        XCTAssertEqual(Darwin.listen(listener, 1), 0)

        let serverClosed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let peer = Darwin.accept(listener, nil, nil)
            guard peer >= 0 else {
                serverClosed.signal()
                return
            }
            let greeting = #"{"QMP":{"version":{},"capabilities":[]}}"# + "\r\n"
            greeting.withCString { _ = Darwin.send(peer, $0, strlen($0), 0) }
            var command = [UInt8](repeating: 0, count: 4096)
            _ = Darwin.read(peer, &command, command.count)
            let response = #"{"return":{}}"# + "\r\n"
            response.withCString { _ = Darwin.send(peer, $0, strlen($0), 0) }
            _ = Darwin.shutdown(peer, SHUT_RDWR)
            Darwin.close(peer)
            serverClosed.signal()
        }

        let injector = QMPInputInjector(socketPath: socketURL.path)
        XCTAssertTrue(injector.connect(retries: 10, retryDelay: 0.01))
        XCTAssertEqual(serverClosed.wait(timeout: .now() + 2), .success)

        // Before SO_NOSIGPIPE this call terminates the whole test process with signal 13.
        injector.screendump(to: "/tmp/msbx-qmp-test.png")
        XCTAssertFalse(injector.isConnected)
    }
}
