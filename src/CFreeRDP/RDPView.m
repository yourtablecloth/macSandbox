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

#import "RDPView.h"
#import "rdp_engine.h"
#import "CFreeRDP.h"

@interface RDPView ()
- (void)ingestImage:(CGImageRef)img width:(int)w height:(int)h frameMs:(double)ms;
@end

// This file imports only AppKit. The freerdp/winpr types are isolated in rdp_engine (plain C)
// to avoid conflicts with CoreFoundation COM types.

@implementation RDPView {
    RDPEngine *_engine;
    NSLock *_lock;
    int _w, _h;                 // current RDP frame size (for input coordinate mapping)
    CGImageRef _pendingImage;   // latest frame (coalescing) — consumed on main via layer.contents

    NSTimer *_clipTimer;        // watches local NSPasteboard changes
    NSInteger _lastChangeCount;
    BOOL _gotFirstFrame;

    int _kbdType, _kbdSubtype, _kbdLayout;  // client keyboard identity (0 = default)
    double _wheelAccumY, _wheelAccumX;      // trackpad precise scroll accumulation (120 = 1 notch)
    double _magnifyAccum;                   // pinch zoom accumulation → converted to Ctrl+wheel

    // render instrumentation (frame rate · image creation time)
    double _frameMsAccum;
    int _frameCount;
    CFAbsoluteTime _lastReport;

    NSMutableArray<NSDictionary *> *_mappedFolders; // shared folders (collected before connect)
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _lock = [NSLock new];
        _statusText = @"Idle";
        self.wantsLayer = YES;
        self.layer.backgroundColor = NSColor.blackColor.CGColor;
        // Push RDP frames directly to layer.contents so the GPU composites and scales (removes CPU drawing scale).
        self.layer.contentsGravity = kCAGravityResize;
        self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawNever;
        _clipboardEnabled = YES;   // .wsb default (same as Windows Sandbox)
        _micEnabled = YES;
        _printerEnabled = NO;
        _audioPlaybackEnabled = YES;
        _hiDPIEnabled = YES;
        _mappedFolders = [NSMutableArray array];
    }
    return self;
}

// Non-flipped view (default) — renders a top-down framebuffer upright via NSImage drawInRect.
// (A flipped view + drawInRect applies the correction once more and ends up vertically inverted.)
- (BOOL)isFlipped { return NO; }

#pragma mark - Engine callbacks (called on the connection thread)

// BGRX32 (top-down) buffer → opaque CGImage (buffer is copied — safe to reuse afterward).
static CGImageRef rv_make_image(const uint8_t *bgrx, int w, int h, int stride) {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef bmp = CGBitmapContextCreate((void *)bgrx, w, h, 8, stride, cs,
        kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGImageRef img = bmp ? CGBitmapContextCreateImage(bmp) : NULL;
    if (bmp) CGContextRelease(bmp);
    CGColorSpaceRelease(cs);
    return img;
}

static void rv_on_frame(void *ud, const uint8_t *bgrx, int w, int h, int stride) {
    RDPView *self = (__bridge RDPView *)ud;
    if (!bgrx || w <= 0 || h <= 0) return;
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    CGImageRef img = rv_make_image(bgrx, w, h, stride);
    double ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0;
    if (img) [self ingestImage:img width:w height:h frameMs:ms]; // ownership transferred
}

static void rv_on_status(void *ud, const char *status) {
    RDPView *self = (__bridge RDPView *)ud;
    NSString *s = status ? [NSString stringWithUTF8String:status] : @"";
    dispatch_async(dispatch_get_main_queue(), ^{ self->_statusText = s; });
}

// Remote (guest) clipboard text arrives → written to the host NSPasteboard.
static void rv_on_remote_text(void *ud, const char *utf8) {
    RDPView *self = (__bridge RDPView *)ud;
    NSString *s = utf8 ? [NSString stringWithUTF8String:utf8] : nil;
    if (!s) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSPasteboard *pb = NSPasteboard.generalPasteboard;
        [pb clearContents];
        [pb setString:s forType:NSPasteboardTypeString];
        self->_lastChangeCount = pb.changeCount; // echo prevention (ignore the change we wrote)
        NSLog(@"[RDPView] remote→local clipboard: %lu chars", (unsigned long)s.length);
    });
}

