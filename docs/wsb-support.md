<!--
SPDX-License-Identifier: GPL-3.0-or-later
Copyright (C) 2026 Nam Jung Hyun (rkttu)
-->

# Windows Sandbox `.wsb` 구성 지원 현황

MacSandbox는 Microsoft **Windows Sandbox**의 `.wsb`(XML) 구성 파일 스키마를 차용한다.
다만 실행 방식이 다르다 — Windows Sandbox는 Hyper-V 컨테이너이고, MacSandbox는
**QEMU+HVF 가상 머신 + FreeRDP(임베드) 하이브리드**다. 따라서 일부 항목은 의미가 다르거나
미구현이다. 이 문서는 각 `.wsb` 항목이 **실제로 무엇을 하는지/하지 않는지**를 정리한다.

- 파싱·매핑: [`WSBConfig.swift`](../src/MacSandbox/Core/WSBConfig.swift) → [`SandboxConfig`](../src/MacSandbox/Core/SandboxConfig.swift)
- 적용 시점: **매 실행(런타임)**. 장치/네트워크/디스플레이/메모리는 [`QEMURuntime`](../src/MacSandbox/Core/QEMURuntime.swift),
  리다이렉션(클립보드·오디오)은 임베드 엔진 [`rdp_engine.c`](../src/CFreeRDP/rdp_engine.c)가 처리한다.
- 사용: 파일 더블클릭/연결 대신 CLI 스위치 또는 `.wsb` 경로로 지정.

## 지원 매트릭스

| `.wsb` 항목 | 공식 의미 | MacSandbox | 비고 |
|---|---|:---:|---|
| `MemoryInMB` | 메모리(MB), 최소 2048 자동 보정 | ✅ 지원 | 호스트 인지형 기본값 + `[4GB, 호스트−4GB]` 클램프(Win11 ARM 최소 4GB) |
| `Networking` | 네트워크 on/off | ✅ 지원 | Enable=virtio-net NAT(user), Disable=`restrict=on`(외부 차단). 게스트 NetKVM 드라이버는 베이스라인에 주입 |
| `LogonCommand`/`Command` | 로그온 후 명령 실행 | ✅ 지원 | FAT 설정 디스크 + 베이스라인 로그온 에이전트(`macsandbox-logon.cmd`)로 전달 |
| `ClipboardRedirection` | 클립보드 공유 | ⚠️ 부분 | 텍스트·파일 **양방향 동작**하나 **항상 켜짐** — `Disable` 무시(엔진이 `RedirectClipboard=TRUE` 하드코딩) |
| `AudioInput` | 마이크 공유 | ⚠️ 부분 | 재생(rdpsnd)·마이크(audin)가 **RDP로 항상 동작**. 이 플래그는 보조 QEMU HDA 장치만 토글 → `Disable`해도 RDP 오디오는 유지 |
| `vGPU` | GPU 가속(Disable 시 WARP) | ⚠️ 부분/의미 상이 | **QEMU 콘솔(VNC 부팅 모니터) 표시 장치**(ramfb↔virtio-gpu-pci)만 전환. 사용자 화면(RDP)엔 영향 없고 WDDM 가속 없음(DWM은 소프트웨어 합성) |
| `MappedFolders` | 호스트 폴더 공유 | ❌ 미구현 | 파싱·요약 표시만. **실제 마운트 안 됨**(임베드 엔진에 드라이브/rdpdr 리다이렉션 없음; 구 sdl-freerdp 경로에만 잔존). `SandboxFolder` 미파싱 |
| `PrinterRedirection` | 프린터 공유 | ❌ 미구현 | 파싱하지만 엔진이 `RedirectPrinters` 미설정 → 효과 없음 |
| `VideoInput` | 웹캠 공유 | ❌ 미지원 | RDPECAM 채널이 번들 libfreerdp에서 비활성 + macOS 카메라 백엔드 부재(별도 분석 참조) |
| `ProtectedClient` | RDP AppContainer 강화 | ❌ 미지원 | 미파싱. Hyper-V AppContainer 개념이라 QEMU+RDP에 매핑 불가 |

> 확장(비표준): `CpuCores` — 실제 `.wsb`엔 없는 MacSandbox 전용 항목. ✅ 지원, `[2, 호스트−2]` 클램프.

## 항목별 상세

### ✅ 완전 지원

- **MemoryInMB** — 값을 받되 `[4GB, 호스트−4GB]`로 클램프(과할당 방지 + Win11 ARM 최소 4GB 보장).
  미지정 시 호스트 RAM의 약 절반(16GB 호스트 → 8GB).
- **Networking** — `Enable`(기본): QEMU user-mode NAT(`hostfwd`로 RDP 포워딩 포함). `Disable`: `restrict=on`으로
  외부 접근 차단(RDP 루프백은 유지). 게스트에서 동작하려면 NetKVM(virtio-net) 드라이버 필요 — 베이스라인에 주입됨.
- **LogonCommand** — `<Command>` 문자열을 FAT 설정 디스크의 `macsandbox-logon.cmd`로 기록하고,
  베이스라인이 로그온 시 이동식 드라이브를 스캔해 실행한다(unattend Run 키 에이전트). 다중 단계 명령은
  스크립트 파일로 작성 권장(공식 권고와 동일).

### ⚠️ 부분 지원 (known limitation)

