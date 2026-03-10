import Foundation

/// QEMU 프로세스 실행 정보
struct QEMUProcessInfo {
    let processIdentifier: Int32
    let startTime: Date
    var monitorSocketPath: String
}
