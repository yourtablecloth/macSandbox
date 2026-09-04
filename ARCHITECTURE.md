# macSandbox for Windows Architecture

An app that creates disposable Windows 11 ARM64 sandboxes on macOS (Apple Silicon)
(brand: **macSandbox for Windows**; the internal module/executable name remains `MacSandbox`).
**The runtime is QEMU + Hypervisor.framework (HVF)**, and the baseline image is
built fully automatically and deterministically via a **WinPE-based DISM offline deployment**.

## Why QEMU (and not AVF)

The Apple Virtualization Framework (AVF) supports only macOS/Linux guests, and Windows ARM
guests have no inbox virtio-gpu/net drivers, so **display and networking do not work**.
On Apple Silicon, the only ways to actually run Windows are QEMU (+HVF), Parallels, or VMware,
and QEMU is the open-source option that fills this role. (See the git history for the earlier AVF attempt.)

- The QEMU binary must be signed with the `com.apple.security.hypervisor` entitlement for `-accel hvf` to work.
  `scripts/build.sh` signs `vendor/qemu/bin/qemu-system-aarch64` idempotently.
- The app itself needs no special entitlement (it merely runs QEMU as a child process).

## Baseline build — WinPE DISM deployment (fully deterministic)

The setup.exe + autounattend approach required key-press heuristics because of the
"Press any key to boot from CD" (El Torito) prompt and interactive screens. We replaced it
with a **DISM offline deployment** that **eliminates the El Torito prompt, key presses, and the setup.exe GUI entirely**.

### Deployment media ([WinPEDeployMediaBuilder](src/MacSandbox/Core/WinPEDeployMediaBuilder.swift))

Builds a **GPT-partitioned FAT32 boot disk** from the user's ISO:

- `\EFI\BOOT\BOOTAA64.EFI` ← `bootmgfw.efi` (extracted from install.wim with wimlib)
- `\EFI\Microsoft\Boot\BCD` ← the ISO's BCD (as-is — the ramdisk source uses a `[boot]` relative reference, so no patching is needed)
- `\Boot\boot.sdi`, `\sources\boot.wim` (edited)

> **Key point**: bootmgr maps the `[boot]` device to a real partition, so it must be a **GPT partition**.
> A superfloppy (no partition table) fails with "No mapping". → The firmware boots WinPE directly with no prompt.

`boot.wim` image 2 (Setup) launches setup.exe via `winpeshl.ini`, so wimlib is used to inject
the following into image 2, running the deployment script instead of setup.exe:

