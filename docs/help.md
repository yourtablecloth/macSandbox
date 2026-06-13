---
layout: default
title: macSandbox for Windows — Help
permalink: /help/
---

# macSandbox for Windows — Help

A disposable **Windows 11 ARM64** sandbox for Apple Silicon Macs. Every session
runs on a copy‑on‑write overlay and is **discarded when you close it** — like
Microsoft's Windows Sandbox, but on macOS (QEMU + Hypervisor.framework, with an
in‑app RDP view).

> This app does **not** include Windows. You supply your own Windows 11 ARM64
> ISO and hold a valid license for each Windows instance you run. See
> [Licensing](#licensing).

## Requirements

- Apple Silicon Mac, macOS 14 (Sonoma) or later
- A **Windows 11 ARM64 ISO** you are licensed to use
- About **24 GB** of free disk space for the one‑time baseline build

## First run — building the baseline image

The first time you launch the app (or after you destroy the base image), you'll
see the **Baseline Setup** screen.

1. Click **Choose ISO…** and select your Windows 11 ARM64 ISO.
2. Pick the **edition** to install (e.g., Windows 11 Pro).
3. Click **Build Baseline** and confirm the **Windows licensing checklist**.
4. The app deploys Windows unattended (WinPE + DISM) — no clicks, no prompts.
   This usually takes **20–40 minutes**. You can watch progress in the VM
   console.

When the build finishes, the app switches to the sandbox automatically. The
baseline is built **once**; later launches boot a fresh sandbox from it in
seconds.

The baseline build also disables Microsoft Edge's first‑run experience and
removes inbox bloatware (games, media utilities, promotional apps) so each
sandbox starts clean.

## Using a sandbox

Once a baseline exists, launching the app boots a disposable sandbox straight
into an **in‑app RDP view**. There is no separate window — Windows appears
inside the app.

- **Display** — HiDPI (Retina) by default; the desktop resizes with the window.
- **Mouse & trackpad** — click, drag, right‑click, middle‑click, two‑finger
  **scroll**, and **pinch‑to‑zoom** (sent as Ctrl + wheel).
- **Keyboard** — left/right modifiers are distinguished. With the Korean layout,
  the **right Option** key toggles 한/영 and right Control is Hanja (set the
  layout in Options).
- **Clipboard** — copy/paste text and files in both directions.
- **Shared folders** — folders mapped via `.wsb` appear in the sandbox under
  `\\tsclient` and are auto‑mounted.
- **Audio** — sandbox audio plays on your Mac; the microphone can be shared.
- **Caps Lock** — synchronized with your Mac's state.

**Ending a sandbox:** choose **Sandbox › Stop Sandbox** (⌘.), close the window,
or quit (⌘Q). All changes in the sandbox are discarded.

## Options

Open **Settings…** (⌘,):

- **General → Language** — *Automatic* follows your macOS language; or pick
  English / 한국어 / 日本語 / Deutsch / Español / Français. A change takes
  effect the next time you launch the app.
- **Sandbox** — defaults for new sandboxes: memory, CPU cores, networking,
  clipboard, microphone, printer, vGPU console. Applied from the next start.
  A `.wsb` file or command‑line switch overrides these.
- **Input & Output** — keyboard layout (for 한/영 etc.), audio playback, and
  HiDPI. Applied at the next connection.

## Configuration files (`.wsb`)

macSandbox for Windows reuses Microsoft's Windows Sandbox `.wsb` (XML) schema —
memory, networking, mapped folders, logon command, and redirection toggles. See
the [`.wsb` support matrix](https://github.com/yourtablecloth/macSandbox/blob/main/WSB-SUPPORT.md)
for exactly what each setting does here, and
[`examples/sample.wsb`](https://github.com/yourtablecloth/macSandbox/blob/main/examples/sample.wsb)
for a starting point.

- **Open from Finder** — double‑click a `.wsb` file; the app launches (or, if
  already idle, immediately starts) a new sandbox with that configuration.
- **Open from the app** — on the *ended* screen, click **Configuration (.wsb)…**.
- If a file can't be parsed, the app shows the error instead of starting.
- **Command line** — `MacSandbox my.wsb`, or switches such as
  `--memory 8192 --cpus 4 --folder ~/Downloads:ro --logon "notepad"`.

## Rebuilding or destroying the baseline

From the **Sandbox** menu or the *ended* screen:

- **Rebuild Baseline…** — runs a fresh unattended install, replacing the current
  base image (useful after a new Windows ISO or to reset defaults).
- **Destroy Base Image…** — permanently deletes the baseline. You'll need to
  build a new one before using the sandbox again.

## Troubleshooting

- **Build fails immediately with a disk‑space error** — free up space; the
  baseline build needs ~24 GB temporarily.
- **"Could not read editions"** — install wimlib: `brew install wimlib`.
- **Audio doesn't follow an output‑device change** — RDP audio binds to the
  output device that was default when the stream opened. Switch your output
  **before** playback starts, or pause/resume (or restart the sandbox) to
  rebind.
- **The build seems stuck** — open the VM console (the boot monitor) to watch
  progress; deployment and first‑boot configuration each take several minutes.

## Licensing

macSandbox for Windows is dual‑licensed: **GNU AGPL‑3.0‑or‑later** (open‑source
edition) or a **commercial license**. See
[LICENSING.md](https://github.com/yourtablecloth/macSandbox/blob/main/LICENSING.md).
Bundled QEMU, EDK2 firmware, and linked FreeRDP remain under their own licenses.

This project ships no Windows OS, product key, or entitlement. One Windows
license covers one instance on one device (physical or virtual); OEM licenses
are generally tied to the original PC. You are responsible for EULA and
activation compliance. macSandbox for Windows is an independent project, not
affiliated with or endorsed by Microsoft. Windows is a trademark of the
Microsoft group of companies.

## Support

Bug reports and feature requests are accepted **only via
[GitHub Issues](https://github.com/yourtablecloth/macSandbox/issues)** — there
is no e‑mail support channel.
