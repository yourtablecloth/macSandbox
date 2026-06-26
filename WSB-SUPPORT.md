<!--
SPDX-License-Identifier: AGPL-3.0-or-later
Copyright (C) 2026 Nam Jung Hyun (rkttu)
-->

# Windows Sandbox `.wsb` Configuration Support Status

MacSandbox borrows the `.wsb` (XML) configuration file schema from Microsoft's **Windows Sandbox**.
The execution model differs, however — Windows Sandbox is a Hyper-V container, whereas MacSandbox is a
**QEMU+HVF virtual machine + FreeRDP (embedded) hybrid**. As a result, some fields have a different meaning
or are unimplemented. This document lays out **what each `.wsb` field actually does (and does not do)**.

- Parsing/mapping: [`WSBConfig.swift`](src/MacSandbox/Core/WSBConfig.swift) → [`SandboxConfig`](src/MacSandbox/Core/SandboxConfig.swift)
- Applied: **on every run (at runtime)**. Devices/network/display/memory are handled by [`QEMURuntime`](src/MacSandbox/Core/QEMURuntime.swift),
  and redirection (clipboard/audio) by the embedded engine [`rdp_engine.c`](src/CFreeRDP/rdp_engine.c).
- Usage: specify via a CLI switch or a `.wsb` path instead of double-clicking/associating the file.

## Support matrix

| `.wsb` field | Official meaning | MacSandbox | Notes |
|---|---|:---:|---|
| `MemoryInMB` | Memory (MB), auto-corrected to a minimum of 2048 | ✅ Supported | Host-aware default + `[4GB, host−4GB]` clamp (Win11 ARM minimum 4GB) |
| `Networking` | Network on/off | ✅ Supported | Enable = virtio-net NAT (user); Disable = `restrict=on` (external access blocked). The guest NetKVM driver is injected into the baseline |
| `LogonCommand`/`Command` | Run a command after logon | ✅ Supported | Delivered via a FAT config disk + the baseline logon agent (`macsandbox-logon.cmd`) |
| `ClipboardRedirection` | Clipboard sharing | ✅ Supported | Text and files, both directions. On `Disable`, cliprdr is not loaded (verified) |
| `AudioInput` | Microphone sharing | ✅ Supported | Gates the microphone (audin). Speaker playback (rdpsnd) has no `.wsb` toggle, so it is always on (same as Windows Sandbox) |
| `PrinterRedirection` | Printer sharing | ✅ Supported | `RedirectPrinters` + rdpdr + CUPS → registers host printers in the guest (PRN1 verified). On `Disable`, not registered |
| `vGPU` | GPU acceleration (WARP when Disable) | ⚠️ Partial / different meaning | Only switches the **QEMU console (VNC boot monitor) display device** (ramfb↔virtio-gpu-pci). No effect on the user's display (RDP) and no WDDM acceleration (DWM composites in software) |
| `MappedFolders` | Host folder sharing | ✅ Supported | Exposed via RDP rdpdr drive as `\\tsclient\<leaf>` + auto-mounted (linked) in the guest. The `SandboxFolder` path if specified, otherwise **WDAGUtilityAccount desktop\leaf**. `ReadOnly` not enforced, up to 16 |
| `VideoInput` | Webcam sharing | ❌ Unsupported | The RDPECAM channel is disabled in the bundled libfreerdp + no macOS camera backend (see separate analysis) |
| `ProtectedClient` | RDP AppContainer hardening | ❌ Unsupported | Not parsed. A Hyper-V AppContainer concept, so it cannot be mapped onto QEMU+RDP |

> Extension (non-standard): `CpuCores` — a MacSandbox-only field that does not exist in the real `.wsb`. ✅ Supported, `[2, host−2]` clamp.

## Per-field detail

### ✅ Fully supported

- **MemoryInMB** — Accepts the value but clamps it to `[4GB, host−4GB]` (preventing over-allocation + guaranteeing the Win11 ARM minimum of 4GB).
  When unspecified, about half the host RAM (16GB host → 8GB).
- **Networking** — `Enable` (default): QEMU user-mode NAT (including RDP forwarding via `hostfwd`). `Disable`: `restrict=on`
  blocks external access (RDP loopback is retained). The NetKVM (virtio-net) driver is required for it to work in the guest — it is injected into the baseline.
- **LogonCommand** — Writes the `<Command>` string to `macsandbox-logon.cmd` on the FAT config disk, and
  at logon the baseline scans removable drives and runs it (the unattend Run-key agent). For multi-step commands,
  writing a script file is recommended (same as the official guidance).
- **ClipboardRedirection** — Two-way text and file clipboard. The value gates the engine's `RedirectClipboard`, and
  on `Disable` the cliprdr channel is not loaded (verified).
- **AudioInput** — Gates microphone input (audin, macOS AVFAudio). On `Disable`, audin is not loaded.
  Speaker playback (rdpsnd, CoreAudio) has no `.wsb` toggle, so it is always on (same as Windows Sandbox).
  A macOS permission prompt appears on first microphone use.