// Files copied on the remote (guest) arrive in the host temp folder (Windows→Mac) → placed on NSPasteboard as file URLs.
static void rv_on_remote_files(void *ud, const char *const *paths, int count) {
    RDPView *self = (__bridge RDPView *)ud;
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (int i = 0; i < count; i++) {
        if (paths[i]) {
            NSString *p = [NSString stringWithUTF8String:paths[i]];
            if (p) [urls addObject:[NSURL fileURLWithPath:p]];
        }
    }
    if (urls.count == 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSPasteboard *pb = NSPasteboard.generalPasteboard;
        [pb clearContents];
        [pb writeObjects:urls]; // file URLs pasteable in Finder etc.
        self->_lastChangeCount = pb.changeCount;
        NSLog(@"[RDPView] remote→local %lu file(s) → clipboard", (unsigned long)urls.count);
    });
}

#pragma mark - Render (CGImage → layer.contents, GPU compositing)

// Keep only the latest frame (coalescing) then consume on main. Takes ownership of img.
- (void)ingestImage:(CGImageRef)img width:(int)w height:(int)h frameMs:(double)ms {
    [_lock lock];
    _w = w; _h = h;
    CGImageRef old = _pendingImage;
    _pendingImage = img;
    _frameMsAccum += ms; _frameCount++;
    [_lock unlock];
    if (old) CGImageRelease(old);   // discard the previous frame that never made it to screen
    dispatch_async(dispatch_get_main_queue(), ^{ [self consumePending]; });
}

- (void)consumePending {
    [_lock lock];
    CGImageRef img = _pendingImage; _pendingImage = NULL;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (_lastReport == 0) _lastReport = now;
    BOOL report = (now - _lastReport >= 2.0) && _frameCount > 0;
    double avgMs = report ? _frameMsAccum / _frameCount : 0;
    double fps = report ? _frameCount / (now - _lastReport) : 0;
    if (report) { _frameMsAccum = 0; _frameCount = 0; _lastReport = now; }
    [_lock unlock];
    if (!img) return;                            // a newer frame was already processed

    self.layer.contents = (__bridge id)img;      // GPU upload + composite + scale
    CGImageRelease(img);
    if (report) NSLog(@"[RDPView] render %.0f fps, img creation %.2f ms/frame", fps, avgMs);
    if (!_gotFirstFrame) {
        _gotFirstFrame = YES;
        [self syncLockKeys];   // right after connecting, reflect host Caps Lock/NumLock state to the guest
        if (self.onFirstFrame) self.onFirstFrame();
    }
}

#pragma mark - Input (mouse/keyboard → guest)

- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)becomeFirstResponder { return YES; }

- (void)guestX:(int *)gx y:(int *)gy fromEvent:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    int gw = _w > 0 ? _w : 1440, gh = _h > 0 ? _h : 900;
    *gx = (w > 0) ? (int)(p.x / w * gw) : 0;
    *gy = (h > 0) ? (int)((h - p.y) / h * gh) : 0; // non-flipped view: y=0 is bottom → invert to RDP (top=0)
}

- (void)sendPointer:(uint16_t)flags event:(NSEvent *)e {
    if (!_engine) return;
    int x, y; [self guestX:&x y:&y fromEvent:e];
    rdp_engine_send_pointer(_engine, flags, x, y);
}

- (void)mouseMoved:(NSEvent *)e   { [self sendPointer:RDP_PTR_MOVE event:e]; }
- (void)mouseDragged:(NSEvent *)e { [self sendPointer:RDP_PTR_MOVE | RDP_PTR_BUTTON1 event:e]; }
- (void)mouseDown:(NSEvent *)e    { [self.window makeFirstResponder:self]; [self sendPointer:RDP_PTR_DOWN | RDP_PTR_BUTTON1 event:e]; }
- (void)mouseUp:(NSEvent *)e      { [self sendPointer:RDP_PTR_BUTTON1 event:e]; }
- (void)rightMouseDown:(NSEvent *)e { [self sendPointer:RDP_PTR_DOWN | RDP_PTR_BUTTON2 event:e]; }
- (void)rightMouseUp:(NSEvent *)e   { [self sendPointer:RDP_PTR_BUTTON2 event:e]; }
- (void)otherMouseDown:(NSEvent *)e { [self sendPointer:RDP_PTR_DOWN | RDP_PTR_BUTTON3 event:e]; }
- (void)otherMouseUp:(NSEvent *)e   { [self sendPointer:RDP_PTR_BUTTON3 event:e]; }
- (void)otherMouseDragged:(NSEvent *)e { [self sendPointer:RDP_PTR_MOVE | RDP_PTR_BUTTON3 event:e]; }
- (void)rightMouseDragged:(NSEvent *)e { [self sendPointer:RDP_PTR_MOVE | RDP_PTR_BUTTON2 event:e]; }

