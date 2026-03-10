import Foundation

/// Windows 11 무인 설치(Unattended Install)용 autounattend.xml 생성 서비스
final class UnattendGenerator {

    /// Unattend 생성 시 사용하는 파라미터
    struct Parameters {
        var locale: String = "ko-KR"
        var username: String = "User"
        var password: String = ""
        var computerName: String = "SANDBOX"
        var diskSizeGB: Int = 64

        /// virtio 드라이버 ISO가 마운트된 경우 드라이버 경로 포함
        var includeVirtioDrivers: Bool = false
        /// 게스트 아키텍처 (드라이버 경로 결정)
        var architecture: SandboxConfiguration.GuestArchitecture = .aarch64
    }

    /// autounattend.xml 문자열 생성
    func generateXML(parameters: Parameters = Parameters()) -> String {
        let inputLocale = parameters.locale
        let uiLanguage = parameters.locale
        let username = xmlEscape(parameters.username)
        let computerName = xmlEscape(parameters.computerName)

        let passwordSection: String
        if parameters.password.isEmpty {
            passwordSection = """
                            <Password>
                                <Value></Value>
                                <PlainText>true</PlainText>
                            </Password>
            """
        } else {
            passwordSection = """
                            <Password>
                                <Value>\(xmlEscape(parameters.password))</Value>
                                <PlainText>true</PlainText>
                            </Password>
            """
        }

        let driverPathsSection: String
        if parameters.includeVirtioDrivers {
            let archDir = parameters.architecture == .aarch64 ? "ARM64" : "amd64"
            driverPathsSection = """
                    <DriverPaths>
                        <PathAndCredentials wcm:action="add" wcm:keyValue="1">
                            <Path>E:\\viostor\\w11\\\(archDir)</Path>
                        </PathAndCredentials>
                        <PathAndCredentials wcm:action="add" wcm:keyValue="2">
                            <Path>E:\\NetKVM\\w11\\\(archDir)</Path>
                        </PathAndCredentials>
                        <PathAndCredentials wcm:action="add" wcm:keyValue="3">
                            <Path>E:\\viogpudo\\w11\\\(archDir)</Path>
                        </PathAndCredentials>
                    </DriverPaths>
            """
        } else {
            driverPathsSection = ""
        }

        return """
        <?xml version="1.0" encoding="utf-8"?>
        <unattend xmlns="urn:schemas-microsoft-com:unattend"
                  xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">

            <!-- windowsPE 패스: 디스크 파티션 및 이미지 설치 -->
            <settings pass="windowsPE">
                <component name="Microsoft-Windows-International-Core-WinPE"
                           processorArchitecture="\(processorArchitecture(parameters.architecture))"
                           publicKeyToken="31bf3856ad364e35"
                           language="neutral"
                           versionScope="nonSxS">
                    <SetupUILanguage>
                        <UILanguage>\(uiLanguage)</UILanguage>
                    </SetupUILanguage>
                    <InputLocale>\(inputLocale)</InputLocale>
                    <UILanguage>\(uiLanguage)</UILanguage>
                    <UserLocale>\(inputLocale)</UserLocale>
                    <SystemLocale>\(inputLocale)</SystemLocale>
                </component>

                <component name="Microsoft-Windows-Setup"
                           processorArchitecture="\(processorArchitecture(parameters.architecture))"
                           publicKeyToken="31bf3856ad364e35"
                           language="neutral"
                           versionScope="nonSxS">
        \(driverPathsSection)
                    <DiskConfiguration>
                        <Disk wcm:action="add">
                            <DiskID>0</DiskID>
                            <WillWipeDisk>true</WillWipeDisk>
                            <CreatePartitions>
                                <!-- EFI System Partition -->
                                <CreatePartition wcm:action="add">
                                    <Order>1</Order>
                                    <Size>100</Size>
                                    <Type>EFI</Type>
                                </CreatePartition>
                                <!-- Microsoft Reserved Partition -->
                                <CreatePartition wcm:action="add">
                                    <Order>2</Order>
                                    <Size>16</Size>
                                    <Type>MSR</Type>
                                </CreatePartition>
                                <!-- Windows Partition -->
                                <CreatePartition wcm:action="add">
                                    <Order>3</Order>
                                    <Extend>true</Extend>
                                    <Type>Primary</Type>
                                </CreatePartition>
                            </CreatePartitions>
                            <ModifyPartitions>
                                <ModifyPartition wcm:action="add">
                                    <Order>1</Order>
                                    <PartitionID>1</PartitionID>
                                    <Format>FAT32</Format>
                                    <Label>EFI</Label>
                                </ModifyPartition>
                                <ModifyPartition wcm:action="add">
                                    <Order>2</Order>
                                    <PartitionID>3</PartitionID>
                                    <Format>NTFS</Format>
                                    <Label>Windows</Label>
                                    <Letter>C</Letter>
                                </ModifyPartition>
                            </ModifyPartitions>
                        </Disk>
                    </DiskConfiguration>

                    <ImageInstall>
                        <OSImage>
                            <InstallTo>
                                <DiskID>0</DiskID>
                                <PartitionID>3</PartitionID>
                            </InstallTo>
                        </OSImage>
                    </ImageInstall>

                    <UserData>
                        <AcceptEula>true</AcceptEula>
                        <ProductKey>
                            <WillShowUI>OnError</WillShowUI>
                        </ProductKey>
                    </UserData>
                </component>
            </settings>

            <!-- specialize 패스: 컴퓨터 이름, 로케일 -->
            <settings pass="specialize">
                <component name="Microsoft-Windows-Shell-Setup"
                           processorArchitecture="\(processorArchitecture(parameters.architecture))"
                           publicKeyToken="31bf3856ad364e35"
                           language="neutral"
                           versionScope="nonSxS">
                    <ComputerName>\(computerName)</ComputerName>
                </component>

                <component name="Microsoft-Windows-International-Core"
                           processorArchitecture="\(processorArchitecture(parameters.architecture))"
                           publicKeyToken="31bf3856ad364e35"
                           language="neutral"
                           versionScope="nonSxS">
                    <InputLocale>\(inputLocale)</InputLocale>
                    <UILanguage>\(uiLanguage)</UILanguage>
                    <UserLocale>\(inputLocale)</UserLocale>
                    <SystemLocale>\(inputLocale)</SystemLocale>
                </component>
            </settings>

            <!-- oobeSystem 패스: OOBE 스킵, 계정 생성, 자동 로그온, 설치 후 셧다운 -->
            <settings pass="oobeSystem">
                <component name="Microsoft-Windows-Shell-Setup"
                           processorArchitecture="\(processorArchitecture(parameters.architecture))"
                           publicKeyToken="31bf3856ad364e35"
                           language="neutral"
                           versionScope="nonSxS">
                    <OOBE>
                        <HideEULAPage>true</HideEULAPage>
                        <HideLocalAccountScreen>true</HideLocalAccountScreen>
                        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                        <ProtectYourPC>3</ProtectYourPC>
                        <SkipMachineOOBE>true</SkipMachineOOBE>
                        <SkipUserOOBE>true</SkipUserOOBE>
                    </OOBE>

                    <UserAccounts>
                        <LocalAccounts>
                            <LocalAccount wcm:action="add">
                                <Name>\(username)</Name>
                                <Group>Administrators</Group>
        \(passwordSection)
                                <DisplayName>\(username)</DisplayName>
                            </LocalAccount>
                        </LocalAccounts>
                    </UserAccounts>

                    <AutoLogon>
                        <Enabled>true</Enabled>
                        <Username>\(username)</Username>
                        <LogonCount>1</LogonCount>
                        <Password>
                            <Value>\(xmlEscape(parameters.password))</Value>
                            <PlainText>true</PlainText>
                        </Password>
                    </AutoLogon>

                    <FirstLogonCommands>
                        <SynchronousCommand wcm:action="add">
                            <Order>1</Order>
                            <CommandLine>cmd.exe /c shutdown /s /t 30 /f</CommandLine>
                            <Description>Shutdown after baseline setup</Description>
                        </SynchronousCommand>
                    </FirstLogonCommands>
                </component>

                <component name="Microsoft-Windows-International-Core"
                           processorArchitecture="\(processorArchitecture(parameters.architecture))"
                           publicKeyToken="31bf3856ad364e35"
                           language="neutral"
                           versionScope="nonSxS">
                    <InputLocale>\(inputLocale)</InputLocale>
                    <UILanguage>\(uiLanguage)</UILanguage>
                    <UserLocale>\(inputLocale)</UserLocale>
                    <SystemLocale>\(inputLocale)</SystemLocale>
                </component>
            </settings>
        </unattend>
        """
    }

