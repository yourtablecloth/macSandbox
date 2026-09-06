# VM state probe evidence

Observed on September 6, 2026. This record summarizes tool output from the local feasibility investigation; it is not an end-to-end Windows test report. Design and follow-up scope: [Warm-start feasibility and WSB compatibility](warm-start-feasibility.md).

## Environment and scope

- macOS 26.6.2, build 25G83, Apple Silicon host
- macSandbox source commit `43420147e713e7f68cef28a998d8ea4eb686d911`
- Bundled QEMU emulator 10.2.1 with HVF
- Machine `virt,highmem=on,gic-version=3`; CPU `host`; 2 vCPUs
- QMP over standard input/output; separate source and destination QEMU processes
- Temporary blank disk images and temporary copied UEFI variables
- No Windows system disk, guest credentials, user folders, RDP connection, or actual microphone capture

The app's runtime remained unchanged during this assessment. Probe processes terminated after testing and temporary VM disks/state files were removed.

## Paused minimal VM

The first probe used 128 MiB RAM, `-S`, `-nodefaults`, and no firmware or guest workload. After QMP capability negotiation it queried status, migrated state to a temporary file, waited for migration completion, terminated the source, and started a new process with the same configuration and `-incoming file:<state>`. It waited until the destination left `inmigrate`.

The final repeated observation reported these values:

```text
Initial status: prelaunch
File migration: completed
State file size: 652058 bytes
Destination status after incoming migration: prelaunch
Destination running: false
```

This proves availability of the basic serialization path in the installed HVF build. It does not test execution continuity of a running OS. An earlier intermediate `inmigrate` response was not counted as completed restoration.

## Firmware-stage device configuration

The second probe used 512 MiB RAM, the bundled AArch64 code firmware, a writable copy of the ARM UEFI variables, a blank 64 MiB qcow2 system disk, and a blank 8 MiB RAW configuration medium. The device list included qemu-xhci, USB keyboard/tablet, ramfb, virtio-net, and HDA duplex audio. The source executed firmware for approximately two seconds and was then stopped before saving.

The device classes followed the runtime, with these deliberate differences: no Windows image, no VNC server, no RDP port forwarding, no CoreAudio access (`none` audio backend), and no filesystem or logon scripts on the configuration medium. The user network backend used `restrict=on`. The probe did not switch networking policy during restore or test virtio-gpu.

With `nvme,drive=sysdisk,serial=s0`, QMP returned the following errors:

```text
human-monitor-command: savevm probe
Error: State blocked by non-migratable device '0000:00:01.0/nvme'

migrate: file:<temporary state file>
GenericError: State blocked by non-migratable device '0000:00:01.0/nvme'
```

The matching [QEMU 10.2.1 NVMe implementation](https://github.com/qemu/qemu/blob/v10.2.1/hw/nvme/ctrl.c#L9505) declares `.unmigratable = 1`. This is a controller-state limitation rather than a limitation of the qcow2 format.

## Virtio-blk substitution

A fresh probe replaced only the system-disk device specification with `virtio-blk-pci,drive=sysdisk,serial=s0`. Internal `savevm` then reached a separate storage limitation. External file migration succeeded using the matching temporary disk and firmware-variable files in the destination.

The observed responses were:

```text
human-monitor-command: savevm probe
Error: Device 'pflash1' is writable but does not support snapshots

migrate: file:<temporary state file>
Migration status: completed
State file size: 68774716 bytes
Destination status after incoming migration: paused
cont: success
Destination status after approximately one second: running
```

The destination loaded the same paused-generation disk files; the experiment did not test cloning the backing chain or separate UEFI copies after capture. QEMU reporting `running` is a process/VM-state observation, not proof of a usable Windows desktop or correct guest I/O. The approximately 68.8 MB state file is specific to this small firmware-stage probe and is not an estimate for Windows checkpoint size. State-save timings are not startup benchmarks.

## Follow-up reproduction requirements

Use isolated temporary images, the exact QEMU/firmware versions below, and the configurations above. Keep source and destination device definitions identical within each experiment. Check asynchronous migration completion before terminating the source, then check completion of incoming migration before reporting a restored state. Stop both processes and clean temporary files even when the expected NVMe rejection occurs.

The next reproduction should retain raw QMP transcripts and validate observable Windows behavior, including disk I/O and a usable RDP desktop. The original disposable probes establish feasibility boundaries only. See [QEMU migration requirements](https://www.qemu.org/docs/master/devel/migration/main.html) and the [design acceptance criteria](warm-start-feasibility.md#follow-up-work-and-acceptance-criteria).

## Artifact identities

The following SHA-256 values identify the local binaries/firmware and the upstream source file inspected during this investigation. They are provenance markers, not a promise that another installation uses identical artifacts.

| Artifact | SHA-256 |
| --- | --- |
| `vendor/qemu/bin/qemu-system-aarch64` | `b3b62bd9a284417897166009de545e7f7964ab240c51b62297f8dcce31a4bd0e` |
| `vendor/qemu/share/qemu/edk2-aarch64-code.fd` | `bdf9e7b77f936c379d24c5841becb8e282a9d10a82e4a5454d0c04803057058e` |
| `vendor/qemu/share/qemu/edk2-arm-vars.fd` | `b3b855c5a80310168051164986855692d1bdb06e67619856177965cd87c6774f` |
| Upstream QEMU tag `v10.2.1`, `hw/nvme/ctrl.c` | `1567b3fe8f8cfd167c9faf389195d68314f7af7c9e3e8df6bc318bb3e4fe77cc` |
