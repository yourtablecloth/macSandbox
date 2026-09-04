// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Copyright (C) 2026 Nam Jung Hyun (rkttu)
//
// This file is part of MacSandbox, which is dual-licensed:
//   (1) under the GNU Affero General Public License v3.0 or later (see LICENSE), or
//   (2) under a commercial license (see COMMERCIAL-LICENSE.md).
// You may use this file under the terms of either license.
//
// MacSandbox is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE.

import Foundation

/// Reconciles a baseline whose guest completed provisioning but whose host process stopped
/// before it could change metadata from `creating` to `ready`.
enum BaselineRecovery {
    enum Outcome: Equatable, Sendable {
        case notNeeded
        case recovered
        case failed(String)
    }

    static func recoverStoredBaseline() -> Outcome {
        recover(
            metadataURL: SandboxPaths.baselineMetadataPath,
            completionDiskURL: SandboxPaths.baselineDir.appendingPathComponent("oobe-status.img"),
            inspectCompletion: BuildCompletionDisk.inspect,
            credentialExists: { id in
                (try? BaselineCredentialStore.password(for: id)) != nil
            }
        )
    }

    /// Dependency-injected entry point keeps the on-disk state transition covered by tests.
    static func recover(
        metadataURL: URL,
        completionDiskURL: URL,
        inspectCompletion: (String) throws -> BuildCompletionDisk.InspectionResult,
        credentialExists: (String) -> Bool,
        now: Date = Date()
    ) -> Outcome {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: metadataURL),
              var metadata = try? decoder.decode(BaselineMetadata.self, from: data),
              metadata.status == .creating else {
            return .notNeeded
        }

        func fail(_ reason: String) -> Outcome {
            metadata.status = .error
            do {
                try save(metadata, to: metadataURL)
                return .failed(reason)
            } catch {
                return .failed("\(reason) Metadata update also failed: \(error.localizedDescription)")
            }
        }

        guard metadata.schemaVersion == BaselineMetadata.currentSchemaVersion else {
            return fail("The interrupted baseline uses an unsupported metadata schema.")
        }
        guard FileManager.default.fileExists(atPath: metadata.diskPath),
              FileManager.default.fileExists(atPath: metadata.efiVarsPath) else {
            return fail("The interrupted baseline is missing its disk or UEFI variables.")
        }
        guard FileManager.default.fileExists(atPath: completionDiskURL.path) else {
            return fail("The previous baseline build stopped before reporting guest completion.")
        }

        let completion: BuildCompletionDisk.InspectionResult
        do {
            completion = try inspectCompletion(completionDiskURL.path)
        } catch {
            return fail("Could not inspect the interrupted baseline completion marker: \(error.localizedDescription)")
        }

        switch completion {
        case .success:
            guard credentialExists(metadata.credentialID) else {
                return fail("The interrupted baseline no longer has its saved credential.")
            }
            metadata.status = .ready
            metadata.createdAt = now
            do {
                try save(metadata, to: metadataURL)
                try? FileManager.default.removeItem(at: completionDiskURL)
                return .recovered
            } catch {
                return .failed("Could not finalize the interrupted baseline metadata: \(error.localizedDescription)")
            }
        case .failure(let reason):
            return fail("Windows provisioning failed before the app stopped: \(reason)")
        case .missing:
            return fail("The previous baseline build stopped without a guest completion marker.")
        }
    }

    private static func save(_ metadata: BaselineMetadata, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(to: url, options: .atomic)
    }
}
