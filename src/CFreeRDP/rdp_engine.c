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

#include "rdp_engine.h"

// freerdp 3.x 헤더는 구조체에 deprecated 멤버(pVerifyCertificate 등)를 선언해 include만 해도
// -Wdeprecated-declarations 경고가 난다. 헤더 노이즈만 억제하고(내 코드 경고는 유지) pop한다.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#include <freerdp/freerdp.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/codec/color.h>
#include <freerdp/settings.h>
#include <freerdp/client.h>
#include <freerdp/client/cmdline.h>
#include <freerdp/client/cliprdr.h>
#include <freerdp/channels/cliprdr.h>
#include <freerdp/client/disp.h>
#include <freerdp/channels/disp.h>
#include <freerdp/client/rdpgfx.h>
#include <freerdp/channels/rdpgfx.h>
#include <freerdp/gdi/gfx.h>
#include <freerdp/client/channels.h>
#include <freerdp/addin.h>
#include <freerdp/input.h>
#include <winpr/synch.h>
#include <winpr/clipboard.h>
#include <winpr/string.h>
#include <winpr/input.h>
#include <winpr/shell.h>
#pragma clang diagnostic pop

#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include <sys/stat.h>
#include <dirent.h>

// local→remote(Mac→윈도우) 파일 클립보드용으로 광고하는 포맷 ID(LONG_FORMAT_NAMES라 서버는 이름으로 매핑).
#define FMT_FILEDESCRIPTORW 0xC100
#define FMT_FILECONTENTS    0xC101
#define WIN_ATTR_DIRECTORY  0x10
#define WIN_ATTR_NORMAL     0x80

#define FT_MAX_FILES 1024
#define FT_CHUNK 1048576  // 1MB 청크

// 원격→로컬 파일 전송 상태(윈도우→Mac). 하위폴더는 중첩 경로로 생성.
typedef struct {
    char path[1300];   // 임시 파일 경로(중첩 포함)
    uint64_t size;
    uint64_t pos;
    FILE *fp;
    int isDir;
    int topLevel;      // ftDir 바로 아래(붙여넣기 대상으로 보고)
} ftFile;

// local→remote(Mac→윈도우) 공유 항목. 폴더는 재귀 전개되어 평면 목록이 된다.
typedef struct {
    char rel[600];     // 게스트가 보는 상대경로('\' 구분, 예: "folder\\sub\\a.txt")
    char local[1300];  // 실제 호스트 절대경로
    int isDir;
    uint64_t size;
} localItem;

struct RDPEngine {
    char *host, *user, *pass;
    int port;
    RDPFrameCallback onFrame;
    RDPStatusCallback onStatus;
    RDPClipboardTextCallback onRemoteText;
    RDPClipboardFilesCallback onRemoteFiles;
    void *userdata;

    pthread_t thread;
    int threadStarted;
    volatile int stop;
    freerdp *instance;

    CliprdrClientContext *clip;  // 클립보드 채널 컨텍스트(연결 시 채워짐)
    pthread_mutex_t clipLock;
    char *localText;             // 호스트→게스트 공유용 로컬 클립보드 텍스트(UTF8)
    localItem localItems[FT_MAX_FILES]; // 호스트→게스트 공유 항목(폴더 재귀 전개)
    int localItemCount;

    DispClientContext *disp;     // Display Control 채널(동적 해상도). 연결 시 채워짐
    int reqW, reqH, reqScale;    // 대기 중 요청 해상도/DPI배율(채널 연결 전 요청 시 보관)
    RdpgfxClientContext *gfx;    // Graphics Pipeline(RDPGFX) 채널. 연결 시 gdi에 연결
    int featClipboard;           // 클립보드 리다이렉션 on/off(.wsb ClipboardRedirection)
    int featMic;                 // 마이크 캡처 on/off(.wsb AudioInput). 스피커 재생은 상시.
    int featPrinter;             // 프린터 리다이렉션 on/off(.wsb PrinterRedirection)
    int featSound;               // 오디오 재생(rdpsnd) on/off — 기본 on(옵션으로 끔)
    int kbdType, kbdSubtype, kbdLayout; // 클라이언트 키보드 식별(0 = FreeRDP 기본)
    struct { char path[2048]; char name[256]; } mapped[16]; // 공유 폴더(.wsb MappedFolders)
    int mappedCount;

    UINT32 fileFormatId;         // 서버가 알린 "FileGroupDescriptorW" 포맷 ID(0=없음)
    UINT32 pendingFormatId;      // 마지막 ClientFormatDataRequest의 포맷(응답 구분용)
    char ftDir[1100];            // 받은 파일 임시 디렉토리
    ftFile ftFiles[FT_MAX_FILES];
    int ftCount;
    int ftCur;                   // 현재 받는 파일 인덱스
    UINT32 ftStream;             // streamId 카운터
    int ftActive;
};

// rdpContext를 첫 멤버로 두는 커스텀 컨텍스트. engine 포인터를 콜백에서 참조.
typedef struct {
    rdpContext _ctx;
    RDPEngine *engine;
} engContext;

static void eng_status(RDPEngine *e, const char *s) {
    if (e->onStatus) e->onStatus(e->userdata, s);
}

static BOOL eng_end_paint(rdpContext *context) {
    engContext *c = (engContext *)context;
    RDPEngine *e = c->engine;
    rdpGdi *gdi = context->gdi;
    if (e->onFrame && gdi && gdi->primary_buffer) {
        e->onFrame(e->userdata, gdi->primary_buffer, gdi->width, gdi->height, (int)gdi->stride);
    }
    return TRUE;
}

// 서버가 데스크톱 해상도를 바꾸면(동적 해상도 응답) gdi 버퍼를 재할당한다.
// 이게 없으면 SendMonitorLayout으로 서버가 리사이즈해도 클라이언트 프레임이 옛 크기로 남는다.
static BOOL eng_desktop_resize(rdpContext *context) {
    UINT32 w = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopWidth);
    UINT32 h = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopHeight);
    if (!gdi_resize(context->gdi, w, h)) return FALSE;
    // 리사이즈 직후 현재 프레임을 콜백(즉시 새 크기 반영)
    engContext *c = (engContext *)context;
    RDPEngine *e = c->engine;
    rdpGdi *gdi = context->gdi;
    if (e->onFrame && gdi && gdi->primary_buffer)
        e->onFrame(e->userdata, gdi->primary_buffer, gdi->width, gdi->height, (int)gdi->stride);
    return TRUE;
}

