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

// freerdp 3.x headers declare deprecated members (pVerifyCertificate etc.) in structs, so just including
// them triggers -Wdeprecated-declarations warnings. Suppress only the header noise (keep our own code warnings) and pop.
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

// Format IDs advertised for the local→remote (Mac→Windows) file clipboard (LONG_FORMAT_NAMES, so the server maps by name).
#define FMT_FILEDESCRIPTORW 0xC100
#define FMT_FILECONTENTS    0xC101
#define WIN_ATTR_DIRECTORY  0x10
#define WIN_ATTR_NORMAL     0x80

#define FT_MAX_FILES 1024
#define FT_CHUNK 1048576  // 1MB chunk

// Remote→local file transfer state (Windows→Mac). Subfolders are created as nested paths.
typedef struct {
    char path[1300];   // temp file path (nesting included)
    uint64_t size;
    uint64_t pos;
    FILE *fp;
    int isDir;
    int topLevel;      // directly under ftDir (reported as a paste target)
} ftFile;

// A local→remote (Mac→Windows) shared item. Folders are recursively expanded into a flat list.
typedef struct {
    char rel[600];     // relative path as the guest sees it ('\' separated, e.g. "folder\\sub\\a.txt")
    char local[1300];  // actual host absolute path
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

    CliprdrClientContext *clip;  // clipboard channel context (filled in on connect)
    pthread_mutex_t clipLock;
    char *localText;             // local clipboard text for host→guest sharing (UTF8)
    localItem localItems[FT_MAX_FILES]; // host→guest shared items (folders recursively expanded)
    int localItemCount;

    DispClientContext *disp;     // Display Control channel (dynamic resolution). Filled in on connect
    int reqW, reqH, reqScale;    // pending requested resolution/DPI scale (stored if requested before the channel connects)
    RdpgfxClientContext *gfx;    // Graphics Pipeline (RDPGFX) channel. Connected to gdi on connect
    int featClipboard;           // clipboard redirection on/off (.wsb ClipboardRedirection)
    int featMic;                 // mic capture on/off (.wsb AudioInput). Speaker playback is always on.
    int featPrinter;             // printer redirection on/off (.wsb PrinterRedirection)
    int featSound;               // audio playback (rdpsnd) on/off — default on (turned off via option)
    int kbdType, kbdSubtype, kbdLayout; // client keyboard identity (0 = FreeRDP default)
    struct { char path[2048]; char name[256]; } mapped[16]; // shared folders (.wsb MappedFolders)
    int mappedCount;

    UINT32 fileFormatId;         // the "FileGroupDescriptorW" format ID announced by the server (0=none)
    UINT32 pendingFormatId;      // the format of the last ClientFormatDataRequest (to distinguish responses)
    char ftDir[1100];            // temp directory for received files
    ftFile ftFiles[FT_MAX_FILES];
    int ftCount;
    int ftCur;                   // index of the file currently being received
    UINT32 ftStream;             // streamId counter
    int ftActive;
};

// Custom context with rdpContext as the first member. References the engine pointer from callbacks.
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

// When the server changes the desktop resolution (dynamic resolution response), reallocate the gdi buffer.
// Without this, even if the server resizes via SendMonitorLayout, the client frame stays at the old size.
static BOOL eng_desktop_resize(rdpContext *context) {
    UINT32 w = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopWidth);
    UINT32 h = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopHeight);
    if (!gdi_resize(context->gdi, w, h)) return FALSE;
    // right after resizing, callback the current frame (reflect the new size immediately)
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
    eng_status(c->engine, "Connected (rendering)");
    return TRUE;
}

