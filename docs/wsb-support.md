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
| `ClipboardRedirection` | 클립보드 공유 | ✅ 지원 | 텍스트·파일 양방향. `Disable` 시 cliprdr 미로드(검증됨) |
| `AudioInput` | 마이크 공유 | ✅ 지원 | 마이크(audin)를 게이팅. 스피커 재생(rdpsnd)은 `.wsb` 토글이 없어 상시(Windows Sandbox와 동일) |
| `PrinterRedirection` | 프린터 공유 | ✅ 지원 | `RedirectPrinters`+rdpdr+CUPS → 호스트 프린터를 게스트에 등록(PRN1 검증). `Disable` 시 미등록 |
| `vGPU` | GPU 가속(Disable 시 WARP) | ⚠️ 부분/의미 상이 | **QEMU 콘솔(VNC 부팅 모니터) 표시 장치**(ramfb↔virtio-gpu-pci)만 전환. 사용자 화면(RDP)엔 영향 없고 WDDM 가속 없음(DWM은 소프트웨어 합성) |
| `MappedFolders` | 호스트 폴더 공유 | ✅ 지원 | RDP rdpdr drive로 지정 폴더만 게스트에 `\\tsclient\<name>`로 노출(읽기/쓰기 검증). `ReadOnly` 미강제, `SandboxFolder` 미파싱, 최대 16개 |
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
- **ClipboardRedirection** — 텍스트·파일 양방향 클립보드. 값을 엔진 `RedirectClipboard`로 게이팅하며,
  `Disable` 시 cliprdr 채널이 로드되지 않음(검증됨).
- **AudioInput** — 마이크 입력(audin, macOS AVFAudio)을 게이팅. `Disable` 시 audin 미로드.
  스피커 재생(rdpsnd, CoreAudio)은 `.wsb`에 토글이 없어 항상 켜짐(Windows Sandbox와 동일).
  최초 마이크 사용 시 macOS 권한 프롬프트.
- **PrinterRedirection** — 엔진 `RedirectPrinters` + rdpdr + libfreerdp CUPS 백엔드로 호스트 프린터를
  게스트에 등록(검증: `registered [printer] device PRN1`). `Disable`(기본) 시 미등록.
- **MappedFolders** — **RDP 수준 구현**(QEMU 9p/virtfs 아님): FreeRDP rdpdr drive 장치
  (`freerdp_client_add_device_channel`)로 **지정 폴더만** 게스트에 노출. 게스트에서 `\\tsclient\<name>`
  (드라이브명 = 폴더명, 충돌 시 번호)로 보이며 게스트 드라이버 불필요. 읽기+쓰기 end-to-end 검증됨
  (게스트가 공유 파일을 읽어 다시 기록 → 호스트에 반영). 최대 16개.
  *제한*: `ReadOnly`는 FreeRDP drive가 미지원이라 강제되지 않음(읽기/쓰기로 공유). `SandboxFolder` 미파싱.
  `RedirectDrives`(핫플러그 전체 볼륨 공유)는 보안상 쓰지 않음.

### ⚠️ 부분 지원 (known limitation)

- **vGPU** — `.wsb`의 본래 의미는 게스트 GPU 가속(미사용 시 WARP 소프트웨어 렌더)이다. MacSandbox에선
  사용자 화면이 RDP(rdpgfx)라 이 플래그가 **QEMU 콘솔(부팅 모니터)** 의 표시 장치만 바꾼다
  (`ramfb`↔`virtio-gpu-pci`). 데스크톱은 어느 쪽이든 GPU 가속이 없고 DWM이 소프트웨어로 합성한다.
  → *사용자 체감 GPU 가속엔 영향 없음*.

### ❌ 미지원 (known limitation)

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
  <ClipboardRedirection>Enable</ClipboardRedirection>   <!-- ✅ Disable 시 클립보드 차단 -->
  <AudioInput>Enable</AudioInput>                        <!-- ✅ 마이크 게이팅(스피커는 상시) -->
  <PrinterRedirection>Enable</PrinterRedirection>        <!-- ✅ 호스트 프린터 → 게스트 -->
  <MappedFolders>                                        <!-- ✅ \\tsclient\Shared 로 노출(ReadOnly 미강제) -->
    <MappedFolder><HostFolder>~/Shared</HostFolder><ReadOnly>false</ReadOnly></MappedFolder>
  </MappedFolders>
  <!-- 아래는 파싱되지만 미지원: -->
  <VideoInput>Disable</VideoInput>                       <!-- ❌ 미지원(RDPECAM 부재) -->
  <ProtectedClient>Disable</ProtectedClient>             <!-- ❌ 미파싱 -->
</Configuration>
```

## 출처

- 공식 스키마: [Use and configure Windows Sandbox — Microsoft Learn](https://learn.microsoft.com/en-us/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-configure-using-wsb-file) (2026-03-29 기준)
- 구현: 위 본문에 링크된 소스 파일들.