static BOOL eng_post_connect(freerdp *instance) {
    if (!gdi_init(instance, PIXEL_FORMAT_BGRX32)) return FALSE;
    instance->context->update->EndPaint = eng_end_paint;
    instance->context->update->DesktopResize = eng_desktop_resize;
    engContext *c = (engContext *)instance->context;
    eng_status(c->engine, "연결됨 (렌더링)");
    return TRUE;
}

// FreeRDP 3.x 채널 로드 훅. 코어가 적절한 시점에 호출하고, 이후 채널을 연결한다.
static BOOL eng_load_channels(freerdp *instance) {
    rdpSettings *s = instance->context->settings;
    // 클립보드 채널은 RedirectClipboard(=featClipboard, eng_new_instance에서 설정)일 때만 추가.
    if (freerdp_settings_get_bool(s, FreeRDP_RedirectClipboard)) {
        const char *clipArgs[] = { "cliprdr" };
        freerdp_client_add_static_channel(s, 1, clipArgs);
    }
    // 오디오 재생(rdpsnd): load_addins의 자동 추가는 서브시스템 미지정이라 백엔드 자동 선택에
    // 맡겨진다. CoreAudio(sys:mac)를 명시해 무음(fake) 백엔드로 빠지지 않게 한다.
    if (freerdp_settings_get_bool(s, FreeRDP_AudioPlayback)) {
        const char *sndArgs[] = { "rdpsnd", "sys:mac" };
        freerdp_client_add_static_channel(s, 2, sndArgs);
    }
    // 마이크(audin)도 AVFoundation(sys:mac) 서브시스템을 명시.
    if (freerdp_settings_get_bool(s, FreeRDP_AudioCapture)) {
        const char *micArgs[] = { "audin", "sys:mac" };
        freerdp_client_add_dynamic_channel(s, 2, micArgs);
    }
    BOOL ok = freerdp_client_load_addins(instance->context->channels, s);
    return ok;
}

static BOOL eng_pre_connect(freerdp *instance) { (void)instance; return TRUE; }

static BOOL eng_authenticate(freerdp *instance, char **u, char **p, char **d, rdp_auth_reason reason) {
    (void)instance; (void)u; (void)p; (void)d; (void)reason; return TRUE;
}

static DWORD eng_verify_cert(freerdp *instance, const char *host, UINT16 port,
                             const char *cn, const char *subject, const char *issuer,
                             const char *fp, DWORD flags) {
    (void)instance; (void)host; (void)port; (void)cn;
    (void)subject; (void)issuer; (void)fp; (void)flags;
    return 1; // cert:ignore
}

#pragma mark - cliprdr (클립보드 채널)

static void eng_send_caps(CliprdrClientContext *clip) {
    CLIPRDR_GENERAL_CAPABILITY_SET general = { 0 };
    general.capabilitySetType = CB_CAPSTYPE_GENERAL;
    general.capabilitySetLength = 12;
    general.version = CB_CAPS_VERSION_2;
    // 파일 클립보드 지원 광고 → 서버가 파일 복사 시 FileGroupDescriptorW를 보냄.
    general.generalFlags = CB_USE_LONG_FORMAT_NAMES | CB_STREAM_FILECLIP_ENABLED |
                           CB_FILECLIP_NO_FILE_PATHS | CB_HUGE_FILE_SUPPORT_ENABLED;
    CLIPRDR_CAPABILITIES caps = { 0 };
    caps.cCapabilitiesSets = 1;
    caps.capabilitySets = (CLIPRDR_CAPABILITY_SET *)&general;
    if (clip->ClientCapabilities) clip->ClientCapabilities(clip, &caps);
}

static UINT eng_server_monitor_ready(CliprdrClientContext *clip, const CLIPRDR_MONITOR_READY *ready) {
    (void)ready;
    eng_send_caps(clip);
    CLIPRDR_FORMAT_LIST list = { 0 }; // 초기엔 빈 목록(로컬 클립보드 미공유)
    if (clip->ClientFormatList) clip->ClientFormatList(clip, &list);
    return CHANNEL_RC_OK;
}

// ── 원격→로컬 파일 전송(윈도우→Mac) ──

// 중첩 경로용 재귀 mkdir.
static void mkdir_p(const char *path) {
    char tmp[1300];
    strncpy(tmp, path, sizeof(tmp) - 1); tmp[sizeof(tmp) - 1] = 0;
    for (char *p = tmp + 1; *p; p++) {
        if (*p == '/') { *p = 0; mkdir(tmp, 0755); *p = '/'; }
    }
    mkdir(tmp, 0755);
}

// 전송 완료 → 최상위 항목(파일/폴더) 경로로 콜백(NSPasteboard에 올림).
static void ft_finish(RDPEngine *e) {
    e->ftActive = 0;
    const char *paths[FT_MAX_FILES];
    int n = 0;
    for (int i = 0; i < e->ftCount; i++) {
        if (e->ftFiles[i].fp) { fclose(e->ftFiles[i].fp); e->ftFiles[i].fp = NULL; }
        // 최상위 항목만 보고(폴더면 폴더째, 하위 파일은 폴더 안에 이미 생성됨)
        if (e->ftFiles[i].topLevel && e->ftFiles[i].path[0]) paths[n++] = e->ftFiles[i].path;
    }
    fprintf(stderr, "[cliprdr] 파일/폴더 %d개 수신 완료(%s)\n", n, e->ftDir);
    if (n > 0 && e->onRemoteFiles) e->onRemoteFiles(e->userdata, paths, n);
}