// FreeRDP 3.x channel load hook. The core calls it at the appropriate time, then the channels are connected.
static BOOL eng_load_channels(freerdp *instance) {
    rdpSettings *s = instance->context->settings;
    // The clipboard channel is added only when RedirectClipboard (= featClipboard, set in eng_new_instance) is on.
    if (freerdp_settings_get_bool(s, FreeRDP_RedirectClipboard)) {
        const char *clipArgs[] = { "cliprdr" };
        freerdp_client_add_static_channel(s, 1, clipArgs);
    }
    // Audio playback (rdpsnd): load_addins' automatic addition leaves the backend to automatic selection
    // since no subsystem is specified. Specify CoreAudio (sys:mac) so it doesn't fall back to a silent (fake) backend.
    if (freerdp_settings_get_bool(s, FreeRDP_AudioPlayback)) {
        const char *sndArgs[] = { "rdpsnd", "sys:mac" };
        freerdp_client_add_static_channel(s, 2, sndArgs);
    }
    // Mic (audin) also specifies the AVFoundation (sys:mac) subsystem.
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

#pragma mark - cliprdr (clipboard channel)

static void eng_send_caps(CliprdrClientContext *clip) {
    CLIPRDR_GENERAL_CAPABILITY_SET general = { 0 };
    general.capabilitySetType = CB_CAPSTYPE_GENERAL;
    general.capabilitySetLength = 12;
    general.version = CB_CAPS_VERSION_2;
    // advertise file clipboard support → the server sends FileGroupDescriptorW when files are copied.
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
    CLIPRDR_FORMAT_LIST list = { 0 }; // initially an empty list (local clipboard not shared)
    if (clip->ClientFormatList) clip->ClientFormatList(clip, &list);
    return CHANNEL_RC_OK;
}

// ── remote→local file transfer (Windows→Mac) ──

// recursive mkdir for nested paths.
static void mkdir_p(const char *path) {
    char tmp[1300];
    strncpy(tmp, path, sizeof(tmp) - 1); tmp[sizeof(tmp) - 1] = 0;
    for (char *p = tmp + 1; *p; p++) {
        if (*p == '/') { *p = 0; mkdir(tmp, 0755); *p = '/'; }
    }
    mkdir(tmp, 0755);
}

// transfer complete → callback with top-level item (file/folder) paths (placed on NSPasteboard).
static void ft_finish(RDPEngine *e) {
    e->ftActive = 0;
    const char *paths[FT_MAX_FILES];
    int n = 0;
    for (int i = 0; i < e->ftCount; i++) {
        if (e->ftFiles[i].fp) { fclose(e->ftFiles[i].fp); e->ftFiles[i].fp = NULL; }
        // report only top-level items (folders whole; nested files are already created inside the folder)
        if (e->ftFiles[i].topLevel && e->ftFiles[i].path[0]) paths[n++] = e->ftFiles[i].path;
    }
    fprintf(stderr, "[cliprdr] received %d file(s)/folder(s) (%s)\n", n, e->ftDir);
    if (n > 0 && e->onRemoteFiles) e->onRemoteFiles(e->userdata, paths, n);
}

// request the next chunk of the current file. When it ends, move to the next file; when all end, finish.
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
        return; // wait for response
    }
    ft_finish(e);
}

// parse FileGroupDescriptorW → create files in the temp folder → start requesting chunks.
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
        for (char *p = name; *p; p++) if (*p == '\\') *p = '/';  // guest '\' → posix '/'
        f->topLevel = (strchr(name, '/') == NULL);                // whether it is a top-level item
        int isDir = (fds[i].dwFlags & FD_ATTRIBUTES) &&
                    (fds[i].dwFileAttributes & WIN_ATTR_DIRECTORY);
        f->isDir = isDir;
        f->size = ((uint64_t)fds[i].nFileSizeHigh << 32) | fds[i].nFileSizeLow;
        snprintf(f->path, sizeof(f->path), "%s/%s", e->ftDir, name);
        if (isDir) {
            mkdir_p(f->path);
        } else {
            // create the parent directory then open the file (supports nested paths)
            char parent[1300];
            strncpy(parent, f->path, sizeof(parent) - 1); parent[sizeof(parent) - 1] = 0;
            char *slash = strrchr(parent, '/');
            if (slash) { *slash = 0; mkdir_p(parent); }
            f->fp = fopen(f->path, "wb");
        }
        free(name);
        e->ftCount++;
    }
    fprintf(stderr, "[cliprdr] starting to receive %d item(s) → %s\n", e->ftCount, e->ftDir);
    ft_pump(e);
}

// file chunk data arrives → write to the temp file then the next chunk.
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

// ── format list/data response ──

// When the remote clipboard changes, the format list arrives. If there are files, files first; otherwise request text.
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

