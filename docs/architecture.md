# MacSandbox 아키텍처

macOS(Apple Silicon)에서 Windows 11 ARM64 일회용 샌드박스를 만드는 앱.
**런타임은 QEMU + Hypervisor.framework(HVF)** 이고, 베이스라인 이미지는
**WinPE 기반 DISM 오프라인 배포**로 완전 자동·결정론적으로 구축한다.

## 왜 QEMU인가 (AVF가 아니라)

Apple Virtualization Framework(AVF)는 게스트로 macOS/Linux만 지원하며, Windows ARM
게스트에는 virtio-gpu/net 인박스 드라이버가 없어 **화면·네트워크가 동작하지 않는다**.
Apple Silicon에서 Windows를 실제로 구동하는 길은 QEMU(+HVF) / Parallels / VMware뿐이고,
오픈소스로 이 자리를 점유하는 것이 QEMU다. (옛 AVF 시도는 git 이력 참고.)

- QEMU 바이너리는 `com.apple.security.hypervisor` entitlement로 서명돼야 `-accel hvf`가 동작.
  `scripts/build.sh`가 `vendor/qemu/bin/qemu-system-aarch64`에 멱등 서명한다.
- 앱 자체는 특별한 entitlement가 필요 없다(QEMU를 자식 프로세스로 실행할 뿐).

## 베이스라인 빌드 — WinPE DISM 배포 (완전 결정론적)

setup.exe + autounattend 방식은 "Press any key to boot from CD"(El Torito) 프롬프트와
대화형 화면 때문에 키 입력 휴리스틱이 필요했다. 이를 **DISM 오프라인 배포**로 대체해
**El Torito 프롬프트·키 입력·setup.exe GUI를 모두 제거**했다.

### 배포 매체 ([WinPEDeployMediaBuilder](../src/MacSandbox/Core/WinPEDeployMediaBuilder.swift))

사용자 ISO로부터 **GPT 파티션 FAT32 부트 디스크**를 만든다:

- `\EFI\BOOT\BOOTAA64.EFI` ← `bootmgfw.efi` (install.wim에서 wimlib로 추출)
- `\EFI\Microsoft\Boot\BCD` ← ISO의 BCD (그대로 — ramdisk 소스가 `[boot]` 상대참조라 패치 불필요)
- `\Boot\boot.sdi`, `\sources\boot.wim`(편집본)

> **핵심**: bootmgr는 `[boot]` 장치를 실제 파티션으로 매핑하므로 **GPT 파티션**이어야 한다.
> 슈퍼플로피(파티션 테이블 없음)는 "No mapping"으로 실패한다. → 펌웨어가 프롬프트 없이 WinPE 직접 부팅.

`boot.wim` image 2(Setup)는 `winpeshl.ini`로 setup.exe를 띄우므로, wimlib로 image 2에
다음을 주입해 setup.exe 대신 배포 스크립트를 실행시킨다:

