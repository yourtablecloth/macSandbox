# macSandbox for Windows

[![Release](https://img.shields.io/github/v/release/yourtablecloth/macSandbox?sort=semver&label=release)](https://github.com/yourtablecloth/macSandbox/releases/latest)
[![Build](https://img.shields.io/github/actions/workflow/status/yourtablecloth/macSandbox/release.yml?label=Release%20DMG)](https://github.com/yourtablecloth/macSandbox/actions/workflows/release.yml)
[![Downloads](https://img.shields.io/github/downloads/yourtablecloth/macSandbox/total?label=downloads)](https://github.com/yourtablecloth/macSandbox/releases)
[![License](https://img.shields.io/badge/license-AGPL--3.0--or--later-blue)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Apple%20Silicon-black?logo=apple&logoColor=white)](#requirements)
[![macOS](https://img.shields.io/badge/macOS-Tahoe%2026%2B-black?logo=apple&logoColor=white)](#requirements)

**Disposable Windows 11 ARM64 sandbox for Apple Silicon Macs** — the Windows
Sandbox experience, on macOS. Boot a throwaway Windows environment in seconds
from a prebuilt base image; every change is discarded on exit.

Runtime: **QEMU + Hypervisor.framework (HVF)** for virtualization, with an
**in-app embedded RDP view** (libfreerdp) for display, input, clipboard,
folder, printer, and audio redirection. The base image is built once from your
own Windows 11 ARM64 ISO via a fully deterministic, unattended
**WinPE + DISM** deployment — no clicks, no prompts.

![macSandbox for Windows — disposable Windows 11 sandbox in an in-app RDP view](docs/images/sandbox-launched.png)

## Features

- **Disposable by design** — copy-on-write overlay per session; discarded on exit
- **One-time unattended baseline build** from your Windows 11 ARM64 ISO
  (deterministic WinPE/DISM deployment, virtio driver injection, Edge first-run
  experience disabled, inbox bloatware removed)
- **In-app RDP session** — no external windows; dynamic resolution, HiDPI
  (Retina) scaling, trackpad scrolling and pinch-to-zoom
- **Windows Sandbox `.wsb` compatibility** — see [WSB-SUPPORT.md](WSB-SUPPORT.md)
  and [examples/sample.wsb](examples/sample.wsb)
- **Clipboard** (text and files, both directions), **shared folders**
  (`\\tsclient` auto-mount), **printer redirection** (CUPS), **audio playback
  and microphone**
- **Localized UI** — English, 한국어, 日本語, Deutsch, Español, Français;
  Korean/Japanese keyboard layouts (right Option = 한/영)
- **License-aware** — confirms Windows licensing checklist before every base
  image build; this project ships no Windows OS, key, or entitlement

## Requirements

> **Apple Silicon only — Intel Macs are _not_ supported.** The runtime depends on
> Apple Silicon virtualization (Hypervisor.framework) and a Windows 11 **ARM64**
> guest; there is no Intel/x86 build or path.

- **Apple Silicon Mac (M1 or later)** — Intel Macs are not supported
- **macOS Tahoe (26) or later** (recommended minimum)
- A **Windows 11 ARM64 ISO** you are licensed to use (e.g., from Microsoft's
  official download channels)
- ~24 GB free disk space during the one-time baseline build

> **Minimum OS note:** the binary is built for macOS 14 (Sonoma) and links
> `arm64_sonoma` dependencies, so it _may_ launch on macOS 14–15 — but only macOS
> Tahoe has been tested, and HVF/virtualization behavior on earlier releases is
> unverified. Use macOS Tahoe for a supported experience.

Building **from source** additionally needs [Homebrew](https://brew.sh)
(`brew install freerdp wimlib`); the packaged DMG bundles these libraries, so end users
running the release do not need Homebrew.

## Download & install

Download the latest **`macSandbox-for-Windows-<version>.dmg`** from the
[Releases page](https://github.com/yourtablecloth/macSandbox/releases/latest),
open it, and drag **macSandbox for Windows** into **Applications**.

> **This build is not signed or notarized** (ad-hoc signature), so macOS Gatekeeper
> blocks it on first launch. To allow it:
>
> 1. Double-click the app — macOS blocks it ("Apple could not verify…").
> 2. Open **System Settings → Privacy & Security**, scroll down to **Security**, and
>    click **Open Anyway** next to the macSandbox message; authenticate, then **Open**.
>
> Or clear the quarantine flag from Terminal and open normally:
>
> ```sh
> xattr -dr com.apple.quarantine "/Applications/macSandbox for Windows.app"
> ```

## Build from source

```sh
# Development build
swift build && .build/debug/MacSandbox

# Packaged .app + DMG (bundles QEMU; see scripts/build.sh for vendor setup)
scripts/package_app.sh
```

On first launch the app asks for your Windows 11 ARM64 ISO and builds the
baseline image unattended (one round, typically 20–40 minutes). After that,
every launch boots a fresh disposable sandbox straight into an in-app RDP
session.

Command-line options mirror `.wsb` settings:

```sh
MacSandbox my-config.wsb
MacSandbox --memory 8192 --cpus 4 --folder ~/Downloads:ro --logon "notepad"
```

## Documentation

- [ARCHITECTURE.md](ARCHITECTURE.md) — how the deterministic WinPE/DISM
  baseline build and the QEMU + embedded-RDP runtime work
- [WSB-SUPPORT.md](WSB-SUPPORT.md) — `.wsb` configuration support matrix
- [Project website](https://yourtablecloth.github.io/macSandbox/) (GitHub Pages, served
  from `docs/`)

## Licensing

macSandbox for Windows is **dual-licensed**:

1. **GNU AGPL-3.0-or-later** (open-source edition) — see [LICENSE](LICENSE)
2. **Commercial license** — see [COMMERCIAL-LICENSE.md](COMMERCIAL-LICENSE.md)

Bundled third-party components (QEMU, EDK2 firmware, etc.) and linked
libraries (FreeRDP/WinPR) remain under their own licenses — see
[LICENSING.md](LICENSING.md), [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)
and [WRITTEN-OFFER.txt](WRITTEN-OFFER.txt). QEMU runs strictly as a separate
process; do not link it in-process (see the invariant in LICENSING.md).

**This project does not include Windows.** You must provide your own Windows
11 ARM64 ISO and hold a valid license for each Windows instance you run.
macSandbox for Windows is an independent project, not affiliated with or
endorsed by Microsoft. Windows is a trademark of the Microsoft group of
companies.

## Contributing & Support

- **Bug reports and feature requests are accepted only via
  [GitHub Issues](https://github.com/yourtablecloth/macSandbox/issues).** There is no
  e-mail support channel.
- External contributions require agreeing to the [CLA](CLA.md), which enables
  the project's dual-licensing model (AGPL + commercial).

---
© 2026 Nam Jung Hyun (rkttu)