    /// autounattend.xml을 포함하는 ISO 이미지 생성
    /// - Parameters:
    ///   - parameters: Unattend XML 생성 파라미터
    ///   - outputPath: 생성할 ISO 파일 경로
    /// - Returns: 생성된 ISO 파일 경로
    func generateISO(parameters: Parameters = Parameters(), outputPath: String) throws -> String {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("macsandbox-unattend-\(UUID().uuidString)")

        defer {
            try? fm.removeItem(at: tempDir)
        }

        // 1. 임시 디렉토리 생성 및 autounattend.xml 배치
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let xmlContent = generateXML(parameters: parameters)
        let xmlPath = tempDir.appendingPathComponent("autounattend.xml")
        try xmlContent.write(to: xmlPath, atomically: true, encoding: .utf8)

        // 2. hdiutil로 ISO 생성
        // 출력 경로에서 .iso 확장자 제거 (hdiutil이 자동으로 .iso 추가)
        let outputBase = outputPath.hasSuffix(".iso")
            ? String(outputPath.dropLast(4))
            : outputPath

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = [
            "makehybrid",
            "-o", outputBase,
            "-joliet",
            "-iso",
            tempDir.path
        ]

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMsg = String(data: errorData, encoding: .utf8) ?? "알 수 없는 오류"
            throw UnattendError.isoCreationFailed(errorMsg)
        }

        // hdiutil은 자동으로 .iso 확장자를 추가할 수 있음
        let finalPath = fm.fileExists(atPath: outputBase + ".iso")
            ? outputBase + ".iso"
            : outputBase

        guard fm.fileExists(atPath: finalPath) else {
            throw UnattendError.isoCreationFailed("ISO 파일이 생성되지 않았습니다")
        }

        return finalPath
    }

    // MARK: - Private Helpers

    private func processorArchitecture(_ arch: SandboxConfiguration.GuestArchitecture) -> String {
        switch arch {
        case .aarch64: return "arm64"
        case .x86_64: return "amd64"
        }
    }

    private func xmlEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

// MARK: - Errors

enum UnattendError: LocalizedError {
    case isoCreationFailed(String)

    var errorDescription: String? {
        switch self {
        case .isoCreationFailed(let detail):
            return "Unattend ISO 생성 실패: \(detail)"
        }
    }
}