- **PrinterRedirection** — Registers host printers in the guest via the engine's `RedirectPrinters` + rdpdr + the libfreerdp CUPS backend
  (verified: `registered [printer] device PRN1`). On `Disable` (default), not registered.
- **MappedFolders** — An **RDP-level implementation** (not QEMU 9p/virtfs): the FreeRDP rdpdr drive device
  (`freerdp_client_add_device_channel`) exposes **only the specified folders** in the guest as `\\tsclient\<leaf>` (drive name =
  folder leaf; numbered on collision). No guest driver needed; read+write verified end-to-end. Up to 16.
  - **Guest mount location**: The logon agent creates a link at `\\tsclient\<leaf>`. The `SandboxFolder` absolute path
    if specified, otherwise the **WDAGUtilityAccount desktop\leaf** (same as Windows Sandbox).
    With developer mode (enabled in the baseline), an `mklink /D` symbolic link (folder-like); on a non-enabled baseline it
    falls back to a `.lnk` shortcut (verified). The symlink requires developer mode because there is no unelevated SeCreateSymbolicLinkPrivilege.
  - **Limitations**: `ReadOnly` is not enforced because the FreeRDP drive does not support it (shared read/write — impossible without a patched build).
    `RedirectDrives` (hot-plug whole-volume sharing) is not used for security reasons.

### ⚠️ Partial support (known limitation)

- **vGPU** — The original `.wsb` meaning is guest GPU acceleration (WARP software rendering when unused). In MacSandbox the
  user's display is RDP (rdpgfx), so this flag only changes the display device of the **QEMU console (boot monitor)**
  (`ramfb`↔`virtio-gpu-pci`). The desktop has no GPU acceleration either way and DWM composites in software.
  → *No effect on the user's perceived GPU acceleration.*

### ❌ Unsupported (known limitation)

- **VideoInput (webcam)** — The bundled libfreerdp disables the RDPECAM (`[MS-RDPECAM]`) channel in its build
  (`This build does not support [MS-RDPECAM]…`). On top of that, the upstream FreeRDP camera backend is Linux `v4l` only, so
  there is no macOS (AVFoundation) backend. Supporting it would require rebuilding libfreerdp + writing a new macOS camera backend.
- **ProtectedClient** — Not parsed (the element is ignored). Windows Sandbox's AppContainer isolation is a Hyper-V-only concept, so
  it has no counterpart in the QEMU+RDP model.

## MacSandbox-specific behavior

- **Defaults** match the Windows Sandbox standard: networking, clipboard, and audio **on**; webcam and printer **off**.
- **Value parsing** (3-state): `Enable|true|1|on|yes` → on, `Disable|false|0|off|no` → off,
  `Default`/unrecognized/unspecified → keep the default. For `ReadOnly`, only `true` is read-only.
- **Memory/CPU clamps** always take precedence over the values specified in `.wsb` (host protection).
- **Credentials**: The user account/password are not set via `.wsb` — it auto-logs on with internal fixed credentials.
- **Window size/resolution**: Cannot be set via `.wsb` (same as official). MacSandbox resizes dynamically to fit the window.

## Example `.wsb`

```xml
<Configuration>
  <MemoryInMB>8192</MemoryInMB>      <!-- Clamped to [4GB, host-4GB] -->
  <Networking>Enable</Networking>    <!-- Blocks external access when Disable -->
  <LogonCommand>
    <Command>cmd /c echo hello &gt; C:\Users\Public\hello.txt</Command>
  </LogonCommand>
  <ClipboardRedirection>Enable</ClipboardRedirection>   <!-- ✅ Blocks the clipboard when Disable -->
  <AudioInput>Enable</AudioInput>                        <!-- ✅ Gates the microphone (speaker always on) -->
  <PrinterRedirection>Enable</PrinterRedirection>        <!-- ✅ Host printer → guest -->
  <MappedFolders>                                        <!-- ✅ Auto-mounts to desktop\Shared when SandboxFolder is omitted -->
    <MappedFolder><HostFolder>~/Shared</HostFolder><ReadOnly>false</ReadOnly></MappedFolder>
    <!-- Mounts at the given path when SandboxFolder is specified: -->
    <MappedFolder><HostFolder>~/Docs</HostFolder><SandboxFolder>C:\Users\WDAGUtilityAccount\Docs</SandboxFolder></MappedFolder>
  </MappedFolders>
  <!-- The following are parsed but unsupported: -->
  <VideoInput>Disable</VideoInput>                       <!-- ❌ Unsupported (no RDPECAM) -->
  <ProtectedClient>Disable</ProtectedClient>             <!-- ❌ Not parsed -->
</Configuration>
```

## Sources

- Official schema: [Use and configure Windows Sandbox — Microsoft Learn](https://learn.microsoft.com/en-us/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-configure-using-wsb-file) (as of 2026-03-29)
- Implementation: the source files linked in the body above.
