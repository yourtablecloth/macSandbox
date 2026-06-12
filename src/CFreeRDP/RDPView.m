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

// 이 파일은 AppKit만 import한다. freerdp/winpr 타입은 rdp_engine(plain C)에 격리되어
// CoreFoundation COM 타입과의 충돌을 피한다.

@implementation RDPView {
    RDPEngine *_engine;
    NSLock *_lock;
    int _w, _h;                 // 현재 RDP 프레임 크기(입력 좌표 매핑용)
    CGImageRef _pendingImage;   // 최신 프레임(코얼레싱) — 메인에서 layer.contents로 소비

    NSTimer *_clipTimer;        // 로컬 NSPasteboard 변경 감시
    NSInteger _lastChangeCount;
    BOOL _gotFirstFrame;

    int _kbdType, _kbdSubtype, _kbdLayout;  // 클라이언트 키보드 식별(0 = 기본)
    double _wheelAccumY, _wheelAccumX;      // 트랙패드 정밀 스크롤 누적(120 = 1노치)
    double _magnifyAccum;                   // 핀치 줌 누적 → Ctrl+휠로 변환

    // 렌더 계측(프레임률·이미지 생성 시간)
    double _frameMsAccum;
    int _frameCount;
    CFAbsoluteTime _lastReport;

    NSMutableArray<NSDictionary *> *_mappedFolders; // 공유 폴더(연결 전 수집)
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _lock = [NSLock new];
        _statusText = @"대기";
        self.wantsLayer = YES;
        self.layer.backgroundColor = NSColor.blackColor.CGColor;
        // RDP 프레임을 layer.contents로 직접 올려 GPU가 합성·스케일(드로잉 CPU 스케일 제거).
        self.layer.contentsGravity = kCAGravityResize;
        self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawNever;
        _clipboardEnabled = YES;   // .wsb 기본(Windows Sandbox와 동일)
        _micEnabled = YES;
        _printerEnabled = NO;
        _audioPlaybackEnabled = YES;
        _hiDPIEnabled = YES;
        _mappedFolders = [NSMutableArray array];
    }
    return self;
}

// 비뒤집힘 뷰(기본) — top-down 프레임버퍼를 NSImage drawInRect로 정방향 렌더.
// (뒤집힘 뷰 + drawInRect는 보정이 한 번 더 들어가 상하 반전됨)
- (BOOL)isFlipped { return NO; }

#pragma mark - 엔진 콜백 (연결 스레드에서 호출)

// BGRX32(top-down) 버퍼 → 불투명 CGImage(버퍼 복사 — 이후 재사용 안전).
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
    if (img) [self ingestImage:img width:w height:h frameMs:ms]; // 소유권 이전
}

static void rv_on_status(void *ud, const char *status) {
    RDPView *self = (__bridge RDPView *)ud;
    NSString *s = status ? [NSString stringWithUTF8String:status] : @"";
    dispatch_async(dispatch_get_main_queue(), ^{ self->_statusText = s; });
}

// 원격(게스트) 클립보드 텍스트 도착 → 호스트 NSPasteboard에 기록.
static void rv_on_remote_text(void *ud, const char *utf8) {
    RDPView *self = (__bridge RDPView *)ud;
    NSString *s = utf8 ? [NSString stringWithUTF8String:utf8] : nil;
    if (!s) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSPasteboard *pb = NSPasteboard.generalPasteboard;
        [pb clearContents];
        [pb setString:s forType:NSPasteboardTypeString];
        self->_lastChangeCount = pb.changeCount; // 에코 방지(우리가 쓴 변경은 무시)
        NSLog(@"[RDPView] 원격→로컬 클립보드: %lu자", (unsigned long)s.length);
    });
}

// 원격(게스트)에서 복사된 파일들이 호스트 임시폴더로 도착(윈도우→Mac) → NSPasteboard에 파일 URL로.
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
        [pb writeObjects:urls]; // Finder 등에서 붙여넣기 가능한 파일 URL
        self->_lastChangeCount = pb.changeCount;
        NSLog(@"[RDPView] 원격→로컬 파일 %lu개 → 클립보드", (unsigned long)urls.count);
    });
}

#pragma mark - 렌더 (CGImage → layer.contents, GPU 합성)

