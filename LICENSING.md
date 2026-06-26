# MacSandbox Licensing

> ⚠️ The `COMMERCIAL-LICENSE.md` and `CLA.md` provided alongside this document are **draft templates, not legal advice**.
> Be sure to have them reviewed by an IP attorney before any official commercial/dual-license release.

## Summary

**Code written directly by MacSandbox (macSandbox for Windows) is dual-licensed.**

| Subject | License |
|---|---|
| **MacSandbox's own code** (the works in this repository, such as `src/**`, `Package.swift`, `scripts/**`, etc.) | Choose one of **(1) AGPL-3.0-or-later** (open-source edition) **or (2) a commercial license** ([COMMERCIAL-LICENSE.md](COMMERCIAL-LICENSE.md)) |
| Bundled **QEMU** + its dependent libraries | Their respective GPL/LGPL/permissive licenses (separate programs, not relicensed) |
| Linked **FreeRDP/WinPR** | Apache-2.0 |
| Bundled **edk2** firmware | BSD-2-Clause-Patent |
| Build tool **wimlib** | LGPL-3.0-or-later |

For the full list of third-party components and their licenses, see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

## Why the dual license holds (architectural premise)

1. **GPL code is not linked into the app binary** — QEMU (GPL-2.0-only) and wimlib run as **separate processes**
   (via fork/exec + command-line arguments + the public, documented QMP/RDP socket interfaces).
   By FSF standards they are two separate programs, and bundling them on the same medium (.app/DMG) is
   "mere aggregation" under GPLv2 §2. Therefore GPLv2 copyleft does not propagate to the MacSandbox
   binary, and **no AGPLv3 ↔ GPLv2-only incompatibility arises either** (the incompatibility applies
   only when creating a single combined work).
2. **All libraries linked into the binary are compatible with AGPLv3** — FreeRDP/WinPR (Apache-2.0,
   one-way compatible), their dependent ffmpeg family (libavcodec/x264/x265 = GPL-2.0-**or-later** →
   upgradable to GPLv3; GPLv3 ↔ AGPLv3 is permitted by the mutual-combination clause of §13 of each license),
   libusb (LGPL-2.1-or-later), OpenSSL 3 (Apache-2.0).
3. **Reason for choosing AGPL-3.0** — only the GPLv3 family is compatible with Apache-2.0 linking, and AGPL
   additionally protects the dual-license model from unauthorized commercialization in the form of a network
   service (SaaS circumvention).

> 🚨 **Maintenance rule**: If QEMU/wimlib are changed to *in-process (dylib linking)*, they become a GPLv2-only
> combined work, which is **incompatible with AGPLv3 and breaks the dual license.** Be sure to keep them as
> separate processes (exec + socket/CLI interface). (No UTM-style QEMU dylib embedding.)

## Scope of the commercial edition

- The commercial license applies **only to MacSandbox's own code**.
- The bundled **QEMU/wimlib, etc., are distributed under GPL/LGPL as-is even in the commercial edition**, and their source-code offer obligation ([WRITTEN-OFFER.txt](WRITTEN-OFFER.txt)) remains in effect.
- Therefore it is not a "purely proprietary package with no GPL whatsoever." There are no restrictions on the end user's *use* (use does not trigger GPL obligations), and when a commercial customer **redistributes** the product, the GPL obligations for QEMU and the like are fulfilled by the customer.

## Contributions

To redistribute external contributions under the dual license (including the commercial one), the contributor's consent is required.
Every contributor must agree to [CLA.md](CLA.md) (including permission for AGPL + commercial dual relicensing). (Not needed during the solo-development stage.)

## Compliance deliverables

- `LICENSE` — full text of AGPL-3.0 (open-source edition of the own code)
- `THIRD-PARTY-NOTICES.md` — list of third-party components and licenses
- `WRITTEN-OFFER.txt` — written offer to provide source code for GPL/LGPL components
- `scripts/fetch_gpl_sources.py` — collects GPL/LGPL source tarballs matching the bundled versions (for inclusion in the distribution)
- `scripts/apply_license_headers.py` — applies SPDX/license headers to source files
