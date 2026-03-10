import Foundation

/// QEMU 프로세스 생명주기를 관리하는 서비스
final class QEMUService {
    private var process: Process?
    private var monitorSocketPath: String?

    /// QEMU 실행 파일 경로를 탐색 (번들 내장 바이너리 우선)
    func findQEMUExecutable(for arch: SandboxConfiguration.GuestArchitecture = .aarch64) -> String? {
        let binaryName = arch.qemuBinaryName

        // 1순위: 앱 번들에 내장된 QEMU
        if let bundledPath = bundledBinaryPath(binaryName) {
            return bundledPath
        }

        // 2순위: 시스템에 설치된 QEMU
        let candidates = [
            "/opt/homebrew/bin/\(binaryName)",
            "/usr/local/bin/\(binaryName)",
            "/opt/local/bin/\(binaryName)"
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // 3순위: PATH에서 탐색
        let whichProcess = Process()
        let pipe = Pipe()
        whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichProcess.arguments = [binaryName]
        whichProcess.standardOutput = pipe
        whichProcess.standardError = FileHandle.nullDevice
        do {
            try whichProcess.run()
            whichProcess.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        } catch {}
        return nil
    }

    /// 번들에 내장된 QEMU 펌웨어/공유 리소스 경로
    func bundledSharePath() -> String? {
        if let bundleQEMU = bundledVendorDirectory() {
            let sharePath = (bundleQEMU as NSString).appendingPathComponent("share/qemu")
            if FileManager.default.fileExists(atPath: sharePath) {
                return sharePath
            }
        }
        return nil
    }

    // MARK: - Bundle Path Resolution

    /// vendor/qemu 디렉토리 경로 탐색 (앱 번들 또는 개발 환경)
    private func bundledVendorDirectory() -> String? {
        // 앱 번들 내부 (배포 시)
        if let resourcePath = Bundle.main.resourcePath {
            let inBundle = (resourcePath as NSString).appendingPathComponent("vendor/qemu")
            if FileManager.default.fileExists(atPath: inBundle) {
                return inBundle
            }
        }

        // 앱 번들의 Contents/Frameworks/qemu (대안 배치)
        if let bundlePath = Bundle.main.bundlePath as String? {
            let inFrameworks = (bundlePath as NSString).appendingPathComponent("Contents/Frameworks/qemu")
            if FileManager.default.fileExists(atPath: inFrameworks) {
                return inFrameworks
            }
        }

        // 개발 환경: 프로젝트 루트의 vendor/qemu
        let execURL = Bundle.main.executableURL
        var searchDir = execURL?.deletingLastPathComponent()
        for _ in 0..<6 {
            guard let dir = searchDir else { break }
            let vendorPath = dir.appendingPathComponent("vendor/qemu").path
            if FileManager.default.fileExists(atPath: vendorPath) {
                return vendorPath
            }
            searchDir = dir.deletingLastPathComponent()
        }

        return nil
    }

    /// 번들에서 특정 바이너리 경로 탐색
    private func bundledBinaryPath(_ name: String) -> String? {
        guard let vendorDir = bundledVendorDirectory() else { return nil }
        let binPath = (vendorDir as NSString).appendingPathComponent("bin/\(name)")
        if FileManager.default.isExecutableFile(atPath: binPath) {
            return binPath
        }
        return nil
    }

    /// 주어진 설정으로 QEMU 인스턴스 시작
    func startVM(
        configuration: SandboxConfiguration,
        overlayDiskPath: String,
        onStateChange: @escaping (VMState) -> Void,
        onOutput: @escaping (String) -> Void
    ) throws -> QEMUProcessInfo {
        guard let qemuPath = findQEMUExecutable(for: configuration.guestArch) else {
            throw QEMUError.executableNotFound
        }

        let socketDir = NSTemporaryDirectory()
        let socketPath = (socketDir as NSString).appendingPathComponent("macsandbox-monitor-\(UUID().uuidString).sock")
        self.monitorSocketPath = socketPath

        let args = buildArguments(configuration: configuration, overlayDiskPath: overlayDiskPath, monitorSocketPath: socketPath)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: qemuPath)
        process.arguments = args

        // 번들된 QEMU 사용 시 환경 변수 설정
        var env = ProcessInfo.processInfo.environment
        if let vendorDir = bundledVendorDirectory() {
            let libPath = (vendorDir as NSString).appendingPathComponent("lib")
            let sharePath = (vendorDir as NSString).appendingPathComponent("share/qemu")
            env["DYLD_LIBRARY_PATH"] = libPath
            env["QEMU_DATADIR"] = sharePath
        }
        process.environment = env

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                onOutput(str)
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                onOutput("[stderr] \(str)")
            }
        }

        process.terminationHandler = { [weak self] proc in
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            self?.cleanup(socketPath: socketPath)
            if proc.terminationStatus == 0 {
                onStateChange(.stopped)
            } else {
                onStateChange(.error)
            }
        }

        try process.run()
        self.process = process
        onStateChange(.running)

        return QEMUProcessInfo(
            processIdentifier: process.processIdentifier,
            startTime: Date(),
            monitorSocketPath: socketPath
        )
    }

    /// QEMU VM을 정상 종료 (ACPI shutdown)
    func stopVM() {
        guard let socketPath = monitorSocketPath else {
            process?.terminate()
            return
        }
        // QMP 소켓을 통해 system_powerdown 명령 전송
        sendQMPCommand(socketPath: socketPath, command: """
        {"execute": "system_powerdown"}
        """)

        // 10초 내 종료되지 않으면 강제 종료
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { [weak self] in
            if self?.process?.isRunning == true {
                self?.process?.terminate()
            }
        }
    }

    /// 강제 종료
    func forceStopVM() {
        process?.terminate()
    }

    /// VM이 실행 중인지 확인
    var isRunning: Bool {
        process?.isRunning ?? false
    }

    // MARK: - Private

    private func buildArguments(
        configuration: SandboxConfiguration,
        overlayDiskPath: String,
        monitorSocketPath: String
    ) -> [String] {
        switch configuration.guestArch {
        case .aarch64:
            return buildAArch64Arguments(
                configuration: configuration,
                overlayDiskPath: overlayDiskPath,
                monitorSocketPath: monitorSocketPath
            )
        case .x86_64:
            return buildX86_64Arguments(
                configuration: configuration,
                overlayDiskPath: overlayDiskPath,
                monitorSocketPath: monitorSocketPath
            )
        }
    }

    /// AArch64 (ARM64) VM 인자 생성 — HVF 네이티브 가상화, UEFI pflash, Virtio
    private func buildAArch64Arguments(
        configuration: SandboxConfiguration,
        overlayDiskPath: String,
        monitorSocketPath: String
    ) -> [String] {
        var args: [String] = []

        // 머신: virt (ARM 표준 가상 플랫폼), GIC v3, highmem
        args += ["-machine", "virt,highmem=on,gic-version=3"]

        // 가속기 (Apple Silicon HVF)
        args += ["-accel", "hvf"]

        // CPU: host 패스스루 (Apple Silicon 코어 직접 노출)
        args += ["-cpu", "host"]
        args += ["-smp", "\(configuration.cpuCores)"]

        // 메모리
        args += ["-m", "\(configuration.memoryMB)"]

        // UEFI 펀웨어 (pflash) — Windows ARM에 필수
        if let firmwarePath = findEdk2Firmware("edk2-aarch64-code.fd") {
            args += [
                "-drive", "if=pflash,format=raw,file=\(firmwarePath),readonly=on"
            ]
            // EFI 변수 저장소 (VM별 복사본)
            if let varsPath = ensureEfiVarsFile() {
                args += ["-drive", "if=pflash,format=raw,file=\(varsPath)"]
            }
        }

        // 시스템 디스크 (virtio-blk)
        args += [
            "-drive", "file=\(overlayDiskPath),format=qcow2,if=none,id=hd0",
            "-device", "virtio-blk-pci,drive=hd0"
        ]

        // Windows ISO/ESD 설치 미디어
        if !configuration.windowsISOPath.isEmpty,
           FileManager.default.fileExists(atPath: configuration.windowsISOPath) {
            args += [
                "-drive", "file=\(configuration.windowsISOPath),media=cdrom,if=none,id=cdrom0",
                "-device", "virtio-blk-pci,drive=cdrom0,bootindex=1"
            ]
        }

        // 디스플레이
        if configuration.enableVGA {
            args += ["-device", "virtio-gpu-pci"]
            args += ["-display", "cocoa"]
        } else {
            args += ["-nographic"]
        }

        // 네트워크
        if configuration.networkingEnabled {
            switch configuration.networkMode {
            case .userMode:
                args += ["-netdev", "user,id=net0"]
                args += ["-device", "virtio-net-pci,netdev=net0"]
            case .bridged:
                args += ["-netdev", "bridge,id=net0,br=bridge0"]
                args += ["-device", "virtio-net-pci,netdev=net0"]
            case .none:
                args += ["-nic", "none"]
            }
        } else {
            args += ["-nic", "none"]
        }

        // USB (키보드/마우스)
        args += ["-device", "qemu-xhci"]
        args += ["-device", "usb-kbd"]
        args += ["-device", "usb-tablet"]

        // RTC
        args += ["-rtc", "base=localtime,clock=host"]

        // 공유 폴더 (virtio-9p)
        for folder in configuration.sharedFolders {
            let readOnlyOpt = folder.readOnly ? ",readonly=on" : ""
            args += [
                "-fsdev", "local,id=\(folder.guestMountTag),path=\(folder.hostPath),security_model=mapped-xattr\(readOnlyOpt)",
                "-device", "virtio-9p-pci,fsdev=\(folder.guestMountTag),mount_tag=\(folder.guestMountTag)"
            ]
        }

        // QMP 모니터 소켓
        args += ["-qmp", "unix:\(monitorSocketPath),server,nowait"]

        // 추가 인자
        args += configuration.additionalQEMUArgs

        return args
    }

    /// x86_64 VM 인자 생성 (기존 로직 유지)
    private func buildX86_64Arguments(
        configuration: SandboxConfiguration,
        overlayDiskPath: String,
        monitorSocketPath: String
    ) -> [String] {
        var args: [String] = []

        // 머신 타입
        args += ["-machine", "q35"]

        // 가속기 (macOS = HVF)
        if configuration.enableHVF {
            args += ["-accel", "hvf"]
        } else if configuration.enableKVM {
            args += ["-accel", "kvm"]
        }

        // CPU
        args += ["-cpu", "host"]
        args += ["-smp", "\(configuration.cpuCores)"]

        // 메모리
        args += ["-m", "\(configuration.memoryMB)"]

        // 디스크 (오버레이 이미지 사용)
        args += [
            "-drive", "file=\(overlayDiskPath),format=qcow2,if=virtio"
        ]

        // UEFI 펌웨어 (OVMF)
        if let ovmfPath = findEdk2Firmware("edk2-x86_64-code.fd") {
            args += ["-bios", ovmfPath]
        } else {
            let ovmfPaths = [
                "/opt/homebrew/share/qemu/edk2-x86_64-code.fd",
                "/usr/local/share/qemu/edk2-x86_64-code.fd",
                "/opt/homebrew/share/OVMF/OVMF_CODE.fd"
            ]
            if let ovmfPath = ovmfPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
                args += ["-bios", ovmfPath]
            }
        }

        // 디스플레이
        if configuration.enableVGA {
            args += ["-device", "virtio-vga"]
            args += ["-display", "cocoa"]
        } else {
            args += ["-nographic"]
        }

        // 네트워크
        switch configuration.networkMode {
        case .userMode:
            args += ["-netdev", "user,id=net0"]
            args += ["-device", "virtio-net-pci,netdev=net0"]
        case .bridged:
            args += ["-netdev", "bridge,id=net0,br=bridge0"]
            args += ["-device", "virtio-net-pci,netdev=net0"]
        case .none:
            args += ["-nic", "none"]
        }
        if !configuration.networkingEnabled {
            // 네트워크 비활성화 시 이전 설정 무시하고 nic none으로
            args = args.filter { !$0.contains("netdev") && !$0.contains("virtio-net") }
            args += ["-nic", "none"]
        }

        // 공유 폴더 (virtio-9p)
        for folder in configuration.sharedFolders {
            let readOnlyOpt = folder.readOnly ? ",readonly=on" : ""
            args += [
                "-fsdev", "local,id=\(folder.guestMountTag),path=\(folder.hostPath),security_model=mapped-xattr\(readOnlyOpt)",
                "-device", "virtio-9p-pci,fsdev=\(folder.guestMountTag),mount_tag=\(folder.guestMountTag)"
            ]
        }

        // USB 태블릿 (마우스 잡기 개선)
        args += ["-device", "usb-ehci"]
        args += ["-device", "usb-tablet"]

        // QMP 모니터 소켓
        args += ["-qmp", "unix:\(monitorSocketPath),server,nowait"]

        // 추가 인자
        args += configuration.additionalQEMUArgs

        return args
    }

    // MARK: - Firmware Helpers

    /// 번들된 EDK2 펀웨어 파일 탐색
    private func findEdk2Firmware(_ filename: String) -> String? {
        if let shareDir = bundledSharePath() {
            let path = (shareDir as NSString).appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        // 시스템 경로 폴백
        let systemPaths = [
            "/opt/homebrew/share/qemu/\(filename)",
            "/usr/local/share/qemu/\(filename)"
        ]
        return systemPaths.first(where: { FileManager.default.fileExists(atPath: $0) })
    }

    /// EFI 변수 저장 파일 (VM별 복사본) 생성
    private func ensureEfiVarsFile() -> String? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let varsDir = appSupport.appendingPathComponent("MacSandbox/efi", isDirectory: true)
        let varsFile = varsDir.appendingPathComponent("efi-vars.fd")

        if FileManager.default.fileExists(atPath: varsFile.path) {
            return varsFile.path
        }

        // 64MB 빈 파일 생성 (AAVMF 표준 크기)
        do {
            try FileManager.default.createDirectory(at: varsDir, withIntermediateDirectories: true)
            let emptyData = Data(count: 64 * 1024 * 1024)
            try emptyData.write(to: varsFile)
            return varsFile.path
        } catch {
            return nil
        }
    }

    private func sendQMPCommand(socketPath: String, command: String) {
        let socket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { return }
        defer { close(socket) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(104)) { dest in
                for (i, byte) in pathBytes.enumerated() where i < 104 {
                    dest[i] = byte
                }
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        _ = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(socket, sockPtr, addrLen)
            }
        }

        // QMP 핸드셰이크: greeting 읽고 capabilities 전송
        var buffer = [UInt8](repeating: 0, count: 4096)
        _ = read(socket, &buffer, buffer.count)

        let capabilitiesCmd = "{\"execute\": \"qmp_capabilities\"}\n"
        _ = capabilitiesCmd.withCString { ptr in
            write(socket, ptr, strlen(ptr))
        }
        _ = read(socket, &buffer, buffer.count)

        // 실제 명령 전송
        let cmdWithNewline = command + "\n"
        _ = cmdWithNewline.withCString { ptr in
            write(socket, ptr, strlen(ptr))
        }
    }

    private func cleanup(socketPath: String) {
        try? FileManager.default.removeItem(atPath: socketPath)
        self.process = nil
        self.monitorSocketPath = nil
    }
}

// MARK: - Errors

enum QEMUError: LocalizedError {
    case executableNotFound
    case startFailed(String)
    case alreadyRunning

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "QEMU 실행 파일을 찾을 수 없습니다. vendor/qemu이 누락되었습니다."
        case .startFailed(let reason):
            return "VM 시작 실패: \(reason)"
        case .alreadyRunning:
            return "VM이 이미 실행 중입니다."
        }
    }
}