// data response: file descriptor (→start file transfer) or text (→NSPasteboard).
static UINT eng_server_format_data_response(CliprdrClientContext *clip,
                                            const CLIPRDR_FORMAT_DATA_RESPONSE *resp) {
    RDPEngine *e = (RDPEngine *)clip->custom;
    if (!(resp->common.msgFlags & CB_RESPONSE_OK) || !resp->requestedFormatData)
        return CHANNEL_RC_OK;

    if (e->fileFormatId && e->pendingFormatId == e->fileFormatId) {
        ft_start(e, resp->requestedFormatData, resp->common.dataLen);
        return CHANNEL_RC_OK;
    }
    if (resp->common.dataLen >= 2) { // text
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

// build a FILEGROUPDESCRIPTORW (count + FILEDESCRIPTORW[]) from the local items → respond (folders/nesting included).
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
            WCHAR *w = ConvertUtf8ToWCharAlloc(it->rel, &wl); // '\' separated relative path
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

// the guest requests our (local) clipboard data (local→remote) → respond with file descriptor or text.
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
        w = ConvertUtf8ToWCharAlloc(e->localText, &wlen); // null terminator included
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

// the guest requests a local file's size/byte range (local→remote) → read from the local file and respond.
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

    if (!path[0] || isDir) { // folders have no contents (the guest creates the folder from the descriptor)
        resp.common.msgFlags = CB_RESPONSE_FAIL;
        if (clip->ClientFileContentsResponse) clip->ClientFileContentsResponse(clip, &resp);
        return CHANNEL_RC_OK;
    }

    if (req->dwFlags & FILECONTENTS_SIZE) {
        struct stat st;
        uint64_t size = (stat(path, &st) == 0) ? (uint64_t)st.st_size : 0;
        resp.common.msgFlags = CB_RESPONSE_OK;
        resp.cbRequested = sizeof(uint64_t);
        resp.requestedData = (const BYTE *)&size; // serialized within the call, so the stack value is valid
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

// Dynamic resolution: send the monitor layout using the stored reqW/reqH (pixels) + reqScale (DPI%).
static void eng_send_resize(RDPEngine *e) {
    if (!e->disp || !e->disp->SendMonitorLayout) return;
    int w = e->reqW, h = e->reqH, scale = e->reqScale;
    if (w <= 0 || h <= 0) return;
    if (w < 200) w = 200; if (w > 8192) w = 8192;   // RDP constraints + even
    if (h < 200) h = 200; if (h > 8192) h = 8192;
    w &= ~1; h &= ~1;
    if (scale < 100) scale = 100; if (scale > 500) scale = 500; // DesktopScaleFactor range
    DISPLAY_CONTROL_MONITOR_LAYOUT layout = { 0 };
    layout.Flags = DISPLAY_CONTROL_MONITOR_PRIMARY;
    layout.Width = (UINT32)w;
    layout.Height = (UINT32)h;
    layout.Orientation = 0;                       // landscape
    layout.DesktopScaleFactor = (UINT32)scale;    // guest DPI scale (200 on Retina)
    layout.DeviceScaleFactor = 100;               // only {100,140,180} are valid → 100
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
        fprintf(stderr, "[cliprdr] channel connected\n");
    } else if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0) {
        eng->disp = (DispClientContext *)e->pInterface;
        if (eng->reqW > 0 && eng->reqH > 0) eng_send_resize(eng);
        fprintf(stderr, "[disp] channel connected\n");
    } else if (strcmp(e->name, RDPGFX_DVC_CHANNEL_NAME) == 0) {
        // Graphics Pipeline → connect to gdi (server H.264/AVC444/progressive encoding + region updates).
        eng->gfx = (RdpgfxClientContext *)e->pInterface;
        rdpGdi *gdi = ((rdpContext *)context)->gdi;
        if (gdi) gdi_graphics_pipeline_init(gdi, eng->gfx);
        fprintf(stderr, "[rdpgfx] channel connected\n");
    } else if (strcmp(e->name, "rdpsnd") == 0 || strcmp(e->name, "audin") == 0 ||
               strcmp(e->name, "rdpdr") == 0) {
        fprintf(stderr, "[%s] channel connected\n", e->name);  // for diagnosing audio/device channel negotiation
    }
}

// Channel disconnect hook — graphics pipeline teardown **must happen here** (same as the upstream client).
//
// Calling gdi_graphics_pipeline_uninit at the end of eng_run (before disconnect) frees tile memory while
// the still-alive drdynvc channel thread is running the progressive decoder (tile thread pool), causing
// a UAF crash (progressive_rfx_decode_component, pc=0). disconnect calls this handler while stopping the
// channel, so by this point that channel's decoding has finished.
static void eng_channel_disconnected(void *context, const ChannelDisconnectedEventArgs *e) {
    RDPEngine *eng = ((engContext *)context)->engine;
    if (strcmp(e->name, RDPGFX_DVC_CHANNEL_NAME) == 0) {
        rdpGdi *gdi = ((rdpContext *)context)->gdi;
        if (gdi && eng->gfx) gdi_graphics_pipeline_uninit(gdi, eng->gfx);
        eng->gfx = NULL;
        fprintf(stderr, "[rdpgfx] channel disconnected\n");
    } else if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
        // NULL it so a main-thread clipboard advertisement doesn't touch the freed channel context.
        pthread_mutex_lock(&eng->clipLock);
        eng->clip = NULL;
        pthread_mutex_unlock(&eng->clipLock);
    } else if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0) {
        eng->disp = NULL;   // so a resize request doesn't touch the freed channel
    }
}

