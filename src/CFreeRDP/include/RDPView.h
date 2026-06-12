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

/// libfreerdp를 직접 구동해 RDP 화면을 인앱 NSView로 렌더하는 뷰(PoC).
/// 별도 FreeRDP 창 없이 SwiftUI에 NSViewRepresentable로 임베드된다.
@interface RDPView : NSView

/// 연결 시작 (백그라운드 스레드에서 freerdp_connect + 이벤트 루프).
- (void)connectToHost:(NSString *)host
                 port:(int)port
             username:(NSString *)username
             password:(NSString *)password;

/// 연결 종료 (스레드 중단 + 정리).
- (void)disconnect;

/// 현재 연결 상태 텍스트(상태 표시용).
@property (nonatomic, readonly, copy) NSString *statusText;

/// 첫 RDP 프레임이 렌더된 시점에 메인 스레드에서 1회 호출(부팅 오버레이 → RDP 화면 전환용).
@property (nonatomic, copy) void (^onFirstFrame)(void);

/// 리다이렉션 기능(.wsb 반영). connectToHost 전에 설정한다.
/// 기본: 클립보드 on, 마이크 on, 프린터 off, 스피커 재생 on.
@property (nonatomic) BOOL clipboardEnabled;
@property (nonatomic) BOOL micEnabled;
@property (nonatomic) BOOL printerEnabled;
/// 오디오 재생(게스트→호스트 스피커, rdpsnd+CoreAudio). 기본 YES. connectToHost 전에 설정.
@property (nonatomic) BOOL audioPlaybackEnabled;
/// HiDPI(Retina) — YES면 백킹 픽셀 해상도 + DPI 200%, NO면 포인트 해상도 + 100%. 기본 YES.
@property (nonatomic) BOOL hiDPIEnabled;

/// 클라이언트 키보드 식별(타입/서브타입/레이아웃) — 게스트의 세션 키보드 드라이버 선택 기준.
/// 한국어 (8,3,0x412) → 오른쪽 Option(=오른쪽 Alt)이 한/영. 0이면 FreeRDP 기본. connect 전에 호출.
- (void)setKeyboardType:(int)type subtype:(int)subtype layout:(int)layout;

/// 공유 폴더 추가(.wsb MappedFolder). connectToHost 전에 폴더마다 호출.
/// 게스트에 리다이렉트 드라이브로 노출. readOnly는 미강제(읽기/쓰기 공유).
- (void)addMappedFolder:(NSString *)hostPath name:(NSString *)name readOnly:(BOOL)readOnly;

@end
