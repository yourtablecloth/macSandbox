// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Copyright (C) 2026 Nam Jung Hyun (rkttu) <rkttu.official@gmail.com>
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

// 리다이렉션 기능 게이팅(.wsb 반영). rdp_engine_start 전에 호출. 미호출 시 기본값
// (클립보드 on, 마이크 on, 프린터 off). 스피커 재생은 항상 켜짐(.wsb 토글 없음).
void rdp_engine_set_features(RDPEngine *engine, int clipboard, int mic, int printer);

// 호스트 폴더 공유(.wsb MappedFolder). rdp_engine_start 전에 폴더마다 호출(최대 16개).
// 게스트에 리다이렉트 드라이브로 노출된다. readOnly는 FreeRDP drive 미지원(읽기/쓰기로 공유).
void rdp_engine_add_mapped_folder(RDPEngine *engine, const char *hostPath, const char *name, int readOnly);

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
#define RDP_PTR_HWHEEL  0x0400
// 휠 회전량은 flags 하위 9비트(2의 보수). 음수면 NEGATIVE 플래그 + 하위 8비트 보수값.
#define RDP_PTR_WHEEL_NEGATIVE 0x0100

// 입력 주입(인앱 뷰 상호작용). flags는 RDP_PTR_*. x/y는 게스트 해상도 좌표.
void rdp_engine_send_pointer(RDPEngine *engine, uint16_t flags, int x, int y);
// macOS 키코드(NSEvent.keyCode)를 RDP 스캔코드로 변환해 전송.
void rdp_engine_send_mac_key(RDPEngine *engine, uint16_t macKeyCode, int down);

// 오디오 재생(rdpsnd, 게스트→호스트 스피커) on/off — 기본 on. rdp_engine_start 전에 호출.
// CoreAudio(sys:mac) 서브시스템을 명시 지정해 무음(fake) 백엔드 선택을 막는다.
void rdp_engine_set_audio_playback(RDPEngine *engine, int playback);

// 클라이언트 키보드 식별(타입/서브타입/레이아웃) — 게스트가 세션 키보드 드라이버를 고르는 기준.
// 예: 한국어 101키 Type A = (8, 3, 0x412) → 오른쪽 Alt가 한/영, 오른쪽 Ctrl이 한자.
//     일본어 106키       = (7, 2, 0x411). 0이면 FreeRDP 기본. rdp_engine_start 전에 호출.
void rdp_engine_set_keyboard(RDPEngine *engine, int type, int subtype, int layout);

// 토글 키 상태 동기화(호스트→게스트, RDP Synchronize Event). capsLock/numLock = 0|1.
// 연결 후 임의 시점 호출 가능(미연결 시 무시).
void rdp_engine_send_sync_locks(RDPEngine *engine, int capsLock, int numLock);

#ifdef __cplusplus
}
#endif

#endif /* RDP_ENGINE_H */