// 현재 파일의 다음 청크 요청. 끝나면 다음 파일로, 모두 끝나면 완료.
static void ft_pump(RDPEngine *e) {
    while (e->ftCur < e->ftCount) {
        ftFile *f = &e->ftFiles[e->ftCur];
        if (f->isDir || !f->fp || f->pos >= f->size) {
            if (f->fp) { fclose(f->fp); f->fp = NULL; }
            e->ftCur++;
            continue;
        }
        UINT32 chunk = (f->size - f->pos > FT_CHUNK) ? FT_CHUNK : (UINT32)(f->size - f->pos);
        e->ftStream++;
        CLIPRDR_FILE_CONTENTS_REQUEST req = { 0 };
        req.common.msgType = CB_FILECONTENTS_REQUEST;
        req.streamId = e->ftStream;
        req.listIndex = (UINT32)e->ftCur;
        req.dwFlags = FILECONTENTS_RANGE;
        req.nPositionLow = (UINT32)(f->pos & 0xFFFFFFFFu);
        req.nPositionHigh = (UINT32)(f->pos >> 32);
        req.cbRequested = chunk;
        if (e->clip->ClientFileContentsRequest)
            e->clip->ClientFileContentsRequest(e->clip, &req);
        return; // 응답 대기
    }
    ft_finish(e);
}

// FileGroupDescriptorW 파싱 → 임시폴더에 파일 생성 → 청크 요청 시작.
static void ft_start(RDPEngine *e, const BYTE *data, UINT32 len) {
    if (len < 4) return;
    UINT32 count = *(const UINT32 *)data;
    if (count == 0 || count > FT_MAX_FILES) return;
    if ((4u + (size_t)count * sizeof(FILEDESCRIPTORW)) > len) return;
    const FILEDESCRIPTORW *fds = (const FILEDESCRIPTORW *)(data + 4);

    snprintf(e->ftDir, sizeof(e->ftDir), "/tmp/MacSandboxClip-XXXXXX");
    if (!mkdtemp(e->ftDir)) return;

    e->ftCount = 0; e->ftCur = 0; e->ftActive = 1;
    for (UINT32 i = 0; i < count; i++) {
        ftFile *f = &e->ftFiles[e->ftCount];
        memset(f, 0, sizeof(*f));
        char *name = ConvertWCharNToUtf8Alloc(fds[i].cFileName, 260, NULL);
        if (!name || !name[0]) { free(name); name = strdup("file"); }
        for (char *p = name; *p; p++) if (*p == '\\') *p = '/';  // 게스트 '\' → posix '/'
        f->topLevel = (strchr(name, '/') == NULL);                // 최상위 항목 여부
        int isDir = (fds[i].dwFlags & FD_ATTRIBUTES) &&
                    (fds[i].dwFileAttributes & WIN_ATTR_DIRECTORY);
        f->isDir = isDir;
        f->size = ((uint64_t)fds[i].nFileSizeHigh << 32) | fds[i].nFileSizeLow;
        snprintf(f->path, sizeof(f->path), "%s/%s", e->ftDir, name);
        if (isDir) {
            mkdir_p(f->path);
        } else {
            // 부모 디렉토리 생성 후 파일 열기(중첩 경로 지원)
            char parent[1300];
            strncpy(parent, f->path, sizeof(parent) - 1); parent[sizeof(parent) - 1] = 0;
            char *slash = strrchr(parent, '/');
            if (slash) { *slash = 0; mkdir_p(parent); }
            f->fp = fopen(f->path, "wb");
        }
        free(name);
        e->ftCount++;
    }
    fprintf(stderr, "[cliprdr] 항목 %d개 수신 시작 → %s\n", e->ftCount, e->ftDir);
    ft_pump(e);
}

// 파일 청크 데이터 도착 → 임시파일에 기록 후 다음 청크.
static UINT eng_server_file_contents_response(CliprdrClientContext *clip,
                                              const CLIPRDR_FILE_CONTENTS_RESPONSE *resp) {
    RDPEngine *e = (RDPEngine *)clip->custom;
    if (!e->ftActive) return CHANNEL_RC_OK;
    ftFile *f = (e->ftCur < e->ftCount) ? &e->ftFiles[e->ftCur] : NULL;
    if (!(resp->common.msgFlags & CB_RESPONSE_OK)) {
        if (f && f->fp) { fclose(f->fp); f->fp = NULL; }
        e->ftCur++;
    } else if (f && f->fp && resp->requestedData && resp->cbRequested > 0) {
        fwrite(resp->requestedData, 1, resp->cbRequested, f->fp);
        f->pos += resp->cbRequested;
    }
    ft_pump(e);
    return CHANNEL_RC_OK;
}

// ── 포맷 목록/데이터 응답 ──

// 원격 클립보드 변경 시 포맷 목록 도착. 파일이 있으면 파일 우선, 없으면 텍스트를 요청.
static UINT eng_server_format_list(CliprdrClientContext *clip, const CLIPRDR_FORMAT_LIST *list) {
    RDPEngine *e = (RDPEngine *)clip->custom;
    int hasText = 0;
    UINT32 fileFmt = 0;
    for (UINT32 i = 0; i < list->numFormats; i++) {
        const CLIPRDR_FORMAT *fmt = &list->formats[i];
        if (fmt->formatId == CF_UNICODETEXT) hasText = 1;
        if (fmt->formatName && strcmp(fmt->formatName, "FileGroupDescriptorW") == 0)
            fileFmt = fmt->formatId;
    }
    e->fileFormatId = fileFmt;

    CLIPRDR_FORMAT_LIST_RESPONSE resp = { 0 };
    resp.common.msgType = CB_FORMAT_LIST_RESPONSE;
    resp.common.msgFlags = CB_RESPONSE_OK;
    if (clip->ClientFormatListResponse) clip->ClientFormatListResponse(clip, &resp);

    if (fileFmt && clip->ClientFormatDataRequest) {
        e->pendingFormatId = fileFmt;
        CLIPRDR_FORMAT_DATA_REQUEST req = { 0 };
        req.common.msgType = CB_FORMAT_DATA_REQUEST;
        req.requestedFormatId = fileFmt;
        clip->ClientFormatDataRequest(clip, &req);
    } else if (hasText && clip->ClientFormatDataRequest) {
        e->pendingFormatId = CF_UNICODETEXT;
        CLIPRDR_FORMAT_DATA_REQUEST req = { 0 };
        req.common.msgType = CB_FORMAT_DATA_REQUEST;
        req.requestedFormatId = CF_UNICODETEXT;
        clip->ClientFormatDataRequest(clip, &req);
    }
    return CHANNEL_RC_OK;
}