- `winpeshl.ini` → `cmd /c X:\Windows\System32\deploy.cmd`
- `deploy.cmd`: `diskpart`(NVMe GPT: ESP/MSR/NTFS) → install.wim 탐색 →
  `dism /Apply-Image /Name:"<edition>" /ApplyDir:W:\` → **virtio-win 드라이버 오프라인 주입**
  (`dism /Image:W:\ /Add-Driver /Recurse`) → Panther unattend 복사 →
  `bcdboot W:\Windows /s S: /f UEFI` → `bootmgfw.efi`를 ESP의 `\EFI\BOOT\BOOTAA64.EFI`로 복사 → `wpeutil shutdown`
- `msbx-dp.txt`(diskpart 스크립트), `unattend.xml`(Panther)

### virtio-win 드라이버 주입 ([GuestDrivers](../src/MacSandbox/Core/GuestDrivers.swift))

배포 단계에 `virtio-win.iso`(없으면 fedorapeople에서 자동 다운로드, ~750MB 캐시)를 USB cdrom으로
추가로 물린다. `deploy.cmd`가 `\NetKVM` 마커로 ISO 드라이브를 찾아 오프라인 이미지(W:\)에
`/Add-Driver /Recurse`로 주입한다. ARM64 인박스에 없는 **NetKVM(virtio-net)** 이 핵심 —
이게 있어야 런타임에 RDP가 동작한다. (viostor·viogpudo·vioinput 등 ARM64 드라이버도 함께 주입.)

### 2단계 오케스트레이션 ([BaselineBuilder](../src/MacSandbox/Core/BaselineBuilder.swift))

1. **Phase 1 (배포)**: GPT FAT 부트디스크 + Windows ISO + 빈 NVMe(`nvme`)로 부팅.
   WinPE가 프롬프트·키 0으로 떠서 `deploy.cmd` 실행 → `dism` 적용 → `bcdboot` → shutdown(QEMU exit).
2. **Phase 2 (OOBE)**: NVMe만으로 부팅(펌웨어가 ESP의 `\EFI\BOOT\BOOTAA64.EFI` 자동 부팅).
   `\Windows\Panther\unattend.xml`(oobeSystem-only)이 첫 부팅을 자동화:
   부트스트랩 admin 자동 로그온 → FirstLogonCommands로 내장 **WDAGUtilityAccount** 활성화 +
   영구 자동 로그온 + **RDP 서버 활성화**(`fDenyTSConnections=0`, NLA off, `LimitBlankPasswordUse=0`,
   방화벽 remote-desktop 그룹 허용) + 로그온 에이전트(Run 키) 설정 → `shutdown` → 베이스라인 완료(status=ready).

> Panther unattend는 oobeSystem 패스만 쓴다. specialize에 `Microsoft-Windows-Deployment`
> RunSynchronous를 넣으면 일부 25H2 빌드가 "응답 파일이 올바르지 않음"으로 거부한다.

## 샌드박스 런타임 ([SandboxRunner](../src/MacSandbox/Core/SandboxRunner.swift) / [SandboxConfig](../src/MacSandbox/Core/SandboxConfig.swift))

베이스라인 위에 일회용 환경을 띄운다(Windows Sandbox의 `.wsb`에 대응):

1. 베이스라인 qcow2 위에 **COW 오버레이**(`qemu-img create -b`) + 신선한 UEFI 변수 사본.
2. `SandboxConfig`(메모리/CPU/네트워킹/vGPU/공유폴더/클립보드/마이크/프린터/로그온 명령)를
   QEMU 인자·RDP 플래그·설정 디스크로 번역.
3. QEMU 부팅 → WDAGUtilityAccount 자동 로그온. 종료(또는 FreeRDP 창 닫힘) 시 disposable이면
   오버레이/변수/설정 디스크 폐기.

로그온 명령은 작은 FAT 설정 디스크의 `macsandbox-logon.cmd`로 전달되고, 베이스라인의
로그온 에이전트(HKLM Run 키)가 실행한다.

## RDP 하이브리드 (상호작용 + 리다이렉션)

Windows Sandbox 자신이 내부적으로 RDP를 쓰는 것과 같은 접근. 두 경로를 병행한다:

- **부팅 모니터링**: VNC 프레임버퍼 → QMP `screendump` 폴링 → 인앱 콘솔([VMConsole](../src/MacSandbox/Core/VMConsole.swift)).
  화면 클릭(절대좌표)·키보드(`QKeyMap`)로 부팅 중에도 개입 가능.
- **사용자 상호작용**: 게스트가 뜨면 **FreeRDP**(`sdl-freerdp`) 창으로 접속([RDPSession](../src/MacSandbox/Core/RDPSession.swift)).
  폴더 공유(`/drive`)·클립보드(`+clipboard`)·마이크/오디오(`/microphone` `/sound`)·프린터(`/printer`)
  리다이렉션을 제공. (웹캠은 이 FreeRDP 빌드에 RDPECAM 채널이 없어 미지원.)

QEMU는 user-mode NAT + `hostfwd=tcp:127.0.0.1:<port>-:3389`로 RDP를 호스트에 노출하고,
FreeRDP가 `WDAGUtilityAccount`/빈 암호/`+sec:rdp`(NLA 우회)로 자동 로그온한다.
네트워킹 비활성 시 `restrict=on`으로 인터넷은 막되 RDP 포워딩은 유지.

> user-mode hostfwd는 게스트 RDP 준비 전에도 호스트측 connect를 수락하므로 포트 폴링으로
> 준비를 판정할 수 없다. 대신 FreeRDP를 **재시도 루프**로 띄워(짧게 실패=미준비→재시도,
> 오래 살다 종료=세션 종료→QEMU 종료) 게스트 RDP가 뜨는 시점을 자연스럽게 따라간다.

## 구성 요소

| 파일 | 역할 |
| ---- | ---- |
| `SandboxPaths` | app support 경로, vendor/qemu·wimlib·펌웨어 해석 |
| `DiskService` | qcow2 생성, COW 오버레이(샌드박스 런타임용) |
| `WinPEDeployMediaBuilder` | GPT FAT32 배포 부트 디스크 생성 |
| `QEMURuntime` | 배포/OOBE/샌드박스 인자 빌드(RDP hostfwd 포함), 프로세스 실행 |
| `UnattendBuilder` | Panther unattend(oobeSystem, RDP 활성화 포함) 생성 |
| `BaselineBuilder` | 2단계 빌드 오케스트레이션 |
| `GuestDrivers` | virtio-win ISO 확보(자동 다운로드/캐시) |
| `SandboxRunner` / `SandboxConfig` | 일회용 샌드박스 실행(COW 오버레이 + RDP 하이브리드) |
| `RDPSession` | FreeRDP 인자 빌드 + 재시도 실행 |
| `QMPInput` / `VMConsole` | QMP 입력 주입 + 화면 폴링 |

## 의존성

- `vendor/qemu` (qemu-system-aarch64, qemu-img, edk2 펌웨어) — `scripts/bundle_qemu.py`로 번들
- `wimlib` (`brew install wimlib`) — boot.wim 편집 + bootmgfw 추출
- `freerdp` (`brew install freerdp` → `sdl-freerdp`) — 샌드박스 상호작용 + 리다이렉션
- `virtio-win.iso` — 게스트 virtio 드라이버(자동 다운로드, app support 캐시)
- `hdiutil` / `diskutil` (macOS 기본) — ISO 마운트, GPT FAT32 디스크 생성

## CLI

`MacSandbox --headless-build [ISO경로]` — GUI 없이 베이스라인 빌드 후 종료(검증/자동화용).
