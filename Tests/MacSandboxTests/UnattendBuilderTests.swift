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
        XCTAssertTrue(script.contains("Remove-Item -LiteralPath $PSCommandPath -Force"))
        XCTAssertTrue(script.contains("shutdown.exe /s /t 15 /f"))
    }
}