// Send the local file clipboard format list (local→remote advertisement: FileGroupDescriptorW + FileContents).
// The clip pointer is read under lock so it doesn't race with channel disconnect (eng_channel_disconnected).
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

// Send the local clipboard text format list (local→remote advertisement)
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

#pragma mark - Execution

// Create the instance + configure callbacks/settings (state just before connecting).
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
    // Graphics Pipeline (RDPGFX) — the server encodes with H.264/AVC444/RemoteFX progressive +
    // updates only changed regions → smoother than legacy GDI. The gdi gfx pipeline is connected on channel connect.
    freerdp_settings_set_bool(s, FreeRDP_SupportGraphicsPipeline, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_GfxProgressive, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_GfxH264, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_GfxAVC444v2, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_RedirectClipboard, e->featClipboard ? TRUE : FALSE);
    freerdp_settings_set_bool(s, FreeRDP_SupportDisplayControl, TRUE); // dynamic resolution
    // Printer redirection (.wsb PrinterRedirection): rdpdr + CUPS backend (host printer→guest).
    freerdp_settings_set_bool(s, FreeRDP_RedirectPrinters, e->featPrinter ? TRUE : FALSE);
    // Shared folders (.wsb MappedFolders): expose **only the specified directories** to the guest as rdpdr drive devices.
    // RedirectDrives=TRUE would also share entire host volumes via hot-plug, so it is not used (security).
    for (int i = 0; i < e->mappedCount; i++) {
        const char *args[] = { "drive", e->mapped[i].name, e->mapped[i].path };
        freerdp_client_add_device_channel(s, 3, args);
    }
    // Audio playback (guest→host, speaker): rdpsnd + macOS CoreAudio. .wsb has no toggle, so it is
    // on by default (Windows Sandbox also always plays guest audio to the host). Only turned off via option.
    freerdp_settings_set_bool(s, FreeRDP_AudioPlayback, e->featSound ? TRUE : FALSE);
    // Mic (host→guest): audin + macOS AVFAudio. Gated by .wsb AudioInput.
    // On first use, a macOS microphone permission prompt (Info.plist NSMicrophoneUsageDescription).
    freerdp_settings_set_bool(s, FreeRDP_AudioCapture, e->featMic ? TRUE : FALSE);
    if (e->reqW > 0 && e->reqH > 0) { // if an initial resolution (window size) is set, connect with it
        freerdp_settings_set_uint32(s, FreeRDP_DesktopWidth, (UINT32)(e->reqW & ~1));
        freerdp_settings_set_uint32(s, FreeRDP_DesktopHeight, (UINT32)(e->reqH & ~1));
    }
    // DPI scale at connect time (applied from session start). Adjusts UI size to match the display scale (Retina=200).
    {
        UINT32 sc = (e->reqScale >= 100) ? (UINT32)e->reqScale : 200; // default Retina 200%
        if (sc > 500) sc = 500;
        freerdp_settings_set_uint32(s, FreeRDP_DesktopScaleFactor, sc);
        freerdp_settings_set_uint32(s, FreeRDP_DeviceScaleFactor, 100);
    }
    // Client keyboard identity — the basis for the guest's session keyboard driver selection (한/영 key mapping etc.).
    // e.g. for Korean (8,3,0x412) the guest picks kbd101a so right Alt becomes the 한/영 toggle.
    if (e->kbdType > 0)
        freerdp_settings_set_uint32(s, FreeRDP_KeyboardType, (UINT32)e->kbdType);
    if (e->kbdSubtype > 0)
        freerdp_settings_set_uint32(s, FreeRDP_KeyboardSubType, (UINT32)e->kbdSubtype);
    if (e->kbdLayout > 0)
        freerdp_settings_set_uint32(s, FreeRDP_KeyboardLayout, (UINT32)e->kbdLayout);
    // Channel (cliprdr/disp) load + subscribe is handled in PreConnect (eng_pre_connect).
    return instance;
}