// 데이터 응답: 파일 디스크립터(→파일 전송 시작) 또는 텍스트(→NSPasteboard).
static UINT eng_server_format_data_response(CliprdrClientContext *clip,
                                            const CLIPRDR_FORMAT_DATA_RESPONSE *resp) {
    RDPEngine *e = (RDPEngine *)clip->custom;
    if (!(resp->common.msgFlags & CB_RESPONSE_OK) || !resp->requestedFormatData)
        return CHANNEL_RC_OK;

    if (e->fileFormatId && e->pendingFormatId == e->fileFormatId) {
        ft_start(e, resp->requestedFormatData, resp->common.dataLen);
        return CHANNEL_RC_OK;
    }
    if (resp->common.dataLen >= 2) { // 텍스트
        size_t wlen = resp->common.dataLen / sizeof(WCHAR);
        char *utf8 = ConvertWCharNToUtf8Alloc((const WCHAR *)resp->requestedFormatData, wlen, NULL);
        if (utf8) {
            if (e->onRemoteText) e->onRemoteText(e->userdata, utf8);
            free(utf8);
        }
    }
    return CHANNEL_RC_OK;
}

static const char *base_name(const char *p) {
    const char *s = strrchr(p, '/');
    return s ? s + 1 : p;
}

// 로컬 항목들로 FILEGROUPDESCRIPTORW(count + FILEDESCRIPTORW[]) 빌드 → 응답(폴더/중첩 포함).
static void eng_respond_file_descriptor(RDPEngine *e, CliprdrClientContext *clip) {
    pthread_mutex_lock(&e->clipLock);
    int n = e->localItemCount;
    size_t sz = 4 + (size_t)n * sizeof(FILEDESCRIPTORW);
    BYTE *buf = calloc(1, sz ? sz : 4);
    if (buf) {
        *(UINT32 *)buf = (UINT32)n;
        FILEDESCRIPTORW *fds = (FILEDESCRIPTORW *)(buf + 4);
        for (int i = 0; i < n; i++) {
            localItem *it = &e->localItems[i];
            if (it->isDir) {
                fds[i].dwFlags = FD_ATTRIBUTES;
                fds[i].dwFileAttributes = WIN_ATTR_DIRECTORY;
            } else {
                fds[i].dwFlags = FD_ATTRIBUTES | FD_FILESIZE | FD_PROGRESSUI;
                fds[i].dwFileAttributes = WIN_ATTR_NORMAL;
                fds[i].nFileSizeLow = (UINT32)(it->size & 0xFFFFFFFFu);
                fds[i].nFileSizeHigh = (UINT32)(it->size >> 32);
            }
            size_t wl = 0;
            WCHAR *w = ConvertUtf8ToWCharAlloc(it->rel, &wl); // '\' 구분 상대경로
            if (w) { for (size_t k = 0; k < wl && k < 259; k++) fds[i].cFileName[k] = w[k]; free(w); }
        }
    }
    pthread_mutex_unlock(&e->clipLock);

    CLIPRDR_FORMAT_DATA_RESPONSE resp = { 0 };
    resp.common.msgType = CB_FORMAT_DATA_RESPONSE;
    resp.common.msgFlags = buf ? CB_RESPONSE_OK : CB_RESPONSE_FAIL;
    resp.common.dataLen = buf ? (UINT32)sz : 0;
    resp.requestedFormatData = buf;
    if (clip->ClientFormatDataResponse) clip->ClientFormatDataResponse(clip, &resp);
    free(buf);
}

// 게스트가 우리(로컬) 클립보드 데이터를 요청(local→remote) → 파일 디스크립터 또는 텍스트로 응답.
static UINT eng_server_format_data_request(CliprdrClientContext *clip,
                                           const CLIPRDR_FORMAT_DATA_REQUEST *req) {
    RDPEngine *e = (RDPEngine *)clip->custom;
    if (req->requestedFormatId == FMT_FILEDESCRIPTORW) {
        eng_respond_file_descriptor(e, clip);
        return CHANNEL_RC_OK;
    }

    WCHAR *w = NULL;
    size_t wlen = 0;
    pthread_mutex_lock(&e->clipLock);
    if (req->requestedFormatId == CF_UNICODETEXT && e->localText) {
        w = ConvertUtf8ToWCharAlloc(e->localText, &wlen); // null 종료 포함
    }
    pthread_mutex_unlock(&e->clipLock);

    CLIPRDR_FORMAT_DATA_RESPONSE resp = { 0 };
    resp.common.msgType = CB_FORMAT_DATA_RESPONSE;
    if (w) {
        resp.common.msgFlags = CB_RESPONSE_OK;
        resp.common.dataLen = (UINT32)((wlen + 1) * sizeof(WCHAR));
        resp.requestedFormatData = (const BYTE *)w;
    } else {
        resp.common.msgFlags = CB_RESPONSE_FAIL;
    }
    if (clip->ClientFormatDataResponse) clip->ClientFormatDataResponse(clip, &resp);
    free(w);
    return CHANNEL_RC_OK;
}

