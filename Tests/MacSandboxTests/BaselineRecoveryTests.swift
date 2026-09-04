import Foundation
import XCTest
@testable import MacSandbox

final class BaselineRecoveryTests: XCTestCase {
    func testSuccessfulGuestMarkerPromotesInterruptedBaselineToReady() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let recoveredAt = Date(timeIntervalSince1970: 1_800_000_000)

        let outcome = BaselineRecovery.recover(
            metadataURL: fixture.metadataURL,
            completionDiskURL: fixture.completionDiskURL,
            inspectCompletion: { _ in .success },
            credentialExists: { $0 == fixture.credentialID },
            now: recoveredAt
        )

        XCTAssertEqual(outcome, .recovered)
        let metadata = try decodeMetadata(at: fixture.metadataURL)
        XCTAssertEqual(metadata.status, .ready)
        XCTAssertEqual(metadata.createdAt, recoveredAt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.completionDiskURL.path))
    }

    func testMissingGuestMarkerChangesInterruptedBaselineToError() throws {
        let fixture = try makeFixture(createCompletionDisk: false)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let outcome = BaselineRecovery.recover(
            metadataURL: fixture.metadataURL,
            completionDiskURL: fixture.completionDiskURL,
            inspectCompletion: { _ in .missing },
            credentialExists: { _ in true }
        )

        guard case .failed(let reason) = outcome else {
            return XCTFail("Expected interrupted recovery to fail")
        }
        XCTAssertTrue(reason.contains("before reporting guest completion"))
        XCTAssertEqual(try decodeMetadata(at: fixture.metadataURL).status, .error)
    }

    private func makeFixture(createCompletionDisk: Bool = true) throws -> (
        directory: URL, metadataURL: URL, completionDiskURL: URL, credentialID: String
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macsandbox-recovery-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let diskURL = directory.appendingPathComponent("baseline.qcow2")
        let efiURL = directory.appendingPathComponent("efi-vars.fd")
        let completionDiskURL = directory.appendingPathComponent("oobe-status.img")
        let metadataURL = directory.appendingPathComponent("metadata.json")
        let credentialID = UUID().uuidString
        XCTAssertTrue(FileManager.default.createFile(atPath: diskURL.path, contents: Data()))
        XCTAssertTrue(FileManager.default.createFile(atPath: efiURL.path, contents: Data()))
        if createCompletionDisk {
            XCTAssertTrue(FileManager.default.createFile(atPath: completionDiskURL.path, contents: Data()))
        }

        let metadata = BaselineMetadata(
            schemaVersion: BaselineMetadata.currentSchemaVersion,
            credentialID: credentialID,
            name: "Windows 11 ARM64",
            diskPath: diskURL.path,
            efiVarsPath: efiURL.path,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            diskSizeGB: 256,
            locale: "ko-KR",
            status: .creating
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(to: metadataURL)
        return (directory, metadataURL, completionDiskURL, credentialID)
    }

    private func decodeMetadata(at url: URL) throws -> BaselineMetadata {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BaselineMetadata.self, from: Data(contentsOf: url))
    }
}