// Cut one wheel step (±255 clamped) from the accumulator and send it as an RDP wheel event. The remainder stays accumulated.
// The rotation amount is the low 9 bits of flags in two's complement (negative = NEGATIVE flag + low 8-bit complement value).
- (void)flushWheel:(double *)accum horizontal:(BOOL)horizontal event:(NSEvent *)e {
    if (!_engine) { *accum = 0; return; }
    int v = (int)*accum;
    if (v == 0) return;
    if (v > 255) v = 255; else if (v < -255) v = -255;
    *accum -= v;
    uint16_t flags = (horizontal ? RDP_PTR_HWHEEL : RDP_PTR_WHEEL);
    if (v < 0) flags |= RDP_PTR_WHEEL_NEGATIVE;
    flags |= (uint16_t)(v & 0xFF);
    int x, y; [self guestX:&x y:&y fromEvent:e];
    rdp_engine_send_pointer(_engine, flags, x, y);
}

// Trackpad/mouse wheel → RDP wheel. Precise deltas (trackpad) are pixel-proportional, the wheel uses notch (±120) units.
// scrollingDelta already reflects the macOS 'natural scrolling' setting, so we follow it as-is.
- (void)scrollWheel:(NSEvent *)e {
    double dy = e.scrollingDeltaY, dx = e.scrollingDeltaX;
    if (e.hasPreciseScrollingDeltas) { dy *= 4.0; dx *= 4.0; }   // 1px ≈ 4/120 notch
    else                             { dy *= 120.0; dx *= 120.0; } // 1 line = 1 notch
    _wheelAccumY += dy;
    _wheelAccumX -= dx;  // mac rightward panning (+) = Windows leftward scroll (-)
    [self flushWheel:&_wheelAccumY horizontal:NO event:e];
    [self flushWheel:&_wheelAccumX horizontal:YES event:e];
}

// Pinch zoom → standard Windows Ctrl+wheel zoom. One notch per 0.1 accumulated magnification.
- (void)magnifyWithEvent:(NSEvent *)e {
    if (!_engine) return;
    _magnifyAccum += e.magnification;
    while (_magnifyAccum >= 0.1 || _magnifyAccum <= -0.1) {
        int dir = _magnifyAccum > 0 ? 120 : -120;
        _magnifyAccum -= (dir > 0 ? 0.1 : -0.1);
        uint16_t flags = RDP_PTR_WHEEL | (dir < 0 ? RDP_PTR_WHEEL_NEGATIVE : 0)
                       | (uint16_t)(dir & 0xFF);
        int x, y; [self guestX:&x y:&y fromEvent:e];
        rdp_engine_send_mac_key(_engine, 59, 1);            // Ctrl down (left)
        rdp_engine_send_pointer(_engine, flags, x, y);      // wheel ±120
        rdp_engine_send_mac_key(_engine, 59, 0);            // Ctrl up
    }
}

- (void)keyDown:(NSEvent *)e { if (_engine) rdp_engine_send_mac_key(_engine, e.keyCode, 1); }
- (void)keyUp:(NSEvent *)e   { if (_engine) rdp_engine_send_mac_key(_engine, e.keyCode, 0); }

// Sync the current host Caps Lock state to the guest (+ NumLock is always on for keypad consistency).
- (void)syncLockKeys {
    if (!_engine) return;
    BOOL caps = (NSEvent.modifierFlags & NSEventModifierFlagCapsLock) != 0;
    rdp_engine_send_sync_locks(_engine, caps ? 1 : 0, 1);
}

