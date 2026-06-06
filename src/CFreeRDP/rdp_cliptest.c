// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (C) 2026 Nam Jung Hyun (rkttu) <rkttu.official@gmail.com>
//
// This file is part of MacSandbox, which is dual-licensed:
//   (1) under the GNU General Public License v3.0 or later (see LICENSE), or
//   (2) under a commercial license (see COMMERCIAL-LICENSE.md).
// You may use this file under the terms of either license.
//
// MacSandbox is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE.

#include "CFreeRDP.h"
#include "rdp_engine.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// remote→local 텍스트 클립보드 close-loop 검증. (이 파일은 plain C — winpr/AppKit 미포함)

static char g_remote[512];
static int g_got;
static uint8_t *g_frame; static int g_fw, g_fh, g_fstride;

static void clip_on_text(void *ud, const char *utf8) {
    (void)ud;
    if (utf8) { strncpy(g_remote, utf8, sizeof(g_remote) - 1); g_got = 1; }
}

static void clip_on_frame(void *ud, const uint8_t *bgrx, int w, int h, int stride) {
    (void)ud;
    free(g_frame);
    g_frame = malloc((size_t)h * stride);
    if (g_frame) { memcpy(g_frame, bgrx, (size_t)h * stride); g_fw = w; g_fh = h; g_fstride = stride; }
}

static void save_frame(const char *path) {
    if (!g_frame) return;
    FILE *f = fopen(path, "wb"); if (!f) return;
    fprintf(f, "P6\n%d %d\n255\n", g_fw, g_fh);
    for (int y = 0; y < g_fh; y++) {
        const uint8_t *row = g_frame + (size_t)y * g_fstride;
        for (int x = 0; x < g_fw; x++) { const uint8_t *p = row + x * 4; fputc(p[2], f); fputc(p[1], f); fputc(p[0], f); }
    }
    fclose(f);
}

// macOS US 키보드 keyCode (소문자 letters + space)
static int mac_keycode(char c) {
    switch (c) {
    case 'a': return 0;  case 's': return 1;  case 'd': return 2;  case 'f': return 3;
    case 'h': return 4;  case 'g': return 5;  case 'z': return 6;  case 'x': return 7;
    case 'c': return 8;  case 'v': return 9;  case 'b': return 11; case 'q': return 12;
    case 'w': return 13; case 'e': return 14; case 'r': return 15; case 'y': return 16;
    case 't': return 17; case 'o': return 31; case 'u': return 32; case 'i': return 34;
    case 'p': return 35; case 'l': return 37; case 'j': return 38; case 'k': return 40;
    case 'n': return 45; case 'm': return 46; case ' ': return 49;
    default: return -1;
    }
}

static void tap(RDPEngine *e, int code) {
    rdp_engine_send_mac_key(e, (uint16_t)code, 1); usleep(45000);
    rdp_engine_send_mac_key(e, (uint16_t)code, 0); usleep(45000);
}
static void type_str(RDPEngine *e, const char *s) {
    for (; *s; s++) { int k = mac_keycode(*s); if (k >= 0) tap(e, k); }
}
// 모디파이어+키 콤보 (예: Ctrl+C)
static void combo(RDPEngine *e, int mod, int key) {
    rdp_engine_send_mac_key(e, (uint16_t)mod, 1); usleep(50000);
    tap(e, key);
    rdp_engine_send_mac_key(e, (uint16_t)mod, 0); usleep(100000);
}

#define MAC_CMD 55
#define MAC_CTRL 59
#define MAC_RET 36

int cfreerdp_cliptest(const char *host, int port) {
    g_got = 0; g_remote[0] = 0;
    RDPEngine *e = rdp_engine_create(host, port, "WDAGUtilityAccount", "Sandbox!2026",
                                     clip_on_frame, NULL, clip_on_text, NULL);
    if (!e) return 1;
    rdp_engine_start(e);
    fprintf(stderr, "[cliptest] 연결 + 데스크톱 대기...\n");
    sleep(18);

    // 데스크톱 클릭으로 포커스 확보
    rdp_engine_send_pointer(e, RDP_PTR_MOVE, 700, 450); usleep(100000);
    rdp_engine_send_pointer(e, RDP_PTR_DOWN | RDP_PTR_BUTTON1, 700, 450); usleep(80000);
    rdp_engine_send_pointer(e, RDP_PTR_BUTTON1, 700, 450); usleep(300000);

    // Win+R → "notepad" → Enter
    combo(e, MAC_CMD, 15 /* r */);
    usleep(1200000);
    type_str(e, "notepad");
    tap(e, MAC_RET);
    sleep(4);

    // 메모장에 'msbxrt' 입력 → Ctrl+A → Ctrl+C
    type_str(e, "msbxrt");
    usleep(400000);
    combo(e, MAC_CTRL, 0 /* a */);
    combo(e, MAC_CTRL, 8 /* c */);
    sleep(3);

    save_frame("/tmp/cliptest-frame.ppm");
    int ok = (strstr(g_remote, "msbxrt") != NULL);
    fprintf(stderr, "[cliptest] remote→local 수신: '%s' (기대 'msbxrt') %s\n",
            g_remote, ok ? "OK" : "FAIL");
    rdp_engine_free(e);
    return ok ? 0 : 1;
}
