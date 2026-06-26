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

#import <AppKit/AppKit.h>

/// A view (PoC) that drives libfreerdp directly to render the RDP screen into an in-app NSView.
/// Embedded in SwiftUI via NSViewRepresentable without a separate FreeRDP window.
@interface RDPView : NSView

/// Start connecting (freerdp_connect + event loop on a background thread).
- (void)connectToHost:(NSString *)host
                 port:(int)port
             username:(NSString *)username
             password:(NSString *)password;

/// End the connection (stop the thread + cleanup).
- (void)disconnect;

/// Current connection status text (for status display).
@property (nonatomic, readonly, copy) NSString *statusText;

/// Called once on the main thread when the first RDP frame is rendered (for boot overlay → RDP screen transition).
@property (nonatomic, copy) void (^onFirstFrame)(void);

/// Redirection features (reflecting .wsb). Set before connectToHost.
/// Defaults: clipboard on, mic on, printer off, speaker playback on.
@property (nonatomic) BOOL clipboardEnabled;
@property (nonatomic) BOOL micEnabled;
@property (nonatomic) BOOL printerEnabled;
/// Audio playback (guest→host speaker, rdpsnd+CoreAudio). Default YES. Set before connectToHost.
@property (nonatomic) BOOL audioPlaybackEnabled;
/// HiDPI (Retina) — YES means backing pixel resolution + DPI 200%, NO means point resolution + 100%. Default YES.
@property (nonatomic) BOOL hiDPIEnabled;

/// Client keyboard identity (type/subtype/layout) — the basis for the guest's session keyboard driver selection.
/// Korean (8,3,0x412) → right Option (= right Alt) is 한/영. 0 means FreeRDP default. Call before connect.
- (void)setKeyboardType:(int)type subtype:(int)subtype layout:(int)layout;

/// Add a shared folder (.wsb MappedFolder). Call for each folder before connectToHost.
/// Exposed to the guest as a redirected drive. readOnly is not enforced (read/write share).
- (void)addMappedFolder:(NSString *)hostPath name:(NSString *)name readOnly:(BOOL)readOnly;

@end
