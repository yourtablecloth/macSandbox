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

/// Baseline 1-round build orchestrator
///
/// Create disk → prepare UEFI variables → generate unattended answer ISO → QEMU unattended install →
/// (guest shutdown = install complete) → save metadata.
enum BuildError: LocalizedError {
    case installFailed(String)
    var errorDescription: String? {
        switch self {
        case .installFailed(let reason): return reason
        }
    }
}

@MainActor
final class BaselineBuilder: ObservableObject {

    @Published private(set) var phase: BuildPhase = .idle
    @Published private(set) var detail: String = ""
    @Published private(set) var isRunning = false
    /// Interactive console while the install is in progress (screen + keyboard/mouse intervention). nil when idle.
    @Published var console: VMConsole?
    /// Logs use a separate throttling store — kept apart so views observing the builder don't re-render on every log line.
    let logBuffer = LogBuffer()

    /// Called whenever a log is appended (for stdout output in headless/CLI)
    var logHandler: ((String) -> Void)?

    private let disk = DiskService()
    private let unattend = UnattendBuilder()
    private let runtime = QEMURuntime()

    /// Install timeout (default 60 minutes)
    private let installTimeout: TimeInterval = 60 * 60

    // MARK: - Baseline lookup

    func currentBaseline() -> BaselineMetadata? {
        guard let data = try? Data(contentsOf: SandboxPaths.baselineMetadataPath) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(BaselineMetadata.self, from: data)
    }

    /// On launch, complete or fail a build transaction left in `creating` by a host crash.
    /// The guest marker is authoritative, and recovery also verifies the baseline files and credential.
    @discardableResult
    func recoverInterruptedBuild() async -> Bool {
        guard !isRunning else { return false }
        let outcome = await Task.detached(priority: .userInitiated) {
            BaselineRecovery.recoverStoredBaseline()
        }.value

        switch outcome {
        case .notNeeded:
            return false
        case .recovered:
            updatePhase(.completed, L("build.detail.done"))
            appendLog("Interrupted baseline finalized from the verified guest completion marker")
            return true
        case .failed(let reason):
            updatePhase(.failed(reason), reason)
            appendLog("Interrupted baseline recovery failed: \(reason)")
            return false
        }
    }

    // MARK: - Build

