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

#ifndef RDP_ENGINE_H
#define RDP_ENGINE_H

#include <stdint.h>

// libfreerdp를 구동하는 엔진(plain C 인터페이스 — WinPR/AppKit 타입 노출 안 함).
// AppKit(NSView)과 WinPR을 같은 번역 단위에 두면 COM 타입(REFIID 등)이 CoreFoundation과
// 충돌하므로, freerdp 로직은 이 엔진(rdp_engine.c)에 격리한다.

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RDPEngine RDPEngine;

// 프레임 콜백: BGRX32 버퍼(콜백 동안만 유효 — 필요하면 복사). 연결 스레드에서 호출됨.
typedef void (*RDPFrameCallback)(void *userdata, const uint8_t *bgrx, int width, int height, int stride);
// 상태 텍스트 콜백.
typedef void (*RDPStatusCallback)(void *userdata, const char *status);
// 원격(게스트)에서 복사된 텍스트가 도착(remote→local). 연결 스레드에서 호출됨.
typedef void (*RDPClipboardTextCallback)(void *userdata, const char *utf8);
// 원격(게스트)에서 복사된 파일들을 호스트 임시 경로로 받아옴(remote→local).
// paths는 count개 UTF8 절대경로(콜백 동안만 유효). 연결 스레드에서 호출됨.
typedef void (*RDPClipboardFilesCallback)(void *userdata, const char *const *paths, int count);

RDPEngine *rdp_engine_create(const char *host, int port,
                             const char *username, const char *password,
                             RDPFrameCallback onFrame, RDPStatusCallback onStatus,
                             RDPClipboardTextCallback onRemoteText,
                             void *userdata);

void rdp_engine_start(RDPEngine *engine); // 백그라운드 스레드에서 연결+이벤트 루프
void rdp_engine_stop(RDPEngine *engine);  // 중단 요청
void rdp_engine_free(RDPEngine *engine);  // 정리(중단 후 스레드 조인)

// 로컬(호스트) 클립보드 텍스트를 게스트에 공유(local→remote). NSPasteboard 변경 시 호출.
void rdp_engine_set_local_clipboard_text(RDPEngine *engine, const char *utf8);
// 로컬(호스트) 클립보드 파일들을 게스트에 공유(local→remote, Mac→윈도우). paths는 count개 절대경로.
void rdp_engine_set_local_clipboard_files(RDPEngine *engine, const char *const *paths, int count);

// 원격→로컬 파일 클립보드 수신 콜백 등록(윈도우→Mac). 모든 파일을 임시폴더로 받은 뒤 호출됨.
void rdp_engine_set_files_callback(RDPEngine *engine, RDPClipboardFilesCallback cb);

// 동적 해상도: 게스트 데스크톱을 width×height(픽셀)로, DPI 배율 scalePercent(100~500,
// 예: Retina=200)로 변경 요청. 창 크기/백킹 배율에 맞춤. 연결 전 호출 시 보관.
void rdp_engine_request_resize(RDPEngine *engine, int width, int height, int scalePercent);

// RDP 포인터 플래그 (freerdp/input.h의 PTR_FLAGS_*와 동일 값; winpr 없는 뷰에서 쓰기 위해 재정의).
#define RDP_PTR_MOVE    0x0800
#define RDP_PTR_DOWN    0x8000
#define RDP_PTR_BUTTON1 0x1000
#define RDP_PTR_BUTTON2 0x2000
#define RDP_PTR_BUTTON3 0x4000
#define RDP_PTR_WHEEL   0x0200

// 입력 주입(인앱 뷰 상호작용). flags는 RDP_PTR_*. x/y는 게스트 해상도 좌표.
void rdp_engine_send_pointer(RDPEngine *engine, uint16_t flags, int x, int y);
// macOS 키코드(NSEvent.keyCode)를 RDP 스캔코드로 변환해 전송.
void rdp_engine_send_mac_key(RDPEngine *engine, uint16_t macKeyCode, int down);

#ifdef __cplusplus
}
#endif

#endif /* RDP_ENGINE_H */