// 게스트가 로컬 파일의 크기/바이트 범위를 요청(local→remote) → 로컬 파일에서 읽어 응답.
static UINT eng_server_file_contents_request(CliprdrClientContext *clip,
                                             const CLIPRDR_FILE_CONTENTS_REQUEST *req) {
    RDPEngine *e = (RDPEngine *)clip->custom;
    char path[1300] = { 0 };
    int isDir = 0;
    pthread_mutex_lock(&e->clipLock);
    if ((int)req->listIndex >= 0 && (int)req->listIndex < e->localItemCount) {
        strncpy(path, e->localItems[req->listIndex].local, sizeof(path) - 1);
        isDir = e->localItems[req->listIndex].isDir;
    }
    pthread_mutex_unlock(&e->clipLock);

    CLIPRDR_FILE_CONTENTS_RESPONSE resp = { 0 };
    resp.common.msgType = CB_FILECONTENTS_RESPONSE;
    resp.streamId = req->streamId;

    if (!path[0] || isDir) { // 폴더는 콘텐츠 없음(게스트가 디스크립터로 폴더 생성)
        resp.common.msgFlags = CB_RESPONSE_FAIL;
        if (clip->ClientFileContentsResponse) clip->ClientFileContentsResponse(clip, &resp);
        return CHANNEL_RC_OK;
    }

    if (req->dwFlags & FILECONTENTS_SIZE) {
        struct stat st;
        uint64_t size = (stat(path, &st) == 0) ? (uint64_t)st.st_size : 0;
        resp.common.msgFlags = CB_RESPONSE_OK;
        resp.cbRequested = sizeof(uint64_t);
        resp.requestedData = (const BYTE *)&size; // 호출 내에서 직렬화되므로 스택 유효
        if (clip->ClientFileContentsResponse) clip->ClientFileContentsResponse(clip, &resp);
    } else { // FILECONTENTS_RANGE
        FILE *f = fopen(path, "rb");
        uint64_t pos = ((uint64_t)req->nPositionHigh << 32) | req->nPositionLow;
        UINT32 want = req->cbRequested;
        BYTE *data = (want > 0) ? malloc(want) : NULL;
        size_t got = 0;
        if (f && data) { fseeko(f, (off_t)pos, SEEK_SET); got = fread(data, 1, want, f); }
        if (f) fclose(f);
        resp.common.msgFlags = data ? CB_RESPONSE_OK : CB_RESPONSE_FAIL;
        resp.cbRequested = (UINT32)got;
        resp.requestedData = data;
        if (clip->ClientFileContentsResponse) clip->ClientFileContentsResponse(clip, &resp);
        free(data);
    }
    return CHANNEL_RC_OK;
}

// 동적 해상도: 보관된 reqW/reqH(픽셀) + reqScale(DPI%)로 모니터 레이아웃을 전송.
static void eng_send_resize(RDPEngine *e) {
    if (!e->disp || !e->disp->SendMonitorLayout) return;
    int w = e->reqW, h = e->reqH, scale = e->reqScale;
    if (w <= 0 || h <= 0) return;
    if (w < 200) w = 200; if (w > 8192) w = 8192;   // RDP 제약 + 짝수
    if (h < 200) h = 200; if (h > 8192) h = 8192;
    w &= ~1; h &= ~1;
    if (scale < 100) scale = 100; if (scale > 500) scale = 500; // DesktopScaleFactor 범위
    DISPLAY_CONTROL_MONITOR_LAYOUT layout = { 0 };
    layout.Flags = DISPLAY_CONTROL_MONITOR_PRIMARY;
    layout.Width = (UINT32)w;
    layout.Height = (UINT32)h;
    layout.Orientation = 0;                       // landscape
    layout.DesktopScaleFactor = (UINT32)scale;    // 게스트 DPI 배율(Retina면 200)
    layout.DeviceScaleFactor = 100;               // {100,140,180}만 유효 → 100
    e->disp->SendMonitorLayout(e->disp, 1, &layout);
}

static void eng_channel_connected(void *context, const ChannelConnectedEventArgs *e) {
    RDPEngine *eng = ((engContext *)context)->engine;
    if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
        CliprdrClientContext *clip = (CliprdrClientContext *)e->pInterface;
        eng->clip = clip;
        clip->custom = eng;
        clip->MonitorReady = eng_server_monitor_ready;
        clip->ServerFormatList = eng_server_format_list;
        clip->ServerFormatDataResponse = eng_server_format_data_response;
        clip->ServerFormatDataRequest = eng_server_format_data_request;
        clip->ServerFileContentsResponse = eng_server_file_contents_response;
        clip->ServerFileContentsRequest = eng_server_file_contents_request;
        fprintf(stderr, "[cliprdr] 채널 연결됨\n");
    } else if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0) {
        eng->disp = (DispClientContext *)e->pInterface;
        if (eng->reqW > 0 && eng->reqH > 0) eng_send_resize(eng);
        fprintf(stderr, "[disp] 채널 연결됨\n");
    } else if (strcmp(e->name, RDPGFX_DVC_CHANNEL_NAME) == 0) {
        // Graphics Pipeline → gdi에 연결(서버 H.264/AVC444/progressive 인코딩 + 영역 갱신).
        eng->gfx = (RdpgfxClientContext *)e->pInterface;
        rdpGdi *gdi = ((rdpContext *)context)->gdi;
        if (gdi) gdi_graphics_pipeline_init(gdi, eng->gfx);
        fprintf(stderr, "[rdpgfx] 채널 연결됨\n");
    } else if (strcmp(e->name, "rdpsnd") == 0 || strcmp(e->name, "audin") == 0 ||
               strcmp(e->name, "rdpdr") == 0) {
        fprintf(stderr, "[%s] 채널 연결됨\n", e->name);  // 오디오/장치 채널 협상 진단용
    }
}

// 채널 해제 훅 — 그래픽 파이프라인 해제는 **반드시 여기서**(업스트림 클라이언트와 동일).
//
// eng_run 말미(disconnect 전)에 gdi_graphics_pipeline_uninit을 부르면, 아직 살아있는
// drdynvc 채널 스레드가 progressive 디코더(타일 스레드풀)를 돌리는 동안 타일 메모리를
// 해제해 UAF 크래시가 난다(progressive_rfx_decode_component, pc=0). disconnect가 채널을
// 정지시키는 과정에서 이 핸들러를 호출하므로, 이 시점엔 해당 채널의 디코딩이 끝나 있다.
static void eng_channel_disconnected(void *context, const ChannelDisconnectedEventArgs *e) {
    RDPEngine *eng = ((engContext *)context)->engine;
    if (strcmp(e->name, RDPGFX_DVC_CHANNEL_NAME) == 0) {
        rdpGdi *gdi = ((rdpContext *)context)->gdi;
        if (gdi && eng->gfx) gdi_graphics_pipeline_uninit(gdi, eng->gfx);
        eng->gfx = NULL;
        fprintf(stderr, "[rdpgfx] 채널 해제됨\n");
    } else if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
        // 메인 스레드 클립보드 광고가 해제된 채널 컨텍스트를 만지지 않게 NULL.
        pthread_mutex_lock(&eng->clipLock);
        eng->clip = NULL;
        pthread_mutex_unlock(&eng->clipLock);
    } else if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0) {
        eng->disp = NULL;   // 리사이즈 요청이 해제된 채널을 만지지 않게
    }
}

