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

/// QEMU (qemu-system-aarch64) process lifecycle + install-mode argument building
///
/// Driverless install configuration:
/// - System disk: NVMe (Windows ARM inbox stornvme driver)
/// - Install/answer media: USB mass storage (WinPE inbox usbstor driver)
/// - Display: ramfb (UEFI GOP framebuffer → Windows default display, no guest driver needed)
/// - Acceleration: HVF (Hypervisor.framework)
final class QEMURuntime {

    enum RuntimeError: LocalizedError {
        case qemuNotFound
        case firmwareNotFound

        var errorDescription: String? {
            switch self {
            case .qemuNotFound:
                return L("error.qemuNotFound")
            case .firmwareNotFound:
                return L("error.firmwareNotFound")
            }
        }
    }

    private let lock = NSLock()
    private var process: Process?
    private var watchdog: Process?

    private func storeProcess(_ p: Process?) {
        lock.lock(); process = p; lock.unlock()
    }

    private func currentProcess() -> Process? {
        lock.lock(); defer { lock.unlock() }
        return process
    }

    private func storeWatchdog(_ p: Process?) {
        lock.lock(); watchdog = p; lock.unlock()
    }

    private func currentWatchdog() -> Process? {
        lock.lock(); defer { lock.unlock() }
        return watchdog
    }

    /// Parent-death watchdog.
    ///
    /// macOS has no `PR_SET_PDEATHSIG`, so if the app is SIGKILLed/crashes, the child QEMU is left as an orphan.
    /// We spawn a small monitor process that polls both the app (parent) PID and the QEMU PID, and **once the app disappears**
    /// it reliably destroys QEMU via TERM→KILL (even if the app dies, this monitor process survives to perform cleanup).
    /// If QEMU dies first, the loop ends and it exits on its own.
    private func spawnWatchdog(qemuPID: Int32) {
        let appPID = ProcessInfo.processInfo.processIdentifier
        let script = """
        while /bin/kill -0 \(appPID) 2>/dev/null && /bin/kill -0 \(qemuPID) 2>/dev/null; do /bin/sleep 1; done
        if /bin/kill -0 \(qemuPID) 2>/dev/null; then
          /bin/kill -TERM \(qemuPID) 2>/dev/null
          /bin/sleep 3
          /bin/kill -KILL \(qemuPID) 2>/dev/null
        fi
        """
        let wd = Process()
        wd.executableURL = URL(fileURLWithPath: "/bin/sh")
        wd.arguments = ["-c", script]
        wd.standardOutput = FileHandle.nullDevice
        wd.standardError = FileHandle.nullDevice
        do {
            try wd.run()           // a child, but if the app dies it gets reparented to launchd and keeps polling → removes the orphan
            storeWatchdog(wd)
        } catch {
            storeWatchdog(nil)
        }
    }

    // MARK: - WinPE DISM deployment arguments

    /// Common base arguments (machine/acceleration/CPU/memory/UEFI/display/network/QMP)
    private func baseArguments(
        name: String, efiCodePath: String, efiVarsPath: String,
        cpuCores: Int, memoryMB: Int, qmpSocketPath: String, serialLogPath: String?
    ) -> [String] {
        var args: [String] = []
        args += ["-name", name]
        args += ["-machine", "virt,highmem=on,gic-version=3"]
        args += ["-accel", "hvf"]
        args += ["-cpu", "host"]
        args += ["-smp", "\(cpuCores)"]
        args += ["-m", "\(memoryMB)"]
        args += ["-drive", "if=pflash,format=raw,readonly=on,file=\(efiCodePath)"]
        args += ["-drive", "if=pflash,format=raw,file=\(efiVarsPath)"]
        // Drive EDK II's front-page timeout to zero even when an existing VARS
        // store contains an older nonzero Timeout value.
        args += ["-boot", "menu=on,splash-time=0"]
        args += ["-device", "ramfb"]
        args += ["-display", "none"]
        args += ["-vnc", "127.0.0.1:1"]
        if let serialLogPath { args += ["-serial", "file:\(serialLogPath)"] }
        args += ["-nic", "none"]
        args += ["-rtc", "base=localtime,clock=host"]
        args += ["-qmp", "unix:\(qmpSocketPath),server,nowait"]
        return args
    }

