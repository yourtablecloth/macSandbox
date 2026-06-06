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

import Foundation

/// 샌드박스 RDP 자격증명. 사용자는 보거나 입력하지 않으며(클라이언트가 프로토콜로 자동 전송),
/// 고정 내부 암호로 신뢰성 있는 credential-based auto-logon을 한다(빈 암호 auto-logon은 불안정).
enum SandboxCreds {
    static let username = "WDAGUtilityAccount"
    static let password = "Sandbox!2026"
}

/// 일회용 샌드박스 실행 설정. Windows Sandbox의 `.wsb` 스키마에 대응한다.
///
/// **기본값은 Windows Sandbox 표준과 일치**한다(네트워킹·클립보드·오디오 on, 웹캠·프린터 off).
/// 적용 시점은 **샌드박스 런타임(매 실행)** 이며, 리다이렉션은 FreeRDP(RDP 하이브리드)가 처리한다.
/// 세부 옵션은 GUI가 아니라 `.wsb` 파일/커맨드라인 스위치로 지정한다([[WSBConfig]] / AppLaunch).
struct SandboxConfig: Codable, Equatable {

    /// 가상 GPU 표시 장치. **QEMU 콘솔(VNC 부팅 모니터) 전용** — 사용자 화면은 RDP(rdpgfx)라 영향 없음.
    /// on = virtio-gpu(2D, viogpudo), off = ramfb(드라이버리스, 안정적 기본값). WS 기본은 on이나 여기선 콘솔용이라 off.
    var vGpuEnabled: Bool = false

    /// NAT 네트워킹 (WS 기본 on). on = virtio-net(NAT). 게스트 NetKVM 드라이버는 베이스라인에 주입됨.
    var networkingEnabled: Bool = true

    /// 호스트 폴더 매핑 (`.wsb`의 MappedFolders). FreeRDP `/drive`로 리다이렉션.
    var mappedFolders: [MappedFolder] = []

    /// 로그온 직후 게스트에서 실행할 명령 (`.wsb`의 LogonCommand). 베이스라인 로그온 에이전트가
    /// 설정 디스크의 `macsandbox-logon.cmd`를 실행하는 방식으로 전달된다.
    var logonCommand: String = ""

    /// 마이크/오디오 공유 (WS 기본 on). FreeRDP `/microphone` + `/sound`.
    var audioInputEnabled: Bool = true

    /// 호스트 웹캠 입력 공유 (WS 기본 off). 현재 FreeRDP 빌드에 RDPECAM 채널 없어 미지원.
    var videoInputEnabled: Bool = false

    /// 클립보드 복사/공유 (WS 기본 on). FreeRDP `+clipboard`.
    var clipboardEnabled: Bool = true

    /// 프린터 리다이렉트 (WS 기본 off). FreeRDP `/printer`.
    var printerEnabled: Bool = false

    /// 메모리 크기 (MB). WS 표준 ~4GB.
    var memoryMB: Int = 4096

    /// CPU 코어 수 (`.wsb`엔 없는 항목 — 합리적 기본값).
    var cpuCores: Int = 4

    /// 종료 시 변경사항 폐기(일회용). Windows Sandbox와 동일하게 기본 true.
    var disposable: Bool = true
}

/// 호스트 ↔ 게스트 폴더 매핑 (`.wsb`의 MappedFolder)
struct MappedFolder: Codable, Equatable, Identifiable {
    var id = UUID()
    var hostPath: String
    var readOnly: Bool = false

    private enum CodingKeys: String, CodingKey { case hostPath, readOnly }
}
