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

#ifndef CFREERDP_H
#define CFREERDP_H

#ifdef __cplusplus
extern "C" {
#endif

/// For verifying the libfreerdp link: tries to create a freerdp instance and returns the version string.
/// If linking fails it fails at the build/link stage, so a successful build + call = link OK.
const char *cfreerdp_link_test(void);

/// PoC-1b-i: connect to RDP at host:port with injected test credentials, receive one frame
/// via gdi, and save it as a PPM (P6) file. Verifies the whole graphics pipeline (connect+decode) headlessly.
/// Returns: 0=success, negative=failure (-1 context, -2 connect, -3 no frame received).
int cfreerdp_capture(const char *host, int port, const char *username, const char *password,
                     const char *outpath);

/// PoC-2: remote→local text clipboard close-loop check. After connecting, inject input to type
/// 'msbxrt' into guest Notepad → Ctrl+A → Ctrl+C, and see whether that text comes back to the host.
/// Returns: 0=received successfully, 1=failure.
int cfreerdp_cliptest(const char *host, int port, const char *username, const char *password);

/// PoC-3: Windows→Mac file clipboard close-loop check. Use PowerShell to create a file on the guest +
/// Set-Clipboard, then see whether that file is transferred to the host temp folder. Returns: 0=success, 1=failure.
int cfreerdp_filetest(const char *host, int port, const char *username, const char *password);

/// PoC-3b: Mac→Windows file clipboard round-trip check. Put a host file on the clipboard, have the guest
/// paste it (materialize) onto the desktop, then retrieve its contents as text and check byte equality. 0=success, 1=failure.
int cfreerdp_filetest2(const char *host, int port, const char *username, const char *password);

/// PoC-3b (folder): Mac→Windows folder (including subfolders) round-trip check. 0=success, 1=failure.
int cfreerdp_filetest3(const char *host, int port, const char *username, const char *password);

/// c: dynamic resolution check (frame size changes after resize). 0=success, 1=failure.
int cfreerdp_restest(const char *host, int port, const char *username, const char *password);

/// Vertical-flip render check (composed frame). 0=normal, 1=flipped.
int cfreerdp_fliptest(void);

#ifdef __cplusplus
}
#endif

#endif /* CFREERDP_H */