    /// Phase 1 (deploy): GPT FAT32 WinPE boot disk + Windows ISO (install.wim) + empty NVMe target.
    /// WinPE boots without a prompt and runs diskpart+dism+bcdboot via deploy.cmd, then shuts down.
    func buildDeployArguments(
        bootDiskPath: String, windowsISOPath: String, nvmePath: String,
        efiCodePath: String, efiVarsPath: String, virtioISOPath: String? = nil,
        cpuCores: Int, memoryMB: Int, qmpSocketPath: String, serialLogPath: String? = nil
    ) -> [String] {
        var args = baseArguments(name: "MacSandbox-Deploy", efiCodePath: efiCodePath, efiVarsPath: efiVarsPath,
                                 cpuCores: cpuCores, memoryMB: memoryMB, qmpSocketPath: qmpSocketPath, serialLogPath: serialLogPath)
        // Target NVMe (diskpart's disk 0)
        args += ["-drive", "if=none,id=sysdisk,format=qcow2,file=\(nvmePath)"]
        args += ["-device", "nvme,drive=sysdisk,serial=s0"]
        args += ["-device", "qemu-xhci,id=usb"]
        args += ["-device", "usb-kbd"]
        args += ["-device", "usb-tablet"]
        // GPT FAT32 WinPE boot disk (firmware auto-boot)
        args += ["-drive", "if=none,id=wpe,format=raw,file=\(bootDiskPath)"]
        args += ["-device", "usb-storage,drive=wpe,bootindex=0"]
        // Windows ISO (install.wim source)
        args += ["-drive", "if=none,id=iso,media=cdrom,readonly=on,file=\(windowsISOPath)"]
        args += ["-device", "usb-storage,drive=iso"]
        // virtio-win driver ISO (deploy.cmd injects it offline via dism /Add-Driver)
        if let virtioISOPath {
            args += ["-drive", "if=none,id=virtio,media=cdrom,readonly=on,file=\(virtioISOPath)"]
            args += ["-device", "usb-storage,drive=virtio"]
        }
        return args
    }

    /// Phase 2 (OOBE): boot from the deployed NVMe alone → specialize/oobe → shutdown after first logon.
    /// The firmware auto-boots \\EFI\\BOOT\\BOOTAA64.EFI on the NVMe ESP (=bootmgfw, copied during deployment).
    func buildOobeArguments(
        nvmePath: String, efiCodePath: String, efiVarsPath: String,
        cpuCores: Int, memoryMB: Int, qmpSocketPath: String, serialLogPath: String? = nil
    ) -> [String] {
        var args = baseArguments(name: "MacSandbox-OOBE", efiCodePath: efiCodePath, efiVarsPath: efiVarsPath,
                                 cpuCores: cpuCores, memoryMB: memoryMB, qmpSocketPath: qmpSocketPath, serialLogPath: serialLogPath)
        args += ["-drive", "if=none,id=sysdisk,format=qcow2,file=\(nvmePath)"]
        args += ["-device", "nvme,drive=sysdisk,serial=s0"]
        args += ["-device", "qemu-xhci,id=usb"]
        args += ["-device", "usb-kbd"]
        args += ["-device", "usb-tablet"]
        return args
    }