// 로컬 파일 클립보드 포맷 목록 전송(local→remote 광고: FileGroupDescriptorW + FileContents)
// clip 포인터는 채널 해제(eng_channel_disconnected)와 경합하지 않게 잠금 하에 읽는다.
static void eng_announce_local_files(RDPEngine *e) {
    pthread_mutex_lock(&e->clipLock);
    CliprdrClientContext *clip = e->clip;
    pthread_mutex_unlock(&e->clipLock);
    if (!clip || !clip->ClientFormatList) return;
    CLIPRDR_FORMAT fmts[2] = { 0 };
    fmts[0].formatId = FMT_FILEDESCRIPTORW; fmts[0].formatName = (char *)"FileGroupDescriptorW";
    fmts[1].formatId = FMT_FILECONTENTS;    fmts[1].formatName = (char *)"FileContents";
    CLIPRDR_FORMAT_LIST list = { 0 };
    list.common.msgType = CB_FORMAT_LIST;
    list.numFormats = 2;
    list.formats = fmts;
    clip->ClientFormatList(clip, &list);
}

// 로컬 클립보드 텍스트 포맷 목록 전송(local→remote 광고)
static void eng_announce_local_text(RDPEngine *e) {
    pthread_mutex_lock(&e->clipLock);
    CliprdrClientContext *clip = e->clip;
    pthread_mutex_unlock(&e->clipLock);
    if (!clip || !clip->ClientFormatList) return;
    CLIPRDR_FORMAT format = { 0 };
    format.formatId = CF_UNICODETEXT;
    format.formatName = NULL;
    CLIPRDR_FORMAT_LIST list = { 0 };
    list.common.msgType = CB_FORMAT_LIST;
    list.numFormats = 1;
    list.formats = &format;
    clip->ClientFormatList(clip, &list);
}

#pragma mark - 실행

// 인스턴스 생성 + 콜백/설정 구성(연결 직전 상태).
static freerdp *eng_new_instance(RDPEngine *e) {
    freerdp *instance = freerdp_new();
    if (!instance) return NULL;
    instance->ContextSize = sizeof(engContext);
    instance->PreConnect = eng_pre_connect;
    instance->PostConnect = eng_post_connect;
    instance->LoadChannels = eng_load_channels;
    instance->AuthenticateEx = eng_authenticate;
    instance->VerifyCertificateEx = eng_verify_cert;
    if (!freerdp_context_new(instance)) { freerdp_free(instance); return NULL; }
    ((engContext *)instance->context)->engine = e;
    PubSub_SubscribeChannelConnected(instance->context->pubSub, eng_channel_connected);
    PubSub_SubscribeChannelDisconnected(instance->context->pubSub, eng_channel_disconnected);

    rdpSettings *s = instance->context->settings;
    freerdp_settings_set_string(s, FreeRDP_ServerHostname, e->host);
    freerdp_settings_set_uint32(s, FreeRDP_ServerPort, (UINT32)e->port);
    freerdp_settings_set_string(s, FreeRDP_Username, e->user);
    freerdp_settings_set_string(s, FreeRDP_Password, e->pass ? e->pass : "");
    freerdp_settings_set_bool(s, FreeRDP_AutoLogonEnabled, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_IgnoreCertificate, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_TlsSecurity, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_NlaSecurity, FALSE);
    freerdp_settings_set_bool(s, FreeRDP_RdpSecurity, FALSE);
    freerdp_settings_set_bool(s, FreeRDP_UseRdpSecurityLayer, FALSE);
    freerdp_settings_set_uint32(s, FreeRDP_DesktopWidth, 1440);
    freerdp_settings_set_uint32(s, FreeRDP_DesktopHeight, 900);
    freerdp_settings_set_uint32(s, FreeRDP_ColorDepth, 32);
    // Graphics Pipeline(RDPGFX) — 서버가 H.264/AVC444/RemoteFX progressive로 인코딩 +
    // 변경 영역만 갱신 → 레거시 GDI보다 매끄럽다. gdi gfx 파이프라인은 채널 연결 시 연결.
    freerdp_settings_set_bool(s, FreeRDP_SupportGraphicsPipeline, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_GfxProgressive, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_GfxH264, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_GfxAVC444v2, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_RedirectClipboard, e->featClipboard ? TRUE : FALSE);
    freerdp_settings_set_bool(s, FreeRDP_SupportDisplayControl, TRUE); // 동적 해상도
    // 프린터 리다이렉션(.wsb PrinterRedirection): rdpdr + CUPS 백엔드(호스트 프린터→게스트).
    freerdp_settings_set_bool(s, FreeRDP_RedirectPrinters, e->featPrinter ? TRUE : FALSE);
    // 공유 폴더(.wsb MappedFolders): rdpdr drive 장치로 **지정 디렉토리만** 게스트에 노출.
    // RedirectDrives=TRUE는 핫플러그로 호스트 전체 볼륨까지 공유하므로 쓰지 않는다(보안).
    for (int i = 0; i < e->mappedCount; i++) {
        const char *args[] = { "drive", e->mapped[i].name, e->mapped[i].path };
        freerdp_client_add_device_channel(s, 3, args);
    }
    // 오디오 재생(게스트→호스트, 스피커): rdpsnd + macOS CoreAudio. .wsb엔 토글이 없어
    // 기본 켬(Windows Sandbox도 게스트 오디오를 항상 호스트로 재생). 옵션으로만 끈다.
    freerdp_settings_set_bool(s, FreeRDP_AudioPlayback, e->featSound ? TRUE : FALSE);
    // 마이크(호스트→게스트): audin + macOS AVFAudio. .wsb AudioInput으로 게이팅.
    // 최초 사용 시 macOS 마이크 권한 프롬프트(Info.plist NSMicrophoneUsageDescription).
    freerdp_settings_set_bool(s, FreeRDP_AudioCapture, e->featMic ? TRUE : FALSE);
    if (e->reqW > 0 && e->reqH > 0) { // 초기 해상도(창 크기)가 정해져 있으면 그걸로 연결
        freerdp_settings_set_uint32(s, FreeRDP_DesktopWidth, (UINT32)(e->reqW & ~1));
        freerdp_settings_set_uint32(s, FreeRDP_DesktopHeight, (UINT32)(e->reqH & ~1));
    }
    // 연결 시점 DPI 배율(세션 시작부터 적용). 디스플레이 배율(Retina=200)에 맞춰 UI 크기 보정.
    {
        UINT32 sc = (e->reqScale >= 100) ? (UINT32)e->reqScale : 200; // 기본 Retina 200%
        if (sc > 500) sc = 500;
        freerdp_settings_set_uint32(s, FreeRDP_DesktopScaleFactor, sc);
        freerdp_settings_set_uint32(s, FreeRDP_DeviceScaleFactor, 100);
    }
    // 클라이언트 키보드 식별 — 게스트의 세션 키보드 드라이버 선택 기준(한/영 키 매핑 등).
    // 예: 한국어 (8,3,0x412)면 게스트가 kbd101a를 골라 오른쪽 Alt가 한/영 전환이 된다.
    if (e->kbdType > 0)
        freerdp_settings_set_uint32(s, FreeRDP_KeyboardType, (UINT32)e->kbdType);
    if (e->kbdSubtype > 0)
        freerdp_settings_set_uint32(s, FreeRDP_KeyboardSubType, (UINT32)e->kbdSubtype);
    if (e->kbdLayout > 0)
        freerdp_settings_set_uint32(s, FreeRDP_KeyboardLayout, (UINT32)e->kbdLayout);
    // 채널(cliprdr/disp) 로드 + 구독은 PreConnect(eng_pre_connect)에서 처리.
    return instance;
}

