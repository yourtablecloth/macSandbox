import Foundation
import XCTest
@testable import MacSandbox

final class UnattendBuilderTests: XCTestCase {
    func testGeneratedAnswerFileIsValidAndCommandsFitWindowsLimit() throws {
        let builder = UnattendBuilder()
        let xml = try builder.generatePantherXML(config: InstallConfig(isoPath: "/tmp/windows.iso"))
        let document = try XMLDocument(xmlString: xml, options: [])
        let commandLines = try document.nodes(forXPath: "//*[local-name()='CommandLine']")

        XCTAssertEqual(commandLines.count, 1)
        XCTAssertTrue(commandLines.allSatisfy {
            ($0.stringValue?.count ?? 0) <= UnattendBuilder.maximumCommandLineLength
        })
        XCTAssertTrue(commandLines[0].stringValue?.contains(UnattendBuilder.provisioningScriptPath) == true)
    }

    func testPasswordLivesOnlyInExternalProvisioningScript() throws {
        let password = "Aa1TestPassword0123456789"
        let builder = UnattendBuilder()
        let xml = try builder.generatePantherXML(config: InstallConfig(isoPath: "/tmp/windows.iso"))
        let script = builder.generateProvisioningPowerShell(rdpPassword: password)

        XCTAssertFalse(xml.contains(password))
        XCTAssertTrue(script.contains(password))
        XCTAssertTrue(script.contains(BuildCompletionDisk.volumeLabel))
        XCTAssertTrue(script.contains(BuildCompletionDisk.successToken))
        XCTAssertTrue(script.contains("Remove-Item -LiteralPath $PSCommandPath -Force"))
        XCTAssertTrue(script.contains("shutdown.exe /s /t 15 /f"))
    }

    func testOobeArgumentsAttachWritableCompletionDisk() {
        let arguments = QEMURuntime().buildOobeArguments(
            nvmePath: "/tmp/baseline.qcow2",
            completionDiskPath: "/tmp/oobe-status.img",
            efiCodePath: "/tmp/code.fd",
            efiVarsPath: "/tmp/vars.fd",
            cpuCores: 4,
            memoryMB: 8_192,
            qmpSocketPath: "/tmp/qmp.sock"
        )

        XCTAssertTrue(arguments.contains("nvme,drive=sysdisk,serial=s0,bootindex=0"))
        XCTAssertTrue(arguments.contains("if=none,id=oobestatus,format=raw,file=/tmp/oobe-status.img"))
        XCTAssertTrue(arguments.contains("usb-storage,drive=oobestatus,removable=on"))
    }

    func testFreshCompletionDiskDoesNotReportSuccess() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macsandbox-completion-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("status.img").path

        try BuildCompletionDisk.create(at: path)
        XCTAssertEqual(try BuildCompletionDisk.inspect(at: path), .missing)
    }
}