    /// Disposable sandbox run arguments. Boots the baseline COW overlay and translates the SandboxConfig into devices.
    func buildSandboxArguments(
        overlayPath: String, efiCodePath: String, efiVarsPath: String,
        config: SandboxConfig, configDiskPath: String?, rdpHostPort: Int,
        qmpSocketPath: String, serialLogPath: String? = nil
    ) -> [String] {
        var args: [String] = []
        args += ["-name", "MacSandbox-Run"]
        args += ["-machine", "virt,highmem=on,gic-version=3"]
        args += ["-accel", "hvf"]
        args += ["-cpu", "host"]
        // vCPU: at least 2 (Windows 11 ARM minimum + acceptable performance), and leave at least 2 cores for the host.
        let hostCores = ProcessInfo.processInfo.activeProcessorCount
        let cores = max(2, min(config.cpuCores, max(2, hostCores - 2)))
        args += ["-smp", "\(cores)"]
        // Memory: guarantee at least 4GB (Win11 ARM minimum) + leave at least 4GB for the host (prevents over-allocation).
        let hostMB = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024))
        let mem = min(max(4096, config.memoryMB), max(4096, hostMB - 4096))
        args += ["-m", "\(mem)"]

        args += ["-drive", "if=pflash,format=raw,readonly=on,file=\(efiCodePath)"]
        args += ["-drive", "if=pflash,format=raw,file=\(efiVarsPath)"]
        args += ["-boot", "menu=on,splash-time=0"]

        // System disk — COW overlay on top of the baseline (NVMe)
        args += ["-drive", "if=none,id=sysdisk,format=qcow2,file=\(overlayPath)"]
        args += ["-device", "nvme,drive=sysdisk,serial=s0"]

        // USB controller + input
        args += ["-device", "qemu-xhci,id=usb"]
        args += ["-device", "usb-kbd"]
        args += ["-device", "usb-tablet"]

        // Display — vGPU (virtio-gpu, driver needed) or ramfb (driverless). VNC framebuffer.
        args += ["-device", config.vGpuEnabled ? "virtio-gpu-pci" : "ramfb"]
        args += ["-display", "none"]
        args += ["-vnc", "127.0.0.1:1"]

        // Networking — user-mode NAT + host RDP port forwarding (127.0.0.1:rdpHostPort → guest 3389).
        // RDP hybrid: watch boot via the console (VNC), and interact via FreeRDP (folders/clipboard/mic/printer).
        // When networking is disabled, restrict=on blocks the internet but keeps RDP forwarding.
        // Guest-side operation requires the NetKVM (virtio-net) driver — injected into the baseline.
        var netdev = "user,id=net0,hostfwd=tcp:127.0.0.1:\(rdpHostPort)-:3389"
        if !config.networkingEnabled { netdev += ",restrict=on" }
        args += ["-netdev", netdev]
        args += ["-device", "virtio-net-pci,netdev=net0"]

        // Audio (microphone) — coreaudio backend + HDA (guest driver needed, best-effort)
        if config.audioInputEnabled {
            args += ["-audiodev", "coreaudio,id=snd0"]
            args += ["-device", "intel-hda"]
            args += ["-device", "hda-duplex,audiodev=snd0"]
        }

        // Config disk (FAT for passing LogonCommand/mapping info) — read by the baseline logon agent
        if let configDiskPath {
            args += ["-drive", "if=none,id=cfg,format=raw,file=\(configDiskPath)"]
            args += ["-device", "usb-storage,drive=cfg,removable=on"]
        }

        if let serialLogPath { args += ["-serial", "file:\(serialLogPath)"] }
        args += ["-rtc", "base=localtime,clock=host"]
        args += ["-qmp", "unix:\(qmpSocketPath),server,nowait"]
        return args
    }

    // MARK: - Run

    /// Runs QEMU and waits until the process exits.
    /// QEMU handles guest reboots in-place and **the process only exits on guest power-off (shutdown)**, so
    /// returning means the Windows unattended install completed and shut down.
    /// - Returns: the QEMU process exit code
    func runUntilExit(
        arguments: [String],
        qmpSocketPath: String,
        timeoutSeconds: TimeInterval,
        onOutput: @escaping (String) -> Void
    ) async throws -> Int32 {
        guard let qemu = SandboxPaths.qemuSystemBinary() else { throw RuntimeError.qemuNotFound }

        let proc = Process()
        proc.executableURL = qemu
        proc.arguments = arguments
        proc.environment = SandboxPaths.qemuEnvironment()

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty, let s = String(data: d, encoding: .utf8) { onOutput(s) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty, let s = String(data: d, encoding: .utf8) { onOutput("[qemu] \(s)") }
        }

        storeProcess(proc)

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
            let resumed = OneShotFlag()

            let timeout = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let p = self.currentProcess()
                if p?.isRunning ?? false {
                    onOutput("Install timeout (\(Int(timeoutSeconds))s) exceeded — forcing VM off\n")
                    p?.terminate()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timeout)

            proc.terminationHandler = { [weak self] finished in
                timeout.cancel()
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                try? FileManager.default.removeItem(atPath: qmpSocketPath)
                self?.currentWatchdog()?.terminate()  // QEMU exited normally → clean up the watchdog too
                self?.storeWatchdog(nil)
                self?.storeProcess(nil)
                if resumed.set() { cont.resume(returning: finished.terminationStatus) }
            }

            do {
                try proc.run()
                onOutput("QEMU process started (PID \(proc.processIdentifier))\n")
                spawnWatchdog(qemuPID: proc.processIdentifier)  // prevents VM orphans if the app is force-quit
            } catch {
                timeout.cancel()
                if resumed.set() { cont.resume(throwing: error) }
            }
        }
    }

    /// Force stop (user cancellation). SIGTERM to QEMU → VM shuts down immediately.
    func forceStop() {
        currentProcess()?.terminate()
    }
}

/// Thread-safe flag that guarantees a one-time continuation resume
final class OneShotFlag: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    /// true only on the first call, false thereafter
    func set() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