static void eng_run(RDPEngine *e) {
    // 채널 addin은 별도 플러그인 dylib가 아니라 libfreerdp-client3에 정적 빌드돼 있다.
    // 정적 addin provider를 등록해야 cliprdr 등을 찾는다(기본 동적 로딩은 실패).
    freerdp_register_addin_provider(freerdp_channels_load_static_addin_entry, 0);

    // 연결 재시도 — 게스트 부팅 중(QEMU hostfwd는 즉시 수락하나 RDP 서버 미준비)에는
    // freerdp_connect가 빠르게 실패하므로, 게스트 RDP가 뜰 때까지 재시도한다.
    freerdp *instance = NULL;
    int connected = 0, attempt = 0;
    while (!e->stop) {
        instance = eng_new_instance(e);
        if (!instance) { eng_status(e, "초기화 실패"); return; }
        e->instance = instance;
        eng_status(e, attempt == 0 ? "연결 중..." : "게스트 RDP 대기...");
        if (freerdp_connect(instance)) { connected = 1; break; }
        // 실패 → 정리 후 잠시 뒤 재시도
        freerdp_context_free(instance);
        freerdp_free(instance);
        e->instance = NULL;
        attempt++;
        for (int i = 0; i < 20 && !e->stop; i++) usleep(100000); // ~2초
    }
    if (!connected) return;

    HANDLE handles[64];
    while (!e->stop && !freerdp_shall_disconnect_context(instance->context)) {
        DWORD n = freerdp_get_event_handles(instance->context, handles, 64);
        if (n == 0) break;
        DWORD w = WaitForMultipleObjects(n, handles, FALSE, 100);
        if (w == WAIT_FAILED) break;
        if (!freerdp_check_event_handles(instance->context)) break;
    }

    eng_status(e, "연결 종료");
    // 그래픽 파이프라인 해제는 disconnect 중 ChannelDisconnected(rdpgfx) 핸들러가 수행한다
    // (여기서 먼저 해제하면 진행 중인 progressive 타일 디코딩과 레이스 → UAF 크래시).
    freerdp_disconnect(instance);
    if (e->gfx) {   // 이벤트 미발화 폴백 — 이 시점엔 채널 스레드가 모두 정지된 상태
        if (instance->context->gdi)
            gdi_graphics_pipeline_uninit(instance->context->gdi, e->gfx);
        e->gfx = NULL;
    }
    freerdp_context_free(instance);
    freerdp_free(instance);
    e->instance = NULL;
}

static void *eng_thread_entry(void *arg) {
    eng_run((RDPEngine *)arg);
    return NULL;
}

RDPEngine *rdp_engine_create(const char *host, int port,
                             const char *username, const char *password,
                             RDPFrameCallback onFrame, RDPStatusCallback onStatus,
                             RDPClipboardTextCallback onRemoteText,
                             void *userdata) {
    RDPEngine *e = calloc(1, sizeof(RDPEngine));
    if (!e) return NULL;
    e->host = strdup(host ? host : "127.0.0.1");
    e->user = strdup(username ? username : "WDAGUtilityAccount");
    e->pass = strdup(password ? password : "");
    e->port = port;
    e->onFrame = onFrame;
    e->onStatus = onStatus;
    e->onRemoteText = onRemoteText;
    e->userdata = userdata;
    // 기본값: Windows Sandbox 표준(클립보드·마이크·스피커 on, 프린터 off). set_*로 덮어쓴다.
    e->featClipboard = 1;
    e->featMic = 1;
    e->featPrinter = 0;
    e->featSound = 1;
    pthread_mutex_init(&e->clipLock, NULL);
    return e;
}

void rdp_engine_set_audio_playback(RDPEngine *e, int playback) {
    if (e) e->featSound = playback ? 1 : 0;
}

void rdp_engine_set_keyboard(RDPEngine *e, int type, int subtype, int layout) {
    if (!e) return;
    e->kbdType = type;
    e->kbdSubtype = subtype;
    e->kbdLayout = layout;
}

void rdp_engine_send_sync_locks(RDPEngine *e, int capsLock, int numLock) {
    if (!e || !e->instance) return;
    UINT32 flags = 0;
    if (capsLock) flags |= KBD_SYNC_CAPS_LOCK;
    if (numLock) flags |= KBD_SYNC_NUM_LOCK;
    freerdp_input_send_synchronize_event(e->instance->context->input, flags);
}