// 최신 프레임만 보관(코얼레싱) 후 메인에서 소비. img 소유권을 가져간다.
- (void)ingestImage:(CGImageRef)img width:(int)w height:(int)h frameMs:(double)ms {
    [_lock lock];
    _w = w; _h = h;
    CGImageRef old = _pendingImage;
    _pendingImage = img;
    _frameMsAccum += ms; _frameCount++;
    [_lock unlock];
    if (old) CGImageRelease(old);   // 화면에 못 올라간 이전 프레임 폐기
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
    if (!img) return;                            // 이미 더 최신 프레임이 처리됨

    self.layer.contents = (__bridge id)img;      // GPU 업로드+합성+스케일
    CGImageRelease(img);
    if (report) NSLog(@"[RDPView] render %.0f fps, img생성 %.2f ms/frame", fps, avgMs);
    if (!_gotFirstFrame) {
        _gotFirstFrame = YES;
        [self syncLockKeys];   // 연결 직후 호스트 Caps Lock/NumLock 상태를 게스트에 반영
        if (self.onFirstFrame) self.onFirstFrame();
    }
}

#pragma mark - 입력 (마우스/키보드 → 게스트)

- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)becomeFirstResponder { return YES; }

- (void)guestX:(int *)gx y:(int *)gy fromEvent:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    int gw = _w > 0 ? _w : 1440, gh = _h > 0 ? _h : 900;
    *gx = (w > 0) ? (int)(p.x / w * gw) : 0;
    *gy = (h > 0) ? (int)((h - p.y) / h * gh) : 0; // 비뒤집힘 뷰: y=0이 하단 → RDP(상단=0)로 반전
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

// 누적치에서 휠 1회분(±255 클램프)을 잘라 RDP 휠 이벤트로 전송. 잔여는 누적 유지.
// 회전량은 flags 하위 9비트 2의 보수(음수 = NEGATIVE 플래그 + 하위 8비트 보수값).
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

// 트랙패드/마우스 휠 → RDP 휠. 정밀 델타(트랙패드)는 픽셀 비례, 휠은 노치(±120) 단위.
// scrollingDelta는 macOS '자연스러운 스크롤' 설정이 이미 반영된 값이라 그대로 따른다.
- (void)scrollWheel:(NSEvent *)e {
    double dy = e.scrollingDeltaY, dx = e.scrollingDeltaX;
    if (e.hasPreciseScrollingDeltas) { dy *= 4.0; dx *= 4.0; }   // 1px ≈ 4/120 노치
    else                             { dy *= 120.0; dx *= 120.0; } // 1라인 = 1노치
    _wheelAccumY += dy;
    _wheelAccumX -= dx;  // mac 오른쪽 패닝(+) = Windows 왼쪽 스크롤(-)
    [self flushWheel:&_wheelAccumY horizontal:NO event:e];
    [self flushWheel:&_wheelAccumX horizontal:YES event:e];
}

// 핀치 줌 → Windows 표준 Ctrl+휠 줌. 누적 배율 0.1마다 1노치.
- (void)magnifyWithEvent:(NSEvent *)e {
    if (!_engine) return;
    _magnifyAccum += e.magnification;
    while (_magnifyAccum >= 0.1 || _magnifyAccum <= -0.1) {
        int dir = _magnifyAccum > 0 ? 120 : -120;
        _magnifyAccum -= (dir > 0 ? 0.1 : -0.1);
        uint16_t flags = RDP_PTR_WHEEL | (dir < 0 ? RDP_PTR_WHEEL_NEGATIVE : 0)
                       | (uint16_t)(dir & 0xFF);
        int x, y; [self guestX:&x y:&y fromEvent:e];
        rdp_engine_send_mac_key(_engine, 59, 1);            // Ctrl down (좌측)
        rdp_engine_send_pointer(_engine, flags, x, y);      // 휠 ±120
        rdp_engine_send_mac_key(_engine, 59, 0);            // Ctrl up
    }
}

- (void)keyDown:(NSEvent *)e { if (_engine) rdp_engine_send_mac_key(_engine, e.keyCode, 1); }
- (void)keyUp:(NSEvent *)e   { if (_engine) rdp_engine_send_mac_key(_engine, e.keyCode, 0); }

// 현재 호스트 Caps Lock 상태를 게스트에 동기화(+ 키패드 일관성 위해 NumLock은 항상 on).
- (void)syncLockKeys {
    if (!_engine) return;
    BOOL caps = (NSEvent.modifierFlags & NSEventModifierFlagCapsLock) != 0;
    rdp_engine_send_sync_locks(_engine, caps ? 1 : 0, 1);
}