// Modifier keys only arrive via flagsChanged. Distinguish left/right by keyCode and pass them through as-is
// (supports mappings that differ between left and right, e.g. right Option = 한/영). Press/release is determined by per-device flags.
- (void)flagsChanged:(NSEvent *)e {
    if (!_engine) return;
    // NX_DEVICE*KEYMASK (IOKit per-device modifier flags — individual left/right state)
    static const struct { uint16_t keyCode; NSEventModifierFlags deviceMask; } mods[] = {
        { 56, 0x0002 },   // left shift
        { 60, 0x0004 },   // right shift
        { 59, 0x0001 },   // left control
        { 62, 0x2000 },   // right control
        { 58, 0x0020 },   // left option
        { 61, 0x0040 },   // right option (한/영 on the guest if the keyboard type is Korean)
        { 55, 0x0008 },   // left command
        { 54, 0x0010 },   // right command
    };
    uint16_t kc = e.keyCode;
    if (kc == 57) {       // Caps Lock — sync the toggle state instead of the key itself (avoid state mismatch)
        [self syncLockKeys];
        return;
    }
    for (size_t i = 0; i < sizeof(mods) / sizeof(mods[0]); i++) {
        if (mods[i].keyCode != kc) continue;
        BOOL down = (e.modifierFlags & mods[i].deviceMask) != 0;
        rdp_engine_send_mac_key(_engine, kc, down ? 1 : 0);
        return;
    }
}

// Dynamic resolution: when the view size changes (debounced), fit the guest desktop to the window's pixel size.
- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(pushResize) object:nil];
    [self performSelector:@selector(pushResize) withObject:nil afterDelay:0.4];
}

- (void)pushResize {
    if (!_engine) return;
    int w, h, scale;
    if (_hiDPIEnabled) {
        NSSize px = [self convertSizeToBacking:self.bounds.size]; // point→backing pixels (sharpness)
        w = (int)(px.width + 0.5); h = (int)(px.height + 0.5);
        // Match the guest DPI scale to the host display scale (Retina 2x → 200% → so the UI isn't too small).
        CGFloat bs = self.window.backingScaleFactor;
        if (bs < 1.0) bs = NSScreen.mainScreen.backingScaleFactor;
        if (bs < 1.0) bs = 1.0;
        scale = (int)(bs * 100.0 + 0.5);
    } else {
        // Standard resolution — point size as-is (less render load, less sharpness), DPI 100%.
        w = (int)(self.bounds.size.width + 0.5); h = (int)(self.bounds.size.height + 0.5);
        scale = 100;
    }
    if (w > 0 && h > 0) rdp_engine_request_resize(_engine, w, h, scale);
}

// Enable mouse move tracking
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *a in self.trackingAreas) [self removeTrackingArea:a];
    NSTrackingArea *ta = [[NSTrackingArea alloc] initWithRect:self.bounds
        options:(NSTrackingMouseMoved | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect)
        owner:self userInfo:nil];
    [self addTrackingArea:ta];
}

#pragma mark - Public API

- (void)connectToHost:(NSString *)host port:(int)port
             username:(NSString *)username password:(NSString *)password {
    if (_engine) return;
    _engine = rdp_engine_create(host.UTF8String, port,
                                username.UTF8String, password.UTF8String,
                                rv_on_frame, rv_on_status, rv_on_remote_text,
                                (__bridge void *)self);
    rdp_engine_set_features(_engine, _clipboardEnabled, _micEnabled, _printerEnabled);
    rdp_engine_set_audio_playback(_engine, _audioPlaybackEnabled);
    if (_kbdType > 0 || _kbdLayout > 0)
        rdp_engine_set_keyboard(_engine, _kbdType, _kbdSubtype, _kbdLayout);
    for (NSDictionary *f in _mappedFolders) {
        rdp_engine_add_mapped_folder(_engine, [f[@"path"] UTF8String], [f[@"name"] UTF8String],
                                     [f[@"readOnly"] boolValue] ? 1 : 0);
    }
    rdp_engine_set_files_callback(_engine, rv_on_remote_files);
    rdp_engine_start(_engine);
    // watch for local clipboard changes (local→remote)
    _lastChangeCount = NSPasteboard.generalPasteboard.changeCount;
    _clipTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self
                  selector:@selector(checkLocalClipboard) userInfo:nil repeats:YES];
}

