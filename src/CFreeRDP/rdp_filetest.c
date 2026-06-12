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

#include "CFreeRDP.h"
#include "rdp_engine.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// 윈도우→Mac 파일 클립보드 close-loop 검증.
// PowerShell로 게스트에 파일 생성 + Set-Clipboard, 호스트로 전송돼 오는지 확인.

static char g_path[1300];
static int g_got;

static void on_files(void *ud, const char *const *paths, int count) {
    (void)ud;
    if (count > 0 && paths[0]) { strncpy(g_path, paths[0], sizeof(g_path) - 1); g_got = 1; }
}

// macOS US 키보드: 문자 → (keyCode, shift 필요?)
static int mac_key(char c, int *shift) {
    *shift = 0;
    switch (c) {
    // letters
    case 'a': return 0;  case 's': return 1;  case 'd': return 2;  case 'f': return 3;
    case 'h': return 4;  case 'g': return 5;  case 'z': return 6;  case 'x': return 7;
    case 'c': return 8;  case 'v': return 9;  case 'b': return 11; case 'q': return 12;
    case 'w': return 13; case 'e': return 14; case 'r': return 15; case 'y': return 16;
    case 't': return 17; case 'o': return 31; case 'u': return 32; case 'i': return 34;
    case 'p': return 35; case 'l': return 37; case 'j': return 38; case 'k': return 40;
    case 'n': return 45; case 'm': return 46;
    // digits
    case '0': return 29; case '1': return 18; case '2': return 19; case '3': return 20;
    case '4': return 21; case '5': return 23; case '6': return 22; case '7': return 26;
    case '8': return 28; case '9': return 25;
    // unshifted symbols
    case ' ': return 49; case '.': return 47; case ',': return 43; case ';': return 41;
    case '\'': return 39; case '-': return 27; case '=': return 24; case '/': return 44;
    case '\\': return 42; case '`': return 50; case '[': return 33; case ']': return 30;
    // shifted symbols
    case '"': *shift = 1; return 39; case '$': *shift = 1; return 21;
    case '>': *shift = 1; return 47; case '<': *shift = 1; return 43;
    case '|': *shift = 1; return 42; case ':': *shift = 1; return 41;
    case '~': *shift = 1; return 50; case '_': *shift = 1; return 27;
    case '+': *shift = 1; return 24; case '(': *shift = 1; return 25;
    case ')': *shift = 1; return 29; case '*': *shift = 1; return 28;
    case '!': *shift = 1; return 18; case '@': *shift = 1; return 19;
    case '#': *shift = 1; return 20; case '%': *shift = 1; return 23;
    case '^': *shift = 1; return 22; case '&': *shift = 1; return 26;
    case '?': *shift = 1; return 44; case '{': *shift = 1; return 33;
    case '}': *shift = 1; return 30;
    default: return -1;
    }
}

#define MAC_CMD 55
#define MAC_SHIFT 56
#define MAC_CTRL 59
#define MAC_RET 36

static void type_str(RDPEngine *e, const char *s) {
    for (; *s; s++) {
        int shift = 0, k = mac_key(*s, &shift);
        if (k < 0) continue;
        if (shift) { rdp_engine_send_mac_key(e, MAC_SHIFT, 1); usleep(20000); }
        rdp_engine_send_mac_key(e, (uint16_t)k, 1); usleep(35000);
        rdp_engine_send_mac_key(e, (uint16_t)k, 0); usleep(35000);
        if (shift) { rdp_engine_send_mac_key(e, MAC_SHIFT, 0); usleep(20000); }
    }
}

// ── Mac→윈도우 파일(local→remote) round-trip 검증 ──
static char g_rt[512];
static int g_rt_got;
static void rt_on_text(void *ud, const char *utf8) {
    (void)ud;
    if (utf8) { strncpy(g_rt, utf8, sizeof(g_rt) - 1); g_rt_got = 1; }
}

