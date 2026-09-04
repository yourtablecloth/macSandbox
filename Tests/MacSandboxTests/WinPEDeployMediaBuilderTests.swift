import XCTest
@testable import MacSandbox

final class WinPEDeployMediaBuilderTests: XCTestCase {
    func testAppRemovalDoesNotDependOnFindstr() {
        let script = WinPEDeployMediaBuilder.deployCmdContent(imageEdition: "Windows 11 Pro")

        XCTAssertFalse(script.lowercased().contains("findstr"))
        XCTAssertTrue(script.contains("setlocal EnableExtensions EnableDelayedExpansion"))
        XCTAssertTrue(script.contains("/Get-ProvisionedAppxPackages > X:\\Windows\\Temp\\msbx-appx.txt"))
        XCTAssertTrue(script.contains("usebackq tokens=1,* delims=:"))
        XCTAssertTrue(script.contains("if defined REMOVE"))
        XCTAssertTrue(script.contains("/Remove-ProvisionedAppxPackage /PackageName:\"!PKG!\""))
    }

    func testEveryRemovalKeywordIsEmittedAsABatchSubstringCheck() {
        let script = WinPEDeployMediaBuilder.deployCmdContent(imageEdition: "Windows 11 Pro")

        for keyword in WinPEDeployMediaBuilder.removeAppxKeywords {
            XCTAssertTrue(script.contains("!PKG:\(keyword)=!"), "Missing Appx keyword: \(keyword)")
        }
    }
}
