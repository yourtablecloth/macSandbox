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

#ifndef RDP_ENGINE_H
#define RDP_ENGINE_H

#include <stdint.h>

// The engine that drives libfreerdp (plain C interface — does not expose WinPR/AppKit types).
// Putting AppKit (NSView) and WinPR in the same translation unit makes COM types (REFIID etc.)
// conflict with CoreFoundation, so the freerdp logic is isolated in this engine (rdp_engine.c).

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RDPEngine RDPEngine;

// Frame callback: BGRX32 buffer (valid only during the callback — copy if needed). Called on the connection thread.
typedef void (*RDPFrameCallback)(void *userdata, const uint8_t *bgrx, int width, int height, int stride);
// Status text callback.
typedef void (*RDPStatusCallback)(void *userdata, const char *status);
// Text copied on the remote (guest) arrives (remote→local). Called on the connection thread.
typedef void (*RDPClipboardTextCallback)(void *userdata, const char *utf8);
// Receives files copied on the remote (guest) into host temp paths (remote→local).
// paths is count UTF8 absolute paths (valid only during the callback). Called on the connection thread.
typedef void (*RDPClipboardFilesCallback)(void *userdata, const char *const *paths, int count);

RDPEngine *rdp_engine_create(const char *host, int port,
                             const char *username, const char *password,
                             RDPFrameCallback onFrame, RDPStatusCallback onStatus,
                             RDPClipboardTextCallback onRemoteText,
                             void *userdata);

// Gate redirection features (reflecting .wsb). Call before rdp_engine_start. If not called, defaults
// (clipboard on, mic on, printer off). Speaker playback is always on (no .wsb toggle).
void rdp_engine_set_features(RDPEngine *engine, int clipboard, int mic, int printer);

// Share a host folder (.wsb MappedFolder). Call for each folder before rdp_engine_start (up to 16).
// Exposed to the guest as a redirected drive. readOnly is unsupported by FreeRDP drive (shared read/write).
void rdp_engine_add_mapped_folder(RDPEngine *engine, const char *hostPath, const char *name, int readOnly);

void rdp_engine_start(RDPEngine *engine); // connect + event loop on a background thread
void rdp_engine_stop(RDPEngine *engine);  // request stop
void rdp_engine_free(RDPEngine *engine);  // cleanup (join the thread after stopping)

// Share local (host) clipboard text with the guest (local→remote). Call on NSPasteboard change.
void rdp_engine_set_local_clipboard_text(RDPEngine *engine, const char *utf8);
// Share local (host) clipboard files with the guest (local→remote, Mac→Windows). paths is count absolute paths.
void rdp_engine_set_local_clipboard_files(RDPEngine *engine, const char *const *paths, int count);

// Register the remote→local file clipboard receive callback (Windows→Mac). Called after all files are received into the temp folder.
void rdp_engine_set_files_callback(RDPEngine *engine, RDPClipboardFilesCallback cb);

// Dynamic resolution: request changing the guest desktop to width×height (pixels) with DPI scale scalePercent (100~500,
// e.g. Retina=200). Matches the window size/backing scale. If called before connecting, it is stored.
void rdp_engine_request_resize(RDPEngine *engine, int width, int height, int scalePercent);

// RDP pointer flags (same values as PTR_FLAGS_* in freerdp/input.h; redefined for use in a winpr-free view).
#define RDP_PTR_MOVE    0x0800
#define RDP_PTR_DOWN    0x8000
#define RDP_PTR_BUTTON1 0x1000
#define RDP_PTR_BUTTON2 0x2000
#define RDP_PTR_BUTTON3 0x4000
#define RDP_PTR_WHEEL   0x0200
#define RDP_PTR_HWHEEL  0x0400
// The wheel rotation amount is the low 9 bits of flags (two's complement). If negative, the NEGATIVE flag + low 8-bit complement value.
#define RDP_PTR_WHEEL_NEGATIVE 0x0100

// Inject input (in-app view interaction). flags are RDP_PTR_*. x/y are guest-resolution coordinates.
void rdp_engine_send_pointer(RDPEngine *engine, uint16_t flags, int x, int y);
// Convert a macOS key code (NSEvent.keyCode) to an RDP scancode and send it.
void rdp_engine_send_mac_key(RDPEngine *engine, uint16_t macKeyCode, int down);

// Audio playback (rdpsnd, guest→host speaker) on/off — default on. Call before rdp_engine_start.
// Explicitly specifies the CoreAudio (sys:mac) subsystem to prevent selecting a silent (fake) backend.
void rdp_engine_set_audio_playback(RDPEngine *engine, int playback);

// Client keyboard identity (type/subtype/layout) — the basis the guest uses to pick its session keyboard driver.
// e.g. Korean 101-key Type A = (8, 3, 0x412) → right Alt is 한/영, right Ctrl is Hanja.
//      Japanese 106-key       = (7, 2, 0x411). 0 means FreeRDP default. Call before rdp_engine_start.
void rdp_engine_set_keyboard(RDPEngine *engine, int type, int subtype, int layout);

// Sync toggle key state (host→guest, RDP Synchronize Event). capsLock/numLock = 0|1.
// Can be called at any point after connecting (ignored if not connected).
void rdp_engine_send_sync_locks(RDPEngine *engine, int capsLock, int numLock);

#ifdef __cplusplus
}
#endif

#endif /* RDP_ENGINE_H */
