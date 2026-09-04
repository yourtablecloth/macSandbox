# Third-Party Notices — MacSandbox

MacSandbox includes (bundles) or links the following third-party software. Each component is
governed by its respective license. Source code for the GPL/LGPL components is
provided in accordance with [WRITTEN-OFFER.txt](WRITTEN-OFFER.txt).

This document is a summary for convenience; the full text of each license is included in the
respective project's distribution or in `gpl-sources/` (when GPL/LGPL sources are bundled).

---

## 1. Components linked into the app binary

| Component | Version | License | Notes |
|---|---|---|---|
| **FreeRDP / WinPR** | 3.26.0 | **Apache-2.0** | Directly linked by the embedded RDP view. NOTICE must be preserved. |

> Apache-2.0 is compatible with AGPL-3.0 (one-way), so it can be included in both the AGPL-3.0
> open-source edition and the commercial edition.

## 2. Firmware (passed to QEMU)

| Component | License |
|---|---|
| **edk2** (`edk2-aarch64-code.fd`, `edk2-arm-vars.fd`) | **BSD-2-Clause-Patent** (full license text: `vendor/qemu/share/qemu/edk2-licenses.txt`) |

MacSandbox builds `edk2-aarch64-code.fd` from EDK II commit
`4dfdca63a93497203f197ec98ba20e2327e4afe4` with the changes recorded in
`firmware/macsandbox-edk2.patch`. The custom build replaces the boot logo and suppresses
graphical boot diagnostics. The EDK II source remains available from the upstream project,
and this repository contains the complete downstream patch.

## 3. Build tools (separate processes)

| Component | Version | License |
|---|---|---|
| **wimlib** (`wimlib-imagex`) | 1.14.5 | **LGPL-3.0-or-later** (some tools GPL-3.0). Used for the baseline build (listing/applying ISO editions). |

## 4. Virtualization runtime — QEMU and dependent libraries (bundled as separate processes)

Components bundled under `vendor/qemu` (per `scripts/qemu-bottles.lock.json`, bottle: `arm64_tahoe`).
QEMU runs as a **separate program** and is not linked with MacSandbox code (mere aggregation).

| Component | Version | License (summary) |
|---|---|---|
| **qemu** | 10.2.1 | **GPL-2.0-only** (+ some LGPL-2.1, BSD) |
| capstone | 5.0.7 | BSD-3-Clause |
| dtc / libfdt | 1.7.2 | GPL-2.0-or-later **and** BSD-2-Clause (libfdt dual) |
| glib | 2.86.4 | LGPL-2.1-or-later |
| gnutls | 3.8.12 | LGPL-2.1-or-later (tools GPL-3.0) |
| jpeg-turbo | 3.1.3 | BSD-3-Clause / IJG |
| libpng | 1.6.55 | PNG Reference Library License (libpng) |
| libslirp | 4.9.1 | BSD-3-Clause / MIT |
| libssh | 0.12.0 | LGPL-2.1 |
| libusb | 1.0.29 | LGPL-2.1-or-later |
| lzo | 2.10 | GPL-2.0-or-later |
| ncurses | 6.6 | MIT-style (X11) |
| pixman | 0.46.4 | MIT |
| snappy | 1.2.2 | BSD-3-Clause |
| vde | 2.3.3 | GPL-2.0-or-later (+ BSD/LGPL parts) |
| zstd | 1.5.7 | BSD-3-Clause (or GPL-2.0 dual) |
| pcre2 | 10.47 | BSD-3-Clause |
| gettext (libintl) | (runtime) | LGPL-2.1-or-later (tools GPL-3.0) |
| nettle | 3.10.2 | LGPL-3.0-or-later **or** GPL-2.0-or-later |
| libtasn1 | 4.21.0 | LGPL-2.1-or-later |
| libunistring | 1.4.2 | LGPL-3.0-or-later **or** GPL-2.0-or-later |
| p11-kit | 0.26.2 | BSD-3-Clause |
| ca-certificates | 2025-12-02 | MPL-2.0 (Mozilla CA bundle) |
| gmp | 6.3.0 | LGPL-3.0-or-later **or** GPL-2.0-or-later |
| openssl@3 | 3.6.1 | Apache-2.0 |
| libidn2 | 2.3.8 | LGPL-3.0-or-later (+ GPL) |
| unbound | 1.24.2 | BSD-3-Clause |
| libevent | 2.1.12 | BSD-3-Clause |
| libnghttp2 | 1.68.0 | MIT |

> The license designations above are a summary, and some components have multiple licenses / per-file licenses.
> For the exact terms, refer to each component's distributed license files. Attorney review is recommended before distribution.

---

## GPL/LGPL Source Code

The **Corresponding Source** of the above components to which GPL-2.0/LGPL/GPL-3.0 applies is
provided in accordance with the written offer in `WRITTEN-OFFER.txt`. To bundle it directly in the
distribution, run `python3 scripts/fetch_gpl_sources.py` to collect source tarballs matching the bundled versions into `gpl-sources/`.