int cfreerdp_filetest2(const char *host, int port) {
    g_rt_got = 0; g_rt[0] = 0;
    // 호스트 소스 파일 생성(개행 없이)
    const char *src = "/tmp/macwin-src.txt";
    FILE *sf = fopen(src, "wb");
    if (sf) { fputs("macToWin123", sf); fclose(sf); }

    RDPEngine *e = rdp_engine_create(host, port, "WDAGUtilityAccount", "Sandbox!2026",
                                     NULL, NULL, rt_on_text, NULL);
    if (!e) return 1;
    rdp_engine_start(e);
    fprintf(stderr, "[filetest2] 연결 + 데스크톱 대기...\n");
    sleep(18);

    // 데스크톱 포커스(빈 영역)
    rdp_engine_send_pointer(e, RDP_PTR_MOVE, 640, 360); usleep(100000);
    rdp_engine_send_pointer(e, RDP_PTR_DOWN | RDP_PTR_BUTTON1, 640, 360); usleep(80000);
    rdp_engine_send_pointer(e, RDP_PTR_BUTTON1, 640, 360); usleep(300000);

    // 호스트 클립보드에 파일 공유(local→remote 광고)
    const char *paths[1] = { src };
    rdp_engine_set_local_clipboard_files(e, paths, 1);
    sleep(2);

    // 데스크톱에 Ctrl+V → 파일 붙여넣기(FileContents로 materialize)
    rdp_engine_send_mac_key(e, MAC_CTRL, 1); usleep(50000);
    { int sh; int v = mac_key('v', &sh); rdp_engine_send_mac_key(e, (uint16_t)v, 1); usleep(40000);
      rdp_engine_send_mac_key(e, (uint16_t)v, 0); usleep(40000); }
    rdp_engine_send_mac_key(e, MAC_CTRL, 0);
    sleep(4); // materialize 대기

    // 붙여진 파일을 읽어 텍스트 클립보드로(→ Windows→Mac으로 회수)
    rdp_engine_send_mac_key(e, MAC_CMD, 1); usleep(60000);
    { int sh; int r = mac_key('r', &sh); rdp_engine_send_mac_key(e, (uint16_t)r, 1); usleep(40000);
      rdp_engine_send_mac_key(e, (uint16_t)r, 0); usleep(40000); }
    rdp_engine_send_mac_key(e, MAC_CMD, 0); usleep(1200000);
    type_str(e, "powershell -c \"scb (gc $home\\desktop\\macwin-src.txt -raw)\"");
    usleep(300000);
    rdp_engine_send_mac_key(e, MAC_RET, 1); usleep(45000);
    rdp_engine_send_mac_key(e, MAC_RET, 0);
    sleep(9);

    int ok = (strstr(g_rt, "macToWin123") != NULL);
    fprintf(stderr, "[filetest2] Mac→윈도우 파일 round-trip: 회수='%s' (기대 'macToWin123') %s\n",
            g_rt, ok ? "OK" : "FAIL");
    rdp_engine_free(e);
    return ok ? 0 : 1;
}

// ── 동적 해상도(c) 검증: 리사이즈 요청 후 프레임 크기 변화 확인 ──
static int g_rw, g_rh;
static void res_on_frame(void *ud, const uint8_t *bgrx, int w, int h, int stride) {
    (void)ud; (void)bgrx; (void)stride; g_rw = w; g_rh = h;
}
int cfreerdp_restest(const char *host, int port) {
    g_rw = 0; g_rh = 0;
    RDPEngine *e = rdp_engine_create(host, port, "WDAGUtilityAccount", "Sandbox!2026",
                                     res_on_frame, NULL, NULL, NULL);
    if (!e) return 1;
    rdp_engine_start(e);
    fprintf(stderr, "[restest] 연결 + 데스크톱 대기...\n");
    sleep(16);
    int bw = g_rw, bh = g_rh;
    fprintf(stderr, "[restest] 초기 프레임 %dx%d → 1280x720 요청\n", bw, bh);
    rdp_engine_request_resize(e, 1280, 720, 100);
    sleep(6);
    int aw = g_rw, ah = g_rh;
    int ok = (aw == 1280 && ah == 720);
    fprintf(stderr, "[restest] 리사이즈 후 프레임 %dx%d (기대 1280x720) %s\n", aw, ah, ok ? "OK" : "FAIL");
    rdp_engine_free(e);
    return ok ? 0 : 1;
}