static void eng_run(RDPEngine *e) {
    // The channel addins are statically built into libfreerdp-client3, not separate plugin dylibs.
    // The static addin provider must be registered to find cliprdr etc. (default dynamic loading fails).
    freerdp_register_addin_provider(freerdp_channels_load_static_addin_entry, 0);

    // Connection retry — while the guest is booting (QEMU hostfwd accepts immediately but the RDP server isn't ready),
    // freerdp_connect fails quickly, so retry until the guest RDP comes up.
    freerdp *instance = NULL;
    int connected = 0, attempt = 0;
    while (!e->stop) {
        instance = eng_new_instance(e);
        if (!instance) { eng_status(e, "Initialization failed"); return; }
        e->instance = instance;
        eng_status(e, attempt == 0 ? "Connecting..." : "Waiting for guest RDP...");
        if (freerdp_connect(instance)) { connected = 1; break; }
        // failure → clean up then retry after a short delay
        freerdp_context_free(instance);
        freerdp_free(instance);
        e->instance = NULL;
        attempt++;
        for (int i = 0; i < 20 && !e->stop; i++) usleep(100000); // ~2 seconds
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

    eng_status(e, "Connection closed");
    // Graphics pipeline teardown is performed by the ChannelDisconnected (rdpgfx) handler during disconnect
    // (freeing it first here would race with in-progress progressive tile decoding → UAF crash).
    freerdp_disconnect(instance);
    if (e->gfx) {   // fallback if the event didn't fire — by this point all channel threads are stopped
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
    // Defaults: Windows Sandbox standard (clipboard·mic·speaker on, printer off). Overridden via set_*.
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

// Gate redirection features (reflecting .wsb). Must be called before rdp_engine_start.
void rdp_engine_set_features(RDPEngine *e, int clipboard, int mic, int printer) {
    if (!e) return;
    e->featClipboard = clipboard ? 1 : 0;
    e->featMic = mic ? 1 : 0;
    e->featPrinter = printer ? 1 : 0;
}

// Share a host folder (.wsb MappedFolder). Call before rdp_engine_start. readOnly is unsupported by FreeRDP drive,
// so it is shared read/write (only a warning when requested).
void rdp_engine_add_mapped_folder(RDPEngine *e, const char *hostPath, const char *name, int readOnly) {
    if (!e || !hostPath || !hostPath[0] || e->mappedCount >= 16) return;
    int i = e->mappedCount;
    snprintf(e->mapped[i].path, sizeof(e->mapped[i].path), "%s", hostPath);
    snprintf(e->mapped[i].name, sizeof(e->mapped[i].name), "%s",
             (name && name[0]) ? name : "share");
    e->mappedCount++;
    if (readOnly)
        fprintf(stderr, "[drive] '%s' read-only requested — unsupported by FreeRDP drive, shared read/write\n",
                e->mapped[i].name);
}

void rdp_engine_set_files_callback(RDPEngine *e, RDPClipboardFilesCallback cb) {
    if (e) e->onRemoteFiles = cb;
}

void rdp_engine_request_resize(RDPEngine *e, int width, int height, int scalePercent) {
    if (!e || width <= 0 || height <= 0) return;
    e->reqW = width; e->reqH = height;            // if before connecting, store it and send on disp connect
    e->reqScale = scalePercent > 0 ? scalePercent : 100;
    eng_send_resize(e);
}

void rdp_engine_set_local_clipboard_text(RDPEngine *e, const char *utf8) {
    if (!e) return;
    pthread_mutex_lock(&e->clipLock);
    free(e->localText);
    e->localText = utf8 ? strdup(utf8) : NULL;
    e->localItemCount = 0; // switching to text releases local file sharing
    pthread_mutex_unlock(&e->clipLock);
    eng_announce_local_text(e); // advertise to the guest that we hold a text format
}

// Add a local path to localItems (recursively expand if a folder). The caller holds clipLock.
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
                snprintf(cr, sizeof(cr), "%s\\%s", rel, de->d_name); // the guest uses '\' separators
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
        if (paths[i]) ft_add_local(e, paths[i], base_name(paths[i])); // recursively expand folders
    }
    free(e->localText); e->localText = NULL; // switching to files releases local text sharing
    pthread_mutex_unlock(&e->clipLock);
    eng_announce_local_files(e); // advertise to the guest that we hold a file format
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