- `winpeshl.ini` → `cmd /c X:\Windows\System32\deploy.cmd`
- `deploy.cmd`: `diskpart` (NVMe GPT: ESP/MSR/NTFS) → locate install.wim →
  `dism /Apply-Image /Name:"<edition>" /ApplyDir:W:\` → **offline injection of virtio-win drivers**
  (`dism /Image:W:\ /Add-Driver /Recurse`) → copy Panther unattend →
  `bcdboot W:\Windows /s S: /f UEFI` → copy `bootmgfw.efi` to the ESP's `\EFI\BOOT\BOOTAA64.EFI` → `wpeutil shutdown`
- `msbx-dp.txt` (diskpart script), `unattend.xml` (Panther)

### virtio-win driver injection ([GuestDrivers](src/MacSandbox/Core/GuestDrivers.swift))

During the deployment phase, `virtio-win.iso` (auto-downloaded from fedorapeople if absent, ~750 MB cached) is
attached as an additional USB cdrom. `deploy.cmd` locates the ISO drive via the `\NetKVM` marker and injects
the drivers into the offline image (W:\) with `/Add-Driver /Recurse`. The crucial one is **NetKVM (virtio-net)**,
which the ARM64 inbox lacks — it is what makes RDP work at runtime. (Other ARM64 drivers such as viostor, viogpudo, and vioinput are injected as well.)

### Two-phase orchestration ([BaselineBuilder](src/MacSandbox/Core/BaselineBuilder.swift))

1. **Phase 1 (deployment)**: Boot from the GPT FAT boot disk + Windows ISO + an empty NVMe (`nvme`).
   WinPE comes up with zero prompts or key presses and runs `deploy.cmd` → applies `dism` → `bcdboot` → shutdown (QEMU exit).
2. **Phase 2 (OOBE)**: Boot from the NVMe alone (the firmware auto-boots the ESP's `\EFI\BOOT\BOOTAA64.EFI`).
   `\Windows\Panther\unattend.xml` (oobeSystem-only) automates the first boot:
   bootstrap admin auto-logon → FirstLogonCommands enable the built-in **WDAGUtilityAccount**, set its RDP credential,
   disable password expiration for that account, and **enable the RDP server** (`fDenyTSConnections=0`, NLA off, `LimitBlankPasswordUse=0`,
   allow the firewall remote-desktop group) + configure the logon agent (Run key) → `shutdown` → baseline complete (status=ready).

   The final shutdown is gated on successful application of `PasswordNeverExpires`; if that account-specific setting fails,
   provisioning remains visibly failed instead of saving a baseline with an expiring credential.

> The Panther unattend uses only the oobeSystem pass. Adding a `Microsoft-Windows-Deployment`
> RunSynchronous to specialize causes some 25H2 builds to reject it as "the answer file is invalid".

## Sandbox runtime ([SandboxRunner](src/MacSandbox/Core/SandboxRunner.swift) / [SandboxConfig](src/MacSandbox/Core/SandboxConfig.swift))

Brings up a disposable environment on top of the baseline (the counterpart to Windows Sandbox's `.wsb`):

1. A **COW overlay** (`qemu-img create -b`) on top of the baseline qcow2 + a fresh copy of the UEFI variables.
2. Translates `SandboxConfig` (memory/CPU/networking/vGPU/shared folder/clipboard/microphone/printer/logon command)
   into QEMU arguments, RDP flags, and a config disk. **The defaults match the Windows Sandbox standard.**
3. QEMU boots → the console has no session (the bootstrap account is disabled), and WDAGUtilityAccount logs on via RDP.
   On exit (or when the FreeRDP window closes), the overlay/variables/config disk are discarded if disposable.

The logon command is passed via `macsandbox-logon.cmd` on a small FAT config disk, and the baseline's
logon agent (HKLM Run key) runs it.

## RDP hybrid (interaction + redirection)

The same approach Windows Sandbox itself uses internally with RDP. Two paths run in parallel:

- **Boot monitoring**: VNC framebuffer → QMP `screendump` polling → in-app console ([VMConsole](src/MacSandbox/Core/VMConsole.swift)).
  Screen clicks (absolute coordinates) and the keyboard (`QKeyMap`) allow intervention even during boot.
- **User interaction**: Once the guest is up, connect via a **FreeRDP** (`sdl-freerdp`) window ([RDPSession](src/MacSandbox/Core/RDPSession.swift)).
  Provides folder sharing (`/drive`), clipboard (`+clipboard`), microphone/audio (`/microphone` `/sound`), and printer (`/printer`)
  redirection. (Webcam is unsupported because this FreeRDP build has no RDPECAM channel.)

QEMU exposes RDP on the host via user-mode NAT + `hostfwd=tcp:127.0.0.1:<port>-:3389`, and
FreeRDP logs on with `WDAGUtilityAccount` / a blank password / `/sec:tls` (the server rejects plain RDP as SSL_REQUIRED).
When networking is disabled, `restrict=on` blocks the internet while keeping RDP forwarding.

> A user-mode hostfwd accepts host-side connects even before the guest RDP is ready, so port polling
> cannot determine readiness. Instead, FreeRDP is launched in a **retry loop** (a quick failure = not ready → retry;
> a long-lived process that exits = session ended → QEMU shutdown), naturally tracking when the guest RDP comes up.

> **Avoiding the console↔RDP single-session conflict**: The Win11 client SKU allows one interactive session, so the
> console auto-logon conflicts with the RDP (WDAGUtilityAccount) session. WDAGUtilityAccount cannot be a console
> auto-logon target, and `AutoAdminLogon=0` alone cannot prevent the first OOBE auto-logon, so the baseline's
> FirstLogonCommands **disable the bootstrap account (sandboxsetup)** to prevent a console session from being created.

## UI flow + configuration input

The GUI is a single-window router ([ContentView](src/MacSandbox/Views/ContentView.swift)):

- **No baseline** → [BuildView](src/MacSandbox/Views/ContentView.swift) (pick only the ISO + edition for a 1-round build). Switches automatically when complete.
- **Baseline present** → start the sandbox immediately ([SandboxView](src/MacSandbox/Views/SandboxView.swift)). No start button.
  - **Booting**: A "sandbox booting" notice + only the current message. The console/log expand via "Show more".
  - **RDP established** (`SandboxRunner.rdpConnected`, detected by FreeRDP dynamic channel load) → `NSApp.hide` hides the app window, **leaving only the FreeRDP window**. Shown again when the sandbox exits.
  - **After exit**: restart / load a `.wsb`.

Detailed options are specified not via GUI toggles but via the **`.wsb` file / command-line switches** ([WSBConfig](src/MacSandbox/Core/WSBConfig.swift) / AppLaunch). The defaults follow the Windows Sandbox standard (networking, clipboard, and audio on; webcam and printer off; ~4 GB).

## Components

| File | Role |
| ---- | ---- |
| `SandboxPaths` | app support paths; resolves vendor/qemu, wimlib, and firmware |
| `DiskService` | qcow2 creation; COW overlay (for the sandbox runtime) |
| `WinPEDeployMediaBuilder` | creates the GPT FAT32 deployment boot disk |
| `QEMURuntime` | builds deployment/OOBE/sandbox arguments (including the RDP hostfwd), runs the process |
| `UnattendBuilder` | generates the Panther unattend (oobeSystem, including RDP enablement) |
| `BaselineBuilder` | orchestrates the two-phase build |
| `GuestDrivers` | obtains the virtio-win ISO (auto-download/cache) |
| `SandboxRunner` / `SandboxConfig` | runs the disposable sandbox (COW overlay + RDP hybrid) |
| `RDPSession` | builds FreeRDP arguments + runs with retry |
| `WSBConfig` / `AppLaunch` | `.wsb` (XML) parser + command-line switches → SandboxConfig |
| `ContentView` / `BuildView` / `SandboxView` | router (build↔start screens) + each screen |
| `QMPInput` / `VMConsole` | QMP input injection + screen polling |

## Dependencies

- `vendor/qemu` (qemu-system-aarch64, qemu-img, edk2 firmware) — bundled by `scripts/bundle_qemu.py`
- `wimlib` (`brew install wimlib`) — boot.wim editing + bootmgfw extraction
- `freerdp` (`brew install freerdp` → `sdl-freerdp`) — sandbox interaction + redirection
- `virtio-win.iso` — guest virtio drivers (auto-download, cached in app support)
- `hdiutil` / `diskutil` (built into macOS) — ISO mounting, GPT FAT32 disk creation

## CLI

- `MacSandbox --headless-build [ISO_PATH]` — build the baseline without the GUI, then exit (for verification/automation).
- `MacSandbox <config.wsb>` / `MacSandbox --wsb <config.wsb>` — start with a `.wsb` configuration.
- `MacSandbox --run [switches...]` — configure via switches, then start. Switches:
  `--memory <MB>` `--cpus <N>` `--networking on|off` `--vgpu on|off`
  `--clipboard on|off` `--audio on|off` `--printer on|off`
  `--folder <path>[:ro]` (repeatable) `--logon "<command>"`
- When no switches or `.wsb` are specified, the GUI shows the start screen with the Windows Sandbox standard defaults.
  If `.wsb`/`--folder`/`--run` is present, it starts automatically once the baseline is ready.

A `.wsb` is XML compatible with Windows Sandbox (e.g., `examples/sample.wsb`). HostFolder is resolved as a macOS path.