- **ClipboardRedirection** — 텍스트·파일 양방향 클립보드는 완전히 동작하지만, 임베드 엔진이
  `RedirectClipboard=TRUE`를 **하드코딩**해 `Disable`이 적용되지 않는다. → *값으로 끌 수 없음*(항상 켜짐).
- **AudioInput** — 오디오 재생(rdpsnd)과 마이크 입력(audin) 모두 RDP로 동작(검증됨)하나, 엔진이
  `AudioPlayback/AudioCapture=TRUE`를 **하드코딩**한다. 이 플래그는 보조적인 QEMU `intel-hda`(베스트에포트,
  게스트 드라이버 의존)만 토글하므로 `Disable`해도 RDP 오디오는 유지된다. → *값으로 완전히 끄지 못함*.
- **vGPU** — `.wsb`의 본래 의미는 게스트 GPU 가속(미사용 시 WARP 소프트웨어 렌더)이다. MacSandbox에선
  사용자 화면이 RDP(rdpgfx)라 이 플래그가 **QEMU 콘솔(부팅 모니터)** 의 표시 장치만 바꾼다
  (`ramfb`↔`virtio-gpu-pci`). 데스크톱은 어느 쪽이든 GPU 가속이 없고 DWM이 소프트웨어로 합성한다.
  → *사용자 체감 GPU 가속엔 영향 없음*.

### ❌ 미지원 (known limitation)

- **MappedFolders** — `HostFolder`/`ReadOnly`는 파싱되고 요약에도 보이지만 **실제로 마운트되지 않는다**.
  임베드 RDP 엔진에 드라이브 리다이렉션(rdpdr/`RedirectDrives`)이 없고, 유일한 참조는 은퇴한 sdl-freerdp
  경로뿐이다. `SandboxFolder` 하위 요소도 파싱하지 않는다.
  *대안*: `LogonCommand`로 게스트 내부에서 파일을 내려받거나, 클립보드 파일 붙여넣기로 전달.
  *향후*: 임베드 엔진에 rdpdr 드라이브 리다이렉션을 붙이면 지원 가능.
- **PrinterRedirection** — 파싱만 하고 엔진이 `RedirectPrinters`를 설정하지 않아 효과가 없다.
- **VideoInput(웹캠)** — 번들 libfreerdp가 RDPECAM(`[MS-RDPECAM]`) 채널을 빌드에서 끔
  (`This build does not support [MS-RDPECAM]…`). 게다가 FreeRDP 업스트림 카메라 백엔드는 Linux `v4l`뿐이라
  macOS(AVFoundation) 백엔드가 없다. 지원하려면 libfreerdp 리빌드 + macOS 카메라 백엔드 신규 작성이 필요하다.
- **ProtectedClient** — 미파싱(요소 무시). Windows Sandbox의 AppContainer 격리는 Hyper-V 전용 개념이라
  QEMU+RDP 모델에 대응물이 없다.

## MacSandbox 고유 동작

- **기본값**은 Windows Sandbox 표준과 일치: 네트워킹·클립보드·오디오 **on**, 웹캠·프린터 **off**.
- **값 파싱**(3-상태): `Enable|true|1|on|yes` → 켜짐, `Disable|false|0|off|no` → 꺼짐,
  `Default`/미인식/미지정 → 기본값 유지. `ReadOnly`는 `true`만 읽기전용.
- **메모리/CPU 클램프**는 `.wsb`에 명시한 값보다 항상 우선한다(호스트 보호).
- **자격증명**: 사용자 계정/암호는 `.wsb`로 설정하지 않는다 — 내부 고정 자격증명으로 자동 로그온한다.
- **창 크기/해상도**: `.wsb`로 설정 불가(공식과 동일). MacSandbox는 창 크기에 맞춰 동적 리사이즈한다.

## 예시 `.wsb`

```xml
<Configuration>
  <MemoryInMB>8192</MemoryInMB>      <!-- [4GB, 호스트-4GB]로 클램프 -->
  <Networking>Enable</Networking>    <!-- Disable 시 외부 차단 -->
  <LogonCommand>
    <Command>cmd /c echo hello &gt; C:\Users\Public\hello.txt</Command>
  </LogonCommand>
  <!-- 아래는 파싱되지만 현재 효과 없음/제한: -->
  <ClipboardRedirection>Enable</ClipboardRedirection>   <!-- 항상 켜짐 -->
  <AudioInput>Enable</AudioInput>                        <!-- RDP 오디오 항상 동작 -->
  <MappedFolders>                                        <!-- ❌ 마운트 안 됨 -->
    <MappedFolder><HostFolder>~/Shared</HostFolder><ReadOnly>true</ReadOnly></MappedFolder>
  </MappedFolders>
  <VideoInput>Disable</VideoInput>                       <!-- ❌ 미지원 -->
  <PrinterRedirection>Disable</PrinterRedirection>       <!-- ❌ 미구현 -->
  <ProtectedClient>Disable</ProtectedClient>             <!-- ❌ 미파싱 -->
</Configuration>
```

## 출처

- 공식 스키마: [Use and configure Windows Sandbox — Microsoft Learn](https://learn.microsoft.com/en-us/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-configure-using-wsb-file) (2026-03-29 기준)
- 구현: 위 본문에 링크된 소스 파일들.