// 리다이렉션 기능 게이팅(.wsb 반영). rdp_engine_start 전에 호출해야 한다.
void rdp_engine_set_features(RDPEngine *e, int clipboard, int mic, int printer) {
    if (!e) return;
    e->featClipboard = clipboard ? 1 : 0;
    e->featMic = mic ? 1 : 0;
    e->featPrinter = printer ? 1 : 0;
}

// 호스트 폴더 공유(.wsb MappedFolder). rdp_engine_start 전에 호출. readOnly는 FreeRDP drive가
// 미지원이라 읽기/쓰기로 공유된다(요청 시 경고만).
void rdp_engine_add_mapped_folder(RDPEngine *e, const char *hostPath, const char *name, int readOnly) {
    if (!e || !hostPath || !hostPath[0] || e->mappedCount >= 16) return;
    int i = e->mappedCount;
    snprintf(e->mapped[i].path, sizeof(e->mapped[i].path), "%s", hostPath);
    snprintf(e->mapped[i].name, sizeof(e->mapped[i].name), "%s",
             (name && name[0]) ? name : "share");
    e->mappedCount++;
    if (readOnly)
        fprintf(stderr, "[drive] '%s' 읽기전용 요청 — FreeRDP drive 미지원, 읽기/쓰기로 공유\n",
                e->mapped[i].name);
}

void rdp_engine_set_files_callback(RDPEngine *e, RDPClipboardFilesCallback cb) {
    if (e) e->onRemoteFiles = cb;
}

void rdp_engine_request_resize(RDPEngine *e, int width, int height, int scalePercent) {
    if (!e || width <= 0 || height <= 0) return;
    e->reqW = width; e->reqH = height;            // 연결 전이면 보관했다 disp 연결 시 전송
    e->reqScale = scalePercent > 0 ? scalePercent : 100;
    eng_send_resize(e);
}

void rdp_engine_set_local_clipboard_text(RDPEngine *e, const char *utf8) {
    if (!e) return;
    pthread_mutex_lock(&e->clipLock);
    free(e->localText);
    e->localText = utf8 ? strdup(utf8) : NULL;
    e->localItemCount = 0; // 텍스트로 바뀌면 로컬 파일 공유 해제
    pthread_mutex_unlock(&e->clipLock);
    eng_announce_local_text(e); // 게스트에 텍스트 포맷 보유를 광고
}

// 로컬 경로를 localItems에 추가(폴더면 재귀 전개). 호출자가 clipLock 보유.
static void ft_add_local(RDPEngine *e, const char *local, const char *rel) {
    if (e->localItemCount >= FT_MAX_FILES) return;
    struct stat st;
    if (stat(local, &st) != 0) return;
    int isDir = S_ISDIR(st.st_mode);
    localItem *it = &e->localItems[e->localItemCount++];
    strncpy(it->rel, rel, sizeof(it->rel) - 1);     it->rel[sizeof(it->rel) - 1] = 0;
    strncpy(it->local, local, sizeof(it->local) - 1); it->local[sizeof(it->local) - 1] = 0;
    it->isDir = isDir;
    it->size = isDir ? 0 : (uint64_t)st.st_size;
    if (isDir) {
        DIR *d = opendir(local);
        if (d) {
            struct dirent *de;
            while ((de = readdir(d)) != NULL) {
                if (strcmp(de->d_name, ".") == 0 || strcmp(de->d_name, "..") == 0) continue;
                char cl[1300], cr[600];
                snprintf(cl, sizeof(cl), "%s/%s", local, de->d_name);
                snprintf(cr, sizeof(cr), "%s\\%s", rel, de->d_name); // 게스트는 '\' 구분
                ft_add_local(e, cl, cr);
            }
            closedir(d);
        }
    }
}

void rdp_engine_set_local_clipboard_files(RDPEngine *e, const char *const *paths, int count) {
    if (!e) return;
    if (count < 0) count = 0;
    pthread_mutex_lock(&e->clipLock);
    e->localItemCount = 0;
    for (int i = 0; i < count; i++) {
        if (paths[i]) ft_add_local(e, paths[i], base_name(paths[i])); // 폴더 재귀 전개
    }
    free(e->localText); e->localText = NULL; // 파일로 바뀌면 로컬 텍스트 공유 해제
    pthread_mutex_unlock(&e->clipLock);
    eng_announce_local_files(e); // 게스트에 파일 포맷 보유를 광고
}

void rdp_engine_send_pointer(RDPEngine *e, uint16_t flags, int x, int y) {
    if (!e || !e->instance) return;
    freerdp_input_send_mouse_event(e->instance->context->input, flags, (UINT16)x, (UINT16)y);
}

void rdp_engine_send_mac_key(RDPEngine *e, uint16_t macKeyCode, int down) {
    if (!e || !e->instance) return;
    DWORD vk = GetVirtualKeyCodeFromKeycode(macKeyCode, WINPR_KEYCODE_TYPE_APPLE);
    DWORD sc = GetVirtualScanCodeFromVirtualKeyCode(vk, 4 /* enhanced keyboard */);
    if (sc == 0) return;
    UINT16 flags = down ? KBD_FLAGS_DOWN : KBD_FLAGS_RELEASE;
    if (RDP_SCANCODE_EXTENDED(sc)) flags |= KBD_FLAGS_EXTENDED;
    freerdp_input_send_keyboard_event(e->instance->context->input, flags,
                                      (UINT8)RDP_SCANCODE_CODE(sc));
}

void rdp_engine_start(RDPEngine *e) {
    if (!e || e->threadStarted) return;
    e->stop = 0;
    e->threadStarted = 1;
    pthread_create(&e->thread, NULL, eng_thread_entry, e);
}

void rdp_engine_stop(RDPEngine *e) {
    if (!e) return;
    e->stop = 1;
    if (e->instance) freerdp_abort_connect_context(e->instance->context);
}

void rdp_engine_free(RDPEngine *e) {
    if (!e) return;
    rdp_engine_stop(e);
    if (e->threadStarted) pthread_join(e->thread, NULL);
    pthread_mutex_destroy(&e->clipLock);
    free(e->localText);
    free(e->host); free(e->user); free(e->pass);
    free(e);
}
