---
layout: default
title: Archived macOS Guest Sandbox Experiment
permalink: /archive/macos-guest-sandbox/
---

# Archived macOS guest sandbox experiment

> Development stopped before release. This archive records the evidence and reusable findings from `feat/macos-guest-sandbox`. The production scope remains a Windows 11 ARM64 sandbox. Archive review date: 2026-09-04.

## Scope and provenance

The experiment began from commit `c5fca26` on 2026-06-29 and ended at commit `37d50cb12045c4f54c2b4964b77a89cd654dfe3f`. It added a standalone Virtualization.framework proof of concept, a macOS guest backend, per-guest baseline storage, separate Windows and macOS windows, and a signed development launcher.

The feature branch contained these commits:

- `d00a0960bf9e923731c9afc6c8f1a70c579715a6`: Virtualization.framework feasibility PoC
- `e2a8939fb013e5952ab8daf403694e66be17c3cd`: pluggable guest backend seam
- `7db95caca0d826bb57719944a2d4354e46f1d21d`: macOS guest backend and baseline producer
- `3362be954546b81826320a11e3e83912e0851464`: independent Windows and macOS windows
- `37d50cb12045c4f54c2b4964b77a89cd654dfe3f`: signed development launcher

The repository history does not state the product reason for stopping development. The branch was not merged. This page preserves findings instead of the implementation.

## Verification boundary

The archive review used an Apple M2 MacBook Air running macOS 26.6.2, Xcode 26.6, macOS SDK 26.5, and Swift 6.3.3.

| Item | Status | Evidence from the archive review |
|---|---|---|
| Main application source | Verified to compile | `swift build` completed on the feature branch. The linker reported that local FreeRDP libraries targeted macOS 26 while the package targeted macOS 14. |
| Standalone PoC source | Verified to compile | `swift build` completed in `poc/vz-macos-poc`. |
| Virtualization entitlement | Verified on the PoC executable | The ad-hoc signed executable contained `com.apple.security.virtualization`. |
| Restore-image discovery | Verified | The signed `images` command returned macOS 26.6.2 build 25G83 as supported by the host, with a minimum of 2 vCPUs and 4 GB RAM. These values describe the 2026-09-04 check and will change over time. |
| Restore-image download | Partial evidence found | The application cache contained a 19,769,808,058-byte macOS 26.5.1 IPSW dated 2026-06-28. No retained checksum established file integrity. |
| macOS installation and first boot | Not verified | No macOS baseline directory or PoC VM bundle remained on the review machine. |
| Guest display, input, audio, and VirtioFS | Not verified end to end | The code compiled and called `validate()` on the VM configuration at runtime, but the archive review did not execute that path. No retained artifact or test result demonstrated guest behavior. |
| APFS clone boot and disposal | Not verified end to end | The branch implemented the flow but retained no golden image or cloned session for inspection. |
| Automatic login and Korean input setup | Not verified | The guest-side provisioning script existed only as implementation code. |
| Concurrent Windows and macOS sessions | Not verified | The UI and lifecycle code allowed one window per guest type, but the review found no runtime test evidence. |

## Virtualization.framework installation path

Apple's [`VZMacOSRestoreImage.latestSupported`](https://developer.apple.com/documentation/virtualization/vzmacosrestoreimage/latestsupported) returns a restore image supported by the current host. The image URL points to a network resource, so the host downloads the IPSW before passing its local URL to [`VZMacOSInstaller`](https://developer.apple.com/documentation/virtualization/vzmacosinstaller). The experiment followed this sequence:

```text
latestSupported or selected IPSW
    -> completed-download cache
    -> sparse raw disk and platform identity
    -> VZMacOSInstaller
    -> one-time first-boot setup
    -> golden baseline
    -> per-session APFS clone
```

The branch also parsed Apple's public `mesu.apple.com` catalog to offer older image choices. That catalog format was undocumented in the implementation and the parser treated failure as non-fatal. A future implementation can use it for optional discovery, but should keep `latestSupported` and locally supplied IPSW files as the supported paths.

The persisted VM bundle required more than its disk image:

- Sparse raw disk containing macOS and guest state
- `VZMacAuxiliaryStorage` containing mutable boot-loader state
- Serialized `VZMacHardwareModel`
- Serialized `VZMacMachineIdentifier`
- CPU, memory, and display settings

Deleting or cloning only the disk does not preserve a complete macOS VM identity.

## Signing and development execution

The executable that creates the `VZVirtualMachine` needs the [`com.apple.security.virtualization`](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.virtualization) entitlement. The experiment confirmed that signing the exact PoC executable and then invoking that file allowed restore-image discovery.

The useful development pattern was:

```sh
swift build
BIN="$(swift build --show-bin-path)/MacSandbox"
codesign --force --sign - --entitlements scripts/app.entitlements "$BIN"
exec "$BIN"
```

