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

#include <freerdp/freerdp.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/codec/color.h>
#include <freerdp/settings.h>
#include <winpr/synch.h>

#include <stdio.h>
#include <string.h>

// rdpContext를 첫 멤버로 두는 커스텀 컨텍스트 (libfreerdp 관례).
typedef struct {
    rdpContext _ctx;
    const char *outpath;
    int paints;
} cfCaptureContext;

static void cf_write_ppm(rdpGdi *gdi, const char *outpath) {
    if (!gdi || !gdi->primary_buffer || !outpath) return;
    FILE *f = fopen(outpath, "wb");
    if (!f) return;
    int w = gdi->width, h = gdi->height;
    fprintf(f, "P6\n%d %d\n255\n", w, h);
    for (int y = 0; y < h; y++) {
        const BYTE *row = gdi->primary_buffer + (size_t)y * gdi->stride;
        for (int x = 0; x < w; x++) {
            const BYTE *px = row + (size_t)x * 4; // BGRX32
            fputc(px[2], f); // R
            fputc(px[1], f); // G
            fputc(px[0], f); // B
        }
    }
    fclose(f);
}

static BOOL cf_end_paint(rdpContext *context) {
    cfCaptureContext *cf = (cfCaptureContext *)context;
    cf->paints++;
    return TRUE;
}

static BOOL cf_post_connect(freerdp *instance) {
    if (!gdi_init(instance, PIXEL_FORMAT_BGRX32))
        return FALSE;
    instance->context->update->EndPaint = cf_end_paint;
    return TRUE;
}

static BOOL cf_pre_connect(freerdp *instance) {
    (void)instance;
    return TRUE;
}

static BOOL cf_authenticate(freerdp *instance, char **user, char **pass, char **domain) {
    (void)instance; (void)user; (void)pass; (void)domain;
    return TRUE; // settings의 자격증명 사용
}

static DWORD cf_verify_cert(freerdp *instance, const char *host, UINT16 port,
                            const char *common_name, const char *subject,
                            const char *issuer, const char *fingerprint, DWORD flags) {
    (void)instance; (void)host; (void)port; (void)common_name;
    (void)subject; (void)issuer; (void)fingerprint; (void)flags;
    return 1; // 인증서 무조건 수락 (cert:ignore)
}

int cfreerdp_capture(const char *host, int port, const char *outpath) {
    freerdp *instance = freerdp_new();
    if (!instance) return -1;
    instance->ContextSize = sizeof(cfCaptureContext);
    instance->PreConnect = cf_pre_connect;
    instance->PostConnect = cf_post_connect;
    instance->Authenticate = cf_authenticate;
    instance->VerifyCertificateEx = cf_verify_cert;

    if (!freerdp_context_new(instance)) {
        freerdp_free(instance);
        return -1;
    }
    cfCaptureContext *cf = (cfCaptureContext *)instance->context;
    cf->outpath = outpath;
    cf->paints = 0;

    rdpSettings *s = instance->context->settings;
    freerdp_settings_set_string(s, FreeRDP_ServerHostname, host);
    freerdp_settings_set_uint32(s, FreeRDP_ServerPort, (UINT32)port);
    freerdp_settings_set_string(s, FreeRDP_Username, "WDAGUtilityAccount");
    freerdp_settings_set_string(s, FreeRDP_Password, "Sandbox!2026");
    freerdp_settings_set_bool(s, FreeRDP_AutoLogonEnabled, TRUE); // INFO_AUTOLOGON — 로그인 화면 없이 데스크톱
    freerdp_settings_set_bool(s, FreeRDP_IgnoreCertificate, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_TlsSecurity, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_NlaSecurity, FALSE);
    freerdp_settings_set_bool(s, FreeRDP_RdpSecurity, FALSE);
    freerdp_settings_set_bool(s, FreeRDP_UseRdpSecurityLayer, FALSE);
    freerdp_settings_set_uint32(s, FreeRDP_DesktopWidth, 1440);
    freerdp_settings_set_uint32(s, FreeRDP_DesktopHeight, 900);
    freerdp_settings_set_uint32(s, FreeRDP_ColorDepth, 32);
    // 레거시 GDI 경로로 강제(gfx 비활성) — EndPaint로 프레임버퍼가 갱신됨.
    freerdp_settings_set_bool(s, FreeRDP_SupportGraphicsPipeline, FALSE);

    if (!freerdp_connect(instance)) {
        freerdp_free(instance);
        return -2;
    }

    HANDLE handles[64];
    int loops = 0;
    int settle = -1;          // 첫 페인트 이후 추가 처리 루프 수
    int captured = 0;
    while (!freerdp_shall_disconnect_context(instance->context)) {
        DWORD n = freerdp_get_event_handles(instance->context, handles, 64);
        if (n == 0) break;
        DWORD w = WaitForMultipleObjects(n, handles, FALSE, 200);
        if (w == WAIT_FAILED) break;
        if (!freerdp_check_event_handles(instance->context)) break;
        if (cf->paints > 0) {
            settle = (settle < 0) ? 0 : settle + 1;
            // 첫 페인트 후 ~50초 더 처리해 첫 로그인 프로필 로딩 완료 후 캡처.
            if (settle >= 250) {
                cf_write_ppm(instance->context->gdi, outpath);
                captured = 1;
                break;
            }
        }
        if (++loops > 300) break; // 안전장치 (~최대 60초)
    }

    int result = captured ? 0 : -3;
    freerdp_disconnect(instance);
    freerdp_context_free(instance);
    freerdp_free(instance);
    return result;
}