    func build(config: InstallConfig, headless: Bool = false) async {
        guard !isRunning else { return }
        isRunning = true
        logBuffer.clear()
        var credentialID: String?
        var buildSucceeded = false
        var provisioningArtifacts: [URL] = []
        defer {
            isRunning = false
            for artifact in provisioningArtifacts {
                try? FileManager.default.removeItem(at: artifact)
            }
            if !buildSucceeded, let credentialID {
                BaselineCredentialStore.delete(id: credentialID)
            }
        }

        // Shared sink through which background stages (media build/download) hand logs to the main actor.
        // Snapshot weak self into a local let before passing it to a Task (referencing a mutable weak reference
        // directly in a concurrency closure is treated as an error by some Swift versions — being a @MainActor class, even the Optional is Sendable).
        let logSink: @Sendable (String) -> Void = { [weak self] msg in
            let me = self
            Task { @MainActor in me?.appendLog(msg) }
        }

        do {
            try SandboxPaths.ensureBaseDirectories()

            // 0. Pre-checks — surface failures that would otherwise blow up late (tens of minutes into the install) early and clearly.
            //    During deployment, qcow2 actual usage grows up to 10–20GB, plus a 1.3GB boot disk + 0.7GB virtio ISO.
            try checkFreeDiskSpace(minimumBytes: 24_000_000_000)
            guard FileManager.default.isReadableFile(atPath: config.isoPath) else {
                throw BuildError.installFailed("ISO is not readable: \(config.isoPath)")
            }

            // 1. Initialize the baseline directory (single-baseline policy: replace the existing one)
            updatePhase(.preparingDisk, L("build.detail.cleanup"))
            let baselineDir = SandboxPaths.baselineDir
            let previousCredentialID = currentBaseline()?.credentialID
            if FileManager.default.fileExists(atPath: baselineDir.path) {
                try FileManager.default.removeItem(at: baselineDir)
            }
            if let previousCredentialID {
                BaselineCredentialStore.delete(id: previousCredentialID)
            }
            try FileManager.default.createDirectory(at: baselineDir, withIntermediateDirectories: true)

            let diskPath = SandboxPaths.baselineDiskPath.path
            let efiVarsPath = SandboxPaths.baselineEfiVarsPath.path
            let newCredentialID = UUID().uuidString
            let rdpPassword = try BaselineCredentialStore.generatePassword()
            try BaselineCredentialStore.save(password: rdpPassword, id: newCredentialID)
            credentialID = newCredentialID

            var meta = BaselineMetadata(
                schemaVersion: BaselineMetadata.currentSchemaVersion,
                credentialID: newCredentialID,
                name: "Windows 11 ARM64",
                diskPath: diskPath,
                efiVarsPath: efiVarsPath,
                createdAt: Date(),
                diskSizeGB: config.diskSizeGB,
                locale: config.locale,
                status: .creating
            )
            try saveMetadata(meta)

            // 2. Create the qcow2 NVMe target disk (qemu-img process — off the main thread)
            updatePhase(.preparingDisk, L("build.detail.disk", config.diskSizeGB))
            let diskService = disk
            try await Task.detached(priority: .userInitiated) {
                try diskService.createQcow2(at: diskPath, sizeGB: config.diskSizeGB)
            }.value
            appendLog("Disk created: \(diskPath)")

            // 3. Verify UEFI firmware
            updatePhase(.preparingFirmware, L("build.detail.firmware"))
            guard let efiCode = SandboxPaths.edk2CodeFirmware(),
                  let varsTemplate = SandboxPaths.edk2VarsTemplate() else {
                throw QEMURuntime.RuntimeError.firmwareNotFound
            }

            // 4. Create WinPE DISM deployment media (GPT FAT32 boot disk — editing boot.wim)
            //    This takes several minutes via synchronous hdiutil/wimlib/diskutil work — blocking the main thread
            //    leads to a run-loop stall (IMK mach port errors / unresponsive), so it must run in the background.
            updatePhase(.generatingUnattend, L("build.detail.media"))
            let bootDisk = baselineDir.appendingPathComponent("wpe-boot.img").path
            provisioningArtifacts.append(URL(fileURLWithPath: bootDisk))
            let pantherXML = try unattend.generatePantherXML(config: config)
            let mediaInputs = WinPEDeployMediaBuilder.Inputs(
                isoPath: config.isoPath, imageEdition: config.imageEdition,
                pantherUnattendXML: pantherXML,
                provisioningPowerShell: unattend.generateProvisioningPowerShell(rdpPassword: rdpPassword),
                bootDiskPath: bootDisk)
            try await Task.detached(priority: .userInitiated) {
                try WinPEDeployMediaBuilder.build(mediaInputs, onLog: logSink)
            }.value
            appendLog("Deployment media: \(bootDisk)")

            let serialLog = headless ? baselineDir.appendingPathComponent("uefi-serial.log").path : nil

            // 4.5 Obtain the virtio-win driver ISO — if not cached, downloads ~700MB (also in the background).
            updatePhase(.generatingUnattend, L("build.detail.drivers"))
            let virtioISO = try await Task.detached(priority: .userInitiated) {
                try GuestDrivers.ensureVirtioWinISO(onLog: logSink)
            }.value

            // 5. Phase 1 — WinPE deployment (zero prompts/key input, fully deterministic)
            updatePhase(.installing, L("build.detail.phase1"))
            let efiVarsDeploy = baselineDir.appendingPathComponent("efi-vars-deploy.fd").path
            provisioningArtifacts.append(URL(fileURLWithPath: efiVarsDeploy))
            try FileManager.default.copyItem(atPath: varsTemplate.path, toPath: efiVarsDeploy)
            let deployExit = try await runPhase(name: "deploy", headless: headless) { sock in
                self.runtime.buildDeployArguments(
                    bootDiskPath: bootDisk, windowsISOPath: config.isoPath, nvmePath: diskPath,
                    efiCodePath: efiCode.path, efiVarsPath: efiVarsDeploy, virtioISOPath: virtioISO,
                    cpuCores: config.cpuCores, memoryMB: config.memoryMB,
                    qmpSocketPath: sock, serialLogPath: serialLog)
            }
            guard deployExit == 0 else {
                throw BuildError.installFailed("Deploy phase exited abnormally (exit=\(deployExit)).")
            }
            let deployedSize = ((try? FileManager.default.attributesOfItem(atPath: diskPath))?[.size] as? Int64) ?? 0
            appendLog("Disk after deploy: \(deployedSize / 1_000_000)MB")
            guard deployedSize >= 3_000_000_000 else {
                throw BuildError.installFailed("Disk after deploy is only \(deployedSize / 1_000_000)MB — DISM apply may have failed.")
            }
            try? FileManager.default.removeItem(atPath: bootDisk)
            try? FileManager.default.removeItem(atPath: efiVarsDeploy)

            // 6. Phase 2 — first-boot configuration (specialize/oobe → shutdown after first logon)
            updatePhase(.installing, L("build.detail.phase2"))
            let efiVarsOobe = SandboxPaths.baselineEfiVarsPath.path
            if FileManager.default.fileExists(atPath: efiVarsOobe) { try FileManager.default.removeItem(atPath: efiVarsOobe) }
            try FileManager.default.copyItem(atPath: varsTemplate.path, toPath: efiVarsOobe)
            let completionDisk = baselineDir.appendingPathComponent("oobe-status.img").path
            provisioningArtifacts.append(URL(fileURLWithPath: completionDisk))
            try await Task.detached(priority: .userInitiated) {
                try BuildCompletionDisk.create(at: completionDisk)
            }.value
            let oobeExit = try await runPhase(name: "oobe", headless: headless) { sock in
                self.runtime.buildOobeArguments(
                    nvmePath: diskPath, completionDiskPath: completionDisk,
                    efiCodePath: efiCode.path, efiVarsPath: efiVarsOobe,
                    cpuCores: config.cpuCores, memoryMB: config.memoryMB,
                    qmpSocketPath: sock, serialLogPath: serialLog)
            }
            guard oobeExit == 0 else {
                throw BuildError.installFailed("OOBE phase exited abnormally (exit=\(oobeExit)).")
            }
            let completion = try await Task.detached(priority: .userInitiated) {
                try BuildCompletionDisk.inspect(at: completionDisk)
            }.value
            switch completion {
            case .success:
                appendLog("Guest provisioning completion marker verified")
            case .failure(let reason):
                throw BuildError.installFailed("Windows provisioning failed: \(reason)")
            case .missing:
                throw BuildError.installFailed("Windows stopped without reporting successful baseline provisioning.")
            }

            // 7. Finalize
            updatePhase(.finalizing, L("build.detail.finalize"))
            meta.status = .ready
            meta.createdAt = Date()
            try saveMetadata(meta)
            buildSucceeded = true

            updatePhase(.completed, L("build.detail.done"))
            appendLog("✅ Baseline created (fully deterministic WinPE DISM deployment)")
        } catch {
            console?.stop()
            console = nil
            updatePhase(.failed(error.localizedDescription), error.localizedDescription)
            appendLog("❌ Failed: \(error.localizedDescription)")
            if var meta = currentBaseline() {
                meta.status = .error
                try? saveMetadata(meta)
            }
        }
    }