// modifier 키는 flagsChanged로만 온다. keyCode로 좌/우를 구분해 그대로 전달한다
// (오른쪽 Option=한/영 등 좌우가 다른 매핑 지원). 눌림/뗌은 장치별 플래그로 판정.
- (void)flagsChanged:(NSEvent *)e {
    if (!_engine) return;
    // NX_DEVICE*KEYMASK (IOKit 장치별 modifier 플래그 — 좌/우 개별 상태)
    static const struct { uint16_t keyCode; NSEventModifierFlags deviceMask; } mods[] = {
        { 56, 0x0002 },   // left shift
        { 60, 0x0004 },   // right shift
        { 59, 0x0001 },   // left control
        { 62, 0x2000 },   // right control
        { 58, 0x0020 },   // left option
        { 61, 0x0040 },   // right option (한국어 키보드 타입이면 게스트에서 한/영)
        { 55, 0x0008 },   // left command
        { 54, 0x0010 },   // right command
    };
    uint16_t kc = e.keyCode;
    if (kc == 57) {       // Caps Lock — 키 자체 대신 토글 상태를 동기화(상태 불일치 방지)
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

// 동적 해상도: 뷰 크기가 바뀌면(디바운스) 게스트 데스크톱을 창의 픽셀 크기에 맞춘다.
- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(pushResize) object:nil];
    [self performSelector:@selector(pushResize) withObject:nil afterDelay:0.4];
}

- (void)pushResize {
    if (!_engine) return;
    int w, h, scale;
    if (_hiDPIEnabled) {
        NSSize px = [self convertSizeToBacking:self.bounds.size]; // 포인트→백킹 픽셀(선명도)
        w = (int)(px.width + 0.5); h = (int)(px.height + 0.5);
        // 게스트 DPI 배율을 호스트 디스플레이 배율에 맞춤(Retina 2x → 200% → UI가 작지 않게).
        CGFloat bs = self.window.backingScaleFactor;
        if (bs < 1.0) bs = NSScreen.mainScreen.backingScaleFactor;
        if (bs < 1.0) bs = 1.0;
        scale = (int)(bs * 100.0 + 0.5);
    } else {
        // 표준 해상도 — 포인트 크기 그대로(렌더 부하↓, 선명도↓), DPI 100%.
        w = (int)(self.bounds.size.width + 0.5); h = (int)(self.bounds.size.height + 0.5);
        scale = 100;
    }
    if (w > 0 && h > 0) rdp_engine_request_resize(_engine, w, h, scale);
}

// 마우스 이동 추적 활성화
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *a in self.trackingAreas) [self removeTrackingArea:a];
    NSTrackingArea *ta = [[NSTrackingArea alloc] initWithRect:self.bounds
        options:(NSTrackingMouseMoved | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect)
        owner:self userInfo:nil];
    [self addTrackingArea:ta];
}

#pragma mark - 공개 API

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
    // 로컬 클립보드 변경 감시(local→remote)
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

    // 파일 URL 우선(local→remote 파일: Mac→윈도우)
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
            NSLog(@"[RDPView] 로컬→원격 파일 %d개", n);
            return;
        }
    }

    NSString *s = [pb stringForType:NSPasteboardTypeString];
    if (s.length) {
        rdp_engine_set_local_clipboard_text(_engine, s.UTF8String);
        NSLog(@"[RDPView] 로컬→원격 클립보드: %lu자", (unsigned long)s.length);
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

// 상하 반전 결정론 검증: top=빨강 / bottom=파랑 합성 프레임을 렌더해 위쪽이 빨강인지 확인.
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
        // 실제 윈도우 백킹에 올려야 cacheDisplayInRect가 layer.contents를 정확히 렌더.
        NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, w, h)
                         styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        win.contentView = v;
        CGImageRef img = rv_make_image(buf, w, h, stride);
        [v ingestImage:img width:w height:h frameMs:0]; // 소유권 이전
        // consumePending(비동기)가 layer.contents를 설정하도록 런루프를 잠깐 돌림
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
        [v displayIfNeeded];
        NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:v.bounds];
        [v cacheDisplayInRect:v.bounds toBitmapImageRep:rep];
        NSInteger pw = rep.pixelsWide, ph = rep.pixelsHigh;  // Retina면 2x
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
