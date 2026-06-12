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

#ifndef CFREERDP_H
#define CFREERDP_H

#ifdef __cplusplus
extern "C" {
#endif

/// libfreerdp 링크 검증용: freerdp 인스턴스를 만들어 보고 버전 문자열을 반환한다.
/// 링크가 안 되면 빌드/링크 단계에서 실패하므로, 성공 빌드 + 호출 = 링크 OK.
const char *cfreerdp_link_test(void);

/// PoC-1b-i: host:port의 RDP(WDAGUtilityAccount/빈 암호/TLS)에 연결해 gdi로 1프레임을
/// 받아 PPM(P6) 파일로 저장한다. 그래픽 파이프라인 전체(연결+디코드)를 헤드리스로 검증.
/// 반환: 0=성공, 음수=실패(-1 컨텍스트, -2 연결, -3 프레임 미수신).
int cfreerdp_capture(const char *host, int port, const char *outpath);

/// PoC-2: remote→local 텍스트 클립보드 close-loop 검증. 연결 후 입력을 주입해 게스트
/// 메모장에 'msbxrt'를 입력→Ctrl+A→Ctrl+C하고, 그 텍스트가 호스트로 돌아오는지 본다.
/// 반환: 0=수신 성공, 1=실패.
int cfreerdp_cliptest(const char *host, int port);

/// PoC-3: 윈도우→Mac 파일 클립보드 close-loop 검증. PowerShell로 게스트에 파일 생성 +
/// Set-Clipboard 후, 그 파일이 호스트 임시폴더로 전송돼 오는지 본다. 반환: 0=성공, 1=실패.
int cfreerdp_filetest(const char *host, int port);

/// PoC-3b: Mac→윈도우 파일 클립보드 round-trip 검증. 호스트 파일을 클립보드에 올리고 게스트가
/// 데스크톱에 붙여넣기(materialize) 후 그 내용을 텍스트로 회수해 바이트 일치를 본다. 0=성공,1=실패.
int cfreerdp_filetest2(const char *host, int port);

/// PoC-3b(폴더): Mac→윈도우 폴더(하위폴더 포함) round-trip 검증. 0=성공,1=실패.
int cfreerdp_filetest3(const char *host, int port);

/// c: 동적 해상도 검증(리사이즈 후 프레임 크기 변화). 0=성공,1=실패.
int cfreerdp_restest(const char *host, int port);

/// 상하 반전 렌더 검증(합성 프레임). 0=정상, 1=뒤집힘.
int cfreerdp_fliptest(void);

#ifdef __cplusplus
}
#endif

#endif /* CFREERDP_H */