    func cancel() {
        runtime.forceStop()
        appendLog("Cancelled by user — VM stop requested")
    }

    // MARK: - Private

    /// Runs one QEMU phase. Brings up an interactive console (screen monitoring + user intervention)
    /// and waits until the process exits. (Both deploy/OOBE have no boot prompt, so no key injection is needed.)
    private func runPhase(name: String, headless: Bool,
                          argsBuilder: (String) -> [String]) async throws -> Int32 {
        let qmpSocket = "/tmp/msbx-\(UUID().uuidString.prefix(8)).sock"
        let args = argsBuilder(qmpSocket)
        appendLog("[\(name)] QEMU started")
        let console = VMConsole(socketPath: qmpSocket, capturesFrames: !headless)
        self.console = console
        console.start()
        let exit = try await runtime.runUntilExit(
            arguments: args, qmpSocketPath: qmpSocket, timeoutSeconds: installTimeout
        ) { [weak self] out in
            let me = self
            Task { @MainActor in me?.appendLog(out) }
        }
        console.stop()
        self.console = nil
        appendLog("[\(name)] QEMU exited (exit=\(exit))")
        return exit
    }

    private func updatePhase(_ phase: BuildPhase, _ detail: String) {
        self.phase = phase
        self.detail = detail
    }

    /// Checks free space on the baseline storage volume (passes if measurement fails — it would fail naturally during the install stage).
    private func checkFreeDiskSpace(minimumBytes: Int64) throws {
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = values?.volumeAvailableCapacityForImportantUsage else { return }
        if free < minimumBytes {
            let fmt = ByteCountFormatter()
            throw BuildError.installFailed(L("error.lowDiskSpace",
                fmt.string(fromByteCount: free), fmt.string(fromByteCount: minimumBytes)))
        }
    }

    private func saveMetadata(_ meta: BaselineMetadata) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(meta).write(to: SandboxPaths.baselineMetadataPath, options: .atomic)
    }

    private func appendLog(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else { return }
        logBuffer.append(trimmed)
        logHandler?(trimmed)
    }
}