`swift run` may rebuild or invoke an executable that does not carry the required entitlement. A development launcher should build, sign, inspect if necessary, and execute the same binary path. Packaged application signing needs the entitlement on the application process because the macOS backend runs in process. The Windows backend keeps its Hypervisor.framework entitlement on the separate QEMU executable.

## Disposable storage model

The experiment used `cp -c` to request an APFS copy-on-write clone of the golden disk. It copied auxiliary storage for each session because the guest mutates that file while booting. It preserved the hardware model and machine identifier to stay on the known bootable path.

This design left two unresolved conditions:

- A source and destination on storage that cannot perform an APFS clone fell back to a full disk copy. Disposal semantics remained possible, but startup time and free-space requirements changed substantially.
- Preserving one machine identifier avoided an untested identity change. Two clones with the same identifier were not intended to run concurrently. The branch exposed a PoC option for a new identifier, but no retained test showed whether an installed guest continued to boot after the change.

A revived implementation should treat clone capability, available capacity, and machine identity as explicit preflight checks instead of hidden fallbacks.

## Guest integration and provisioning

The proposed runtime embedded a [`VZVirtualMachineView`](https://developer.apple.com/documentation/virtualization) instead of using RDP. It configured a Mac keyboard, a USB screen-coordinate pointing device, NAT networking, host audio streams, and a fixed 1920 by 1200 display at 110 pixels per inch.

The fixed one-timescale framebuffer was a performance hypothesis. The branch expected fewer software-composited pixels to reduce frame drops and accepted lower sharpness. No retained measurement compared frame time, input latency, CPU load, or power use across display settings.

For host folders and the first-boot script, the backend used a VirtioFS multiple-directory share with [`macOSGuestAutomountTag`](https://developer.apple.com/documentation/virtualization/vzvirtiofilesystemdeviceconfiguration/macosguestautomounttag). Apple documents automatic mounting under `/Volumes/My Shared Files` for supported macOS guests. The experiment did not retain an end-to-end mount result.

For the available macOS 26 host and SDK, the branch designed the post-install flow around a manual Setup Assistant pass. The proposed bake flow required the user to create an administrator account once and run a guest-side script. The script attempted to enable automatic login, add ABC and Korean 2-Set input sources, skip several per-user setup panes, and disable the wake password. The archive evidence did not show that this flow completed successfully.

The branch included a reference-only macOS 27 provisioning snippet. Xcode 26.6 with macOS SDK 26.5 did not expose the referenced API during the archive review, so the snippet never compiled as part of either target. It remains unverified research and should not guide a production implementation without checking the shipping SDK and Apple documentation.

Automatic login also changes the security model. The golden image and every clone can enter the account without an interactive password. A future product design needs an explicit threat model, credential lifecycle, and user-facing disclosure before adopting that behavior.

## Reusable architecture findings

The branch separated orchestration from guest-specific mechanisms with a backend protocol and a host callback protocol. Windows retained QEMU, qcow2, configuration-disk, and embedded-RDP behavior. macOS supplied Virtualization.framework, APFS cloning, VirtioFS, and a native VM view. A guest-kind discriminator selected the backend and namespaced storage.

This separation exposed useful boundaries for another multi-guest experiment:

- Baseline creation and metadata
- Per-session writable storage
- Configuration delivery
- Guest presentation
- Stop, cleanup, and window lifecycle

The experiment also revealed integration gaps:

- The new `baseline/windows` path had no migration from the released `baseline` layout. Existing Windows baselines would appear missing after an upgrade even though the metadata decoder accepted older fields.
- Any clean first-boot shutdown marked the macOS baseline as provisioned. Setup Assistant or the guest script could remain incomplete. Finalization needs an explicit postcondition or an unambiguous user action.
- The UI added English-only macOS labels and messages without updating the existing localization resources.
- Windows `.wsb` options did not map fully to macOS. The branch reused memory, CPU, networking, microphone, and mapped-folder fields while leaving Windows-specific settings without equivalent behavior.
- Stale-overlay cleanup assumed one application instance. A second process could mistake another live session for stale state.
- The branch had no automated tests for metadata migration, backend selection, baseline finalization, clone cleanup, or multi-window shutdown.

## Conditions for revisiting the feature

A future experiment can start from the archived findings and use these acceptance gates:

1. Define the macOS guest product scope, license assumptions, supported host and guest versions, and automatic-login security boundary.
2. Add a migration that preserves released Windows baselines before changing storage paths.
3. Complete an installation, first boot, provisioning, shutdown, clone, second boot, and disposal cycle on a clean test account.
4. Test preserved and regenerated machine identifiers, including the intended concurrency limit.
5. Measure display frame time, input latency, CPU use, memory use, and storage growth before selecting framebuffer defaults.
6. Verify every guest integration path, including read-only folders, duplicate share names, audio input permission, networking disabled, and unclean shutdown.
7. Replace implicit provisioning completion with an observable postcondition and recovery flow.
8. Localize the UI and add regression tests for Windows behavior before merging a backend refactor.