// ── Mac→윈도우 폴더(하위폴더 포함) round-trip 검증 (b) ──
int cfreerdp_filetest3(const char *host, int port) {
    g_rt_got = 0; g_rt[0] = 0;
    // 호스트에 폴더 구조 생성: /tmp/macwin-folder/sub/b.txt
    system("rm -rf /tmp/macwin-folder && mkdir -p /tmp/macwin-folder/sub");
    FILE *a = fopen("/tmp/macwin-folder/a.txt", "wb"); if (a) { fputs("topfile", a); fclose(a); }
    FILE *b = fopen("/tmp/macwin-folder/sub/b.txt", "wb"); if (b) { fputs("folderContent99", b); fclose(b); }

    RDPEngine *e = rdp_engine_create(host, port, "WDAGUtilityAccount", "Sandbox!2026",
                                     NULL, NULL, rt_on_text, NULL);
    if (!e) return 1;
    rdp_engine_start(e);
    fprintf(stderr, "[filetest3] 연결 + 데스크톱 대기...\n");
    sleep(18);

    rdp_engine_send_pointer(e, RDP_PTR_MOVE, 640, 360); usleep(100000);
    rdp_engine_send_pointer(e, RDP_PTR_DOWN | RDP_PTR_BUTTON1, 640, 360); usleep(80000);
    rdp_engine_send_pointer(e, RDP_PTR_BUTTON1, 640, 360); usleep(300000);

    const char *paths[1] = { "/tmp/macwin-folder" }; // 폴더 통째로 공유(재귀 전개)
    rdp_engine_set_local_clipboard_files(e, paths, 1);
    sleep(2);

    // 데스크톱에 Ctrl+V → 폴더+하위파일 materialize
    rdp_engine_send_mac_key(e, MAC_CTRL, 1); usleep(50000);
    { int sh; int v = mac_key('v', &sh); rdp_engine_send_mac_key(e, (uint16_t)v, 1); usleep(40000);
      rdp_engine_send_mac_key(e, (uint16_t)v, 0); usleep(40000); }
    rdp_engine_send_mac_key(e, MAC_CTRL, 0);
    sleep(5);

    // 하위폴더 파일 내용 회수
    rdp_engine_send_mac_key(e, MAC_CMD, 1); usleep(60000);
    { int sh; int r = mac_key('r', &sh); rdp_engine_send_mac_key(e, (uint16_t)r, 1); usleep(40000);
      rdp_engine_send_mac_key(e, (uint16_t)r, 0); usleep(40000); }
    rdp_engine_send_mac_key(e, MAC_CMD, 0); usleep(1200000);
    type_str(e, "powershell -c \"scb (gc $home\\desktop\\macwin-folder\\sub\\b.txt -raw)\"");
    usleep(300000);
    rdp_engine_send_mac_key(e, MAC_RET, 1); usleep(45000);
    rdp_engine_send_mac_key(e, MAC_RET, 0);
    sleep(9);

    int ok = (strstr(g_rt, "folderContent99") != NULL);
    fprintf(stderr, "[filetest3] 폴더(하위포함) round-trip: 회수='%s' (기대 'folderContent99') %s\n",
            g_rt, ok ? "OK" : "FAIL");
    rdp_engine_free(e);
    return ok ? 0 : 1;
}

int cfreerdp_filetest(const char *host, int port) {
    g_got = 0; g_path[0] = 0;
    RDPEngine *e = rdp_engine_create(host, port, "WDAGUtilityAccount", "Sandbox!2026",
                                     NULL, NULL, NULL, NULL);
    if (!e) return 1;
    rdp_engine_set_files_callback(e, on_files);
    rdp_engine_start(e);
    fprintf(stderr, "[filetest] 연결 + 데스크톱 대기...\n");
    sleep(18);

    // 데스크톱 포커스
    rdp_engine_send_pointer(e, RDP_PTR_MOVE, 700, 450); usleep(100000);
    rdp_engine_send_pointer(e, RDP_PTR_DOWN | RDP_PTR_BUTTON1, 700, 450); usleep(80000);
    rdp_engine_send_pointer(e, RDP_PTR_BUTTON1, 700, 450); usleep(300000);

    // Win+R → PowerShell로 파일 생성 + Set-Clipboard → Enter
    rdp_engine_send_mac_key(e, MAC_CMD, 1); usleep(60000);
    { int sh; int r = mac_key('r', &sh); rdp_engine_send_mac_key(e, (uint16_t)r, 1); usleep(40000);
      rdp_engine_send_mac_key(e, (uint16_t)r, 0); usleep(40000); }
    rdp_engine_send_mac_key(e, MAC_CMD, 0); usleep(1200000);

    type_str(e, "powershell -c \"sc $home\\msbxf.txt msbxfilecontent;scb -path $home\\msbxf.txt\"");
    usleep(300000);
    rdp_engine_send_mac_key(e, MAC_RET, 1); usleep(45000);
    rdp_engine_send_mac_key(e, MAC_RET, 0);
    sleep(11); // PowerShell 콜드스타트 + 파일 생성 + 클립보드 + 전송 대기

    int ok = 0;
    char content[256] = { 0 };
    if (g_got && g_path[0]) {
        FILE *f = fopen(g_path, "rb");
        if (f) { size_t n = fread(content, 1, sizeof(content) - 1, f); content[n] = 0; fclose(f); }
        ok = (strstr(content, "msbxfilecontent") != NULL);
    }
    fprintf(stderr, "[filetest] 윈도우→Mac 파일: 수신=%d 경로='%s' 내용='%.40s' %s\n",
            g_got, g_path, content, ok ? "OK" : "FAIL");
    rdp_engine_free(e);
    return ok ? 0 : 1;
}