- (void)setKeyboardType:(int)type subtype:(int)subtype layout:(int)layout {
    _kbdType = type; _kbdSubtype = subtype; _kbdLayout = layout;
}

- (void)addMappedFolder:(NSString *)hostPath name:(NSString *)name readOnly:(BOOL)readOnly {
    if (hostPath.length == 0) return;
    [_mappedFolders addObject:@{ @"path": hostPath,
                                 @"name": name ?: @"share",
                                 @"readOnly": @(readOnly) }];
}

- (void)checkLocalClipboard {
    NSPasteboard *pb = NSPasteboard.generalPasteboard;
    if (pb.changeCount == _lastChangeCount) return;
    _lastChangeCount = pb.changeCount;
    if (!_engine) return;

    // file URLs first (local→remote files: Mac→Windows)
    NSArray<NSURL *> *urls = [pb readObjectsForClasses:@[NSURL.class]
                              options:@{ NSPasteboardURLReadingFileURLsOnlyKey: @YES }];
    if (urls.count > 0) {
        const char *paths[256];
        int n = 0;
        for (NSURL *u in urls) {
            if (n >= 256) break;
            const char *p = u.path.fileSystemRepresentation;
            if (p) paths[n++] = p;
        }
        if (n > 0) {
            rdp_engine_set_local_clipboard_files(_engine, paths, n);
            NSLog(@"[RDPView] local→remote %d file(s)", n);
            return;
        }
    }

    NSString *s = [pb stringForType:NSPasteboardTypeString];
    if (s.length) {
        rdp_engine_set_local_clipboard_text(_engine, s.UTF8String);
        NSLog(@"[RDPView] local→remote clipboard: %lu chars", (unsigned long)s.length);
    }
}

- (void)disconnect {
    [_clipTimer invalidate]; _clipTimer = nil;
    if (_engine) {
        rdp_engine_free(_engine);
        _engine = NULL;
    }
}

- (void)dealloc {
    [self disconnect];
    if (_pendingImage) CGImageRelease(_pendingImage);
}

@end

// Deterministic vertical-flip check: render a composed frame with top=red / bottom=blue and verify the top is red.
int cfreerdp_fliptest(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        const int w = 40, h = 40, stride = w * 4;
        RDPView *v = [[RDPView alloc] initWithFrame:NSMakeRect(0, 0, w, h)];
        uint8_t *buf = malloc((size_t)h * stride);
        for (int y = 0; y < h; y++) {
            for (int x = 0; x < w; x++) {
                uint8_t *p = buf + (size_t)y * stride + x * 4; // BGRX
                if (y < h / 2) { p[0] = 0;   p[1] = 0; p[2] = 255; p[3] = 255; } // top = RED
                else            { p[0] = 255; p[1] = 0; p[2] = 0;   p[3] = 255; } // bottom = BLUE
            }
        }
        // Must attach to a real window backing so cacheDisplayInRect renders layer.contents correctly.
        NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, w, h)
                         styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        win.contentView = v;
        CGImageRef img = rv_make_image(buf, w, h, stride);
        [v ingestImage:img width:w height:h frameMs:0]; // ownership transferred
        // run the run loop briefly so consumePending (asynchronous) sets layer.contents
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
        [v displayIfNeeded];
        NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:v.bounds];
        [v cacheDisplayInRect:v.bounds toBitmapImageRep:rep];
        NSInteger pw = rep.pixelsWide, ph = rep.pixelsHigh;  // 2x on Retina
        NSColor *top = [[rep colorAtX:pw / 2 y:ph / 10] colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
        NSColor *bot = [[rep colorAtX:pw / 2 y:ph - ph / 10 - 1] colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
        int ok = (top.redComponent > 0.5 && top.blueComponent < 0.5 &&
                  bot.blueComponent > 0.5 && bot.redComponent < 0.5);
        free(buf);
        fprintf(stderr, "[fliptest] top=(r%.2f g%.2f b%.2f) bottom=(r%.2f g%.2f b%.2f) → %s\n",
                top.redComponent, top.greenComponent, top.blueComponent,
                bot.redComponent, bot.greenComponent, bot.blueComponent,
                ok ? "UPRIGHT OK" : "FLIPPED");
        return ok ? 0 : 1;
    }
}
