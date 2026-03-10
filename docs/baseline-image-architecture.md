# MacSandbox 베이스라인 이미지 아키텍처 구현 계획

## 개요

Windows 11 ARM64 ESD를 다운로드하여 무인 설치(Unattended Install)를 수행하고,
설치 완료된 디스크 이미지를 **베이스라인 이미지**로 보존한 뒤,
샌드박스 실행 시마다 Copy-on-Write(COW) 오버레이를 생성하여 일회용 환경을 제공하는 시스템.

```text
┌─────────────────────────────────────────────────────────┐
│                    Setup Mode (1회)                      │
│                                                         │
│  ESD 다운로드 → qcow2 생성 → QEMU 부팅 (ISO+unattend)  │
│  → Windows 자동 설치 → 설치 완료 감지 → 베이스라인 저장  │
└─────────────────────┬───────────────────────────────────┘
                      │ baseline.qcow2
                      ▼
┌─────────────────────────────────────────────────────────┐
│                   Sandbox Mode (매회)                    │
│                                                         │
│  베이스라인 선택 → COW 오버레이 생성 → QEMU 부팅        │
│  → 사용자 작업 → VM 종료 → 오버레이 삭제 (원상복구)     │
└─────────────────────────────────────────────────────────┘
```

---

## 모드 정의

### Setup Mode (베이스라인 빌더)

- **목적**: Windows가 설치된 깨끗한 디스크 이미지를 1회 생성
- **트리거**: 사용자가 "새 베이스라인 만들기" 실행
- **입력**: Windows ARM64 ESD/ISO 파일, (선택) virtio 드라이버 ISO
- **출력**: `~/Library/Application Support/MacSandbox/baselines/{name}/baseline.qcow2`
- **특징**: Sysprep 미사용 — OOBE 완료 상태 그대로 보존하여 부팅 시간 최소화

### Sandbox Mode (일회용 샌드박스)

- **목적**: 베이스라인에서 빠르게 일회용 VM 생성/실행/폐기
- **트리거**: 사용자가 "샌드박스 시작" 실행
- **입력**: 베이스라인 이미지 경로
- **출력**: 일시적 COW 오버레이 (종료 시 삭제)
- **특징**: 기존 `DiskImageService.createOverlay` + `removeOverlay` 활용

---

## 디렉토리 구조

```text
~/Library/Application Support/MacSandbox/
├── baselines/                          # 베이스라인 이미지 저장
│   └── {baseline-name}/
│       ├── baseline.qcow2              # 설치 완료된 Windows 디스크
│       ├── efi-vars.fd                 # 해당 베이스라인의 UEFI 변수
│       └── metadata.json               # 베이스라인 메타데이터
├── images/                             # 기존 빈 이미지 (호환 유지)
├── overlays/                           # 샌드박스 COW 오버레이 (임시)
├── configs/                            # .msb 설정 파일
├── iso/                                # 다운로드된 ESD/ISO 파일
├── efi/                                # 공용 UEFI 파일
│   └── edk2-aarch64-code.fd            # UEFI 펌웨어 (읽기 전용)
└── drivers/                            # virtio 드라이버
    └── virtio-win.iso                  # virtio-win 드라이버 ISO
```

---

## 구현 TODO 목록

### Phase 1: 모델 및 데이터 구조

#### 1.1 `BaselineImage` 모델 생성

- [ ] `src/MacSandbox/Models/BaselineImage.swift` 신규 생성
- [ ] 필드 정의:
  - `id: UUID`
  - `name: String` — 사용자 지정 이름 (예: "Windows 11 24H2")
  - `diskPath: String` — baseline.qcow2 절대 경로
  - `efiVarsPath: String` — efi-vars.fd 절대 경로
  - `createdAt: Date`
  - `windowsVersion: String` — 설치된 Windows 버전 정보
  - `diskSizeGB: Int`
  - `architecture: GuestArchitecture`
  - `status: BaselineStatus` — `.creating`, `.ready`, `.error`, `.deleted`
- [ ] `BaselineStatus` enum 정의
- [ ] `Codable` 준수 (`metadata.json`으로 저장)

#### 1.2 `SetupProgress` 모델 생성

- [ ] `src/MacSandbox/Models/SetupProgress.swift` 신규 생성
- [ ] Setup Mode의 단계별 진행 상태 추적:
  - `.idle` — 대기
  - `.downloadingISO` — ESD/ISO 다운로드 중
  - `.preparingDisk` — qcow2 디스크 생성 중
  - `.preparingDrivers` — virtio 드라이버 준비 중
  - `.generatingUnattend` — unattend.xml 생성 중
  - `.installingWindows` — QEMU에서 Windows 설치 진행 중
  - `.waitingForCompletion` — 설치 완료 대기
  - `.finalizingBaseline` — 베이스라인 마무리 (메타데이터 저장)
  - `.completed` — 완료
  - `.failed(String)` — 실패 (에러 메시지 포함)

---

### Phase 2: Unattend.xml 생성

#### 2.1 `UnattendGenerator` 서비스 생성

- [ ] `src/MacSandbox/Services/UnattendGenerator.swift` 신규 생성
- [ ] Windows 11 ARM64 무인 설치용 `autounattend.xml` 템플릿 구현
- [ ] 포함해야 할 설정:
  - **windowsPE 패스**: 디스크 파티션 설정 (GPT: EFI SP + MSR + Windows)
  - **windowsPE 패스**: `Microsoft-Windows-Setup > ImageInstall` — ESD/WIM 이미지 선택
  - **specialize 패스**: 컴퓨터 이름, 로케일 설정
  - **oobeSystem 패스**: OOBE 스킵 설정 (EULA 동의, 네트워크 스킵)
  - **oobeSystem 패스**: 로컬 관리자 계정 자동 생성
  - **oobeSystem 패스**: 자동 로그온 설정
- [ ] virtio 드라이버 로딩을 위한 `DriverPaths` 섹션 추가
  - ARM64에서는 `viostor\w11\ARM64`, `NetKVM\w11\ARM64` 경로
- [ ] 설치 완료 후 shutdown 명령을 실행하는 `FirstLogonCommands` 추가
  - `shutdown /s /t 30 /f` — 설치 완료 후 자동 종료 (베이스라인 저장 트리거)
- [ ] 템플릿 파라미터:
  - `locale: String` (기본: "ko-KR")
  - `username: String` (기본: "User")
  - `password: String` (기본: "" — 빈 비밀번호)
  - `computerName: String` (기본: "SANDBOX")
  - `diskSizeGB: Int`
- [ ] 생성된 XML을 임시 ISO로 패키징하는 기능 (또는 virtio-9p로 전달)

#### 2.2 Unattend ISO 생성

- [ ] `autounattend.xml`을 포함하는 작은 ISO 이미지 생성
- [ ] macOS `hdiutil` 사용:

  ```bash
  hdiutil makehybrid -o unattend.iso -joliet -iso <temp_dir>
  ```

- [ ] 임시 디렉토리에 `autounattend.xml` 배치 후 ISO 생성
- [ ] 대안: virtio-9p 공유 폴더로 `autounattend.xml` 전달 (`-virtfs` 옵션)

---

### Phase 3: Virtio 드라이버 관리

#### 3.1 `VirtioDriverService` 서비스 생성

- [ ] `src/MacSandbox/Services/VirtioDriverService.swift` 신규 생성
- [ ] virtio-win ISO 다운로드 기능
  - 공식 배포 URL: `https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso`
  - SHA256 검증
- [ ] 다운로드 위치: `~/Library/Application Support/MacSandbox/drivers/virtio-win.iso`
- [ ] 이미 다운로드된 경우 재사용
- [ ] Windows ARM64용 virtio 드라이버 포함 여부 확인 로직
  - 필수 드라이버: `viostor` (스토리지), `NetKVM` (네트워크), `viogpudo` (GPU)
  - ARM64 빌드 가용성 확인 (virtio-win이 ARM64를 포함하지 않을 수 있음)

#### 3.2 ARM64 virtio 드라이버 대안 검토

- [ ] virtio-win이 ARM64 드라이버를 포함하지 않는 경우의 대안:
  - **옵션 A**: QEMU의 `-device virtio-blk-pci` 대신 `-device nvme` 사용 (Windows 기본 드라이버)
  - **옵션 B**: `-device usb-storage` 사용 (느리지만 드라이버 불필요)
  - **옵션 C**: 커뮤니티 빌드된 ARM64 virtio 드라이버 소싱
- [ ] 선택한 전략에 따라 QEMU 인자 조정

---

### Phase 4: 베이스라인 빌더 서비스

#### 4.1 `BaselineBuilderService` 핵심 구현

- [ ] `src/MacSandbox/Services/BaselineBuilderService.swift` 신규 생성
- [ ] `@MainActor ObservableObject`로 구현 (진행 상태 UI 바인딩)
- [ ] Published 프로퍼티:
  - `setupProgress: SetupProgress`
  - `progressDetail: String` — 현재 단계 상세 설명
  - `isRunning: Bool`
  - `currentBaseline: BaselineImage?`

#### 4.2 베이스라인 생성 플로우 구현

- [ ] `createBaseline(name:isoPath:diskSizeGB:)` async 메서드:

  **Step 1 — 디렉토리 준비**
  - `baselines/{name}/` 디렉토리 생성
  - 중복 이름 검사

  **Step 2 — 빈 qcow2 디스크 생성**
  - `qemu-img create -f qcow2 baseline.qcow2 {size}G`
  - 기존 `DiskImageService.createBlankImage` 확장 또는 새 메서드

  **Step 3 — UEFI 변수 파일 준비**
  - efi-vars.fd를 베이스라인 디렉토리에 복사
  - 기존 `QEMUService.ensureEfiVarsFile` 로직 재사용

  **Step 4 — Unattend 미디어 생성**
  - `UnattendGenerator`로 `autounattend.xml` 생성
  - ISO 패키징 또는 virtio-9p 마운트 준비

  **Step 5 — (선택) Virtio 드라이버 확인**
  - virtio-win.iso 존재 확인, 필요시 다운로드

  **Step 6 — QEMU VM 시작 (설치 모드)**
  - `buildSetupModeArguments()` — Phase 4.3에서 구현
  - Windows ISO/ESD + Unattend ISO + (선택) virtio-win ISO 마운트
  - VM 프로세스 시작 및 모니터링

  **Step 7 — 설치 완료 대기**
  - QMP 또는 프로세스 종료 감지
  - Unattend의 `FirstLogonCommands`에서 `shutdown` 실행 → VM 정상 종료
  - 타임아웃 설정 (기본 60분)

  **Step 8 — 베이스라인 마무리**
  - metadata.json 저장
  - 임시 파일 정리 (unattend ISO 등)
  - BaselineImage 상태를 `.ready`로 변경

#### 4.3 Setup Mode QEMU 인자 빌드

- [ ] `QEMUService`에 `buildSetupModeArguments()` 메서드 추가
- [ ] 기존 `buildAArch64Arguments`와의 차이점:
  - **디스크**: baseline.qcow2를 직접 연결 (오버레이 아님)
  - **ISO 마운트**: Windows ISO를 CDROM 또는 virtio-blk로 연결
  - **Unattend**: autounattend.iso를 두 번째 CDROM으로 연결
  - **Virtio 드라이버**: virtio-win.iso를 세 번째 CDROM으로 연결 (필요시)
  - **부팅 순서**: ISO에서 부팅 (`bootindex=0` on ISO device)
  - **UEFI**: 베이스라인 전용 efi-vars.fd 사용
  - **메모리/CPU**: 설치 시에는 더 많은 리소스 할당 권장 (4+ cores, 8GB+ RAM)
- [ ] 인자 예시 (AArch64):

  ```text
  -machine virt,highmem=on,gic-version=3
  -accel hvf
  -cpu host
  -smp 4
  -m 8192
  -drive if=pflash,format=raw,readonly=on,file=edk2-aarch64-code.fd
  -drive if=pflash,format=raw,file=baselines/{name}/efi-vars.fd
  -drive file=baselines/{name}/baseline.qcow2,if=none,id=hd0,format=qcow2
  -device virtio-blk-pci,drive=hd0
  -drive file=Windows11_ARM64.iso,if=none,id=cdrom0,media=cdrom
  -device virtio-blk-pci,drive=cdrom0,bootindex=0
  -drive file=autounattend.iso,if=none,id=cdrom1,media=cdrom
  -device virtio-blk-pci,drive=cdrom1
  -device virtio-gpu-pci
  -device qemu-xhci
  -device usb-kbd
  -device usb-tablet
  -nic user,model=virtio-net-pci
  -display cocoa
  ```

#### 4.4 설치 완료 감지

- [ ] **방법 1 — 프로세스 종료 감지** (권장, 가장 간단)
  - Unattend의 `FirstLogonCommands`에서 `shutdown /s /t 30`
  - QEMU 프로세스가 종료되면 설치 완료로 판단
  - `Process.terminationHandler` 활용
- [ ] **방법 2 — QMP 모니터링** (보조)
  - QMP `SHUTDOWN` 이벤트 감지
  - Unix domain socket으로 QMP 연결
- [ ] 설치 실패 감지:
  - QEMU가 비정상 종료 (exit code ≠ 0)
  - 타임아웃 초과 (기본 60분)
  - 디스크 이미지 크기가 비정상적으로 작음 (설치 미완료 징후)

#### 4.5 베이스라인 관리

- [ ] `BaselineBuilderService`에 추가 메서드:
  - `listBaselines() -> [BaselineImage]` — 저장된 베이스라인 목록
  - `deleteBaseline(id:)` — 베이스라인 삭제 (디렉토리 전체 삭제)
  - `loadBaseline(name:) -> BaselineImage?` — metadata.json 로드
  - `validateBaseline(id:) -> Bool` — qcow2 + efi-vars.fd 존재 확인
  - `duplicateBaseline(id:newName:)` — 베이스라인 복제 (별도 이미지로)

---

### Phase 5: Sandbox Mode 개선

#### 5.1 베이스라인 기반 샌드박스 시작

- [ ] `SandboxViewModel.startSandbox()` 수정:
  - 베이스라인의 `efi-vars.fd`도 COW 복사하여 사용
    - 방법: 샌드박스 시작 시 `efi-vars.fd`를 오버레이 디렉토리에 복사
    - 또는 efi-vars도 qcow2 오버레이 사용
  - `buildAArch64Arguments`에서 베이스라인의 efi-vars 경로 사용
- [ ] `DiskImageService.createOverlay` 확장:
  - 오버레이 생성 시 efi-vars.fd 복사 기능 추가
  - `createSandboxEnvironment(baseline:sandboxId:) -> SandboxDiskPaths` 메서드
  - 반환값: `(overlayDiskPath: String, efiVarsPath: String)`

#### 5.2 샌드박스 정리 로직 개선

- [ ] `onVMStopped()` 수정:
  - 오버레이 qcow2 삭제 (기존)
  - 복사된 efi-vars.fd도 삭제
  - 임시 파일 전체 정리

---

### Phase 6: ViewModel 통합

#### 6.1 `SetupViewModel` 생성

- [ ] `src/MacSandbox/ViewModels/SetupViewModel.swift` 신규 생성
- [ ] BaselineBuilderService를 래핑하는 ViewModel
- [ ] 바인딩 프로퍼티:
  - `baselineName: String`
  - `selectedISOPath: String?`
  - `diskSizeGB: Int` (기본: 64)
  - `cpuCores: Int` (기본: 4)
  - `memoryMB: Int` (기본: 8192)
  - `locale: String` (기본: "ko-KR")
  - `progress: SetupProgress`
  - `progressPercent: Double`
  - `logOutput: String`
  - `existingBaselines: [BaselineImage]`
- [ ] 액션 메서드:
  - `startSetup()` — 베이스라인 생성 시작
  - `cancelSetup()` — 생성 중단 (VM 강제 종료)
  - `selectISO()` — NSOpenPanel으로 ISO 선택
  - `deleteBaseline(id:)` — 베이스라인 삭제

#### 6.2 `SandboxViewModel` 수정

- [ ] 베이스라인 목록 로딩 기능 추가:
  - `availableBaselines: [BaselineImage]`
  - `selectedBaseline: BaselineImage?`
- [ ] `startSandbox()`에서 베이스라인 기반 시작 지원
- [ ] 기존 `baseImagePath` 직접 지정 방식도 호환 유지

---

### Phase 7: UI 구현

#### 7.1 `SetupWizardView` — 베이스라인 생성 마법사

- [ ] `src/MacSandbox/Views/SetupWizardView.swift` 신규 생성
- [ ] 단계별 위저드 UI:

  **Step 1 — ISO 선택**
  - Windows ARM64 ESD/ISO 파일 선택 (파일 선택 패널)
  - 또는 `WindowsDownloadService`로 다운로드
  - ISO 파일 정보 표시 (이름, 크기)

  **Step 2 — 설정 입력**
  - 베이스라인 이름
  - 디스크 크기 (슬라이더, 기본 64GB)
  - CPU 코어 수 (설치용, 기본 4)
  - 메모리 크기 (설치용, 기본 8GB)
  - 로케일 선택

  **Step 3 — 설치 진행**
  - ProgressView로 진행 상태 표시
  - 단계별 상태 텍스트
  - 로그 출력 (접을 수 있는 섹션)
  - 취소 버튼
  - QEMU 디스플레이 표시 옵션 (Cocoa 윈도우)

  **Step 4 — 완료**
  - 성공/실패 표시
  - 생성된 베이스라인 정보 요약
  - "샌드박스 시작" 바로가기 버튼

#### 7.2 `BaselineManagerView` — 베이스라인 목록 관리

- [ ] `src/MacSandbox/Views/BaselineManagerView.swift` 신규 생성
- [ ] 베이스라인 목록 표시:
  - 이름, 생성일, 디스크 크기, 상태
  - 상태 아이콘 (ready: 녹색, creating: 노랑 회전, error: 빨강)
- [ ] 액션:
  - "새 베이스라인 만들기" → SetupWizardView 열기
  - 베이스라인 선택 → 샌드박스 시작
  - 베이스라인 삭제 (확인 다이얼로그)
  - 베이스라인 복제

#### 7.3 `ContentView` 수정

- [ ] 네비게이션 구조 개선:
  - 탭 또는 사이드바에 "Setup" / "Sandbox" 모드 전환 추가
  - 또는 초기 화면에서 베이스라인이 없으면 SetupWizardView 자동 표시
- [ ] 베이스라인이 존재할 때: 베이스라인 선택 → 바로 샌드박스 시작 플로우

#### 7.4 `SandboxConfigView` 수정

- [ ] 베이스라인 선택 UI 추가:
  - 드롭다운/피커로 사용 가능한 베이스라인 목록 표시
  - 선택 시 `configuration.baseImagePath` 자동 설정
  - 베이스라인 상태 표시 (ready only 선택 가능)

---

### Phase 8: ESD 처리 (선택적 확장)

#### 8.1 ESD → ISO 변환

- [ ] ESD(Electronic Software Distribution)를 직접 사용하는 경우:
  - Windows 설치 프로그램이 ESD를 직접 처리 가능 (ISO 내에 포함된 형태)
  - 또는 ESD를 WIM으로 변환 후 부팅 가능 ISO 생성
- [ ] DISM 없이 ESD 처리하는 방법 검토:
  - `wimlib-imagex` (크로스 플랫폼 WIM 도구) 활용
  - `wimlib` Homebrew 패키지 번들링 검토
  - 또는: 사용자에게 ISO 형태로 제공하도록 안내 (가장 간단)

#### 8.2 Microsoft 공식 다운로드 자동화 (선택)

- [ ] UUP dump 등 서드파티 활용한 ARM64 ISO 생성 검토
- [ ] 법적/라이선스 검토 (Microsoft EULA 준수 확인)

---

### Phase 9: 테스트 및 검증

#### 9.1 단위 테스트

- [ ] `UnattendGenerator` 테스트:
  - 생성된 XML이 유효한지 검증
  - 필수 섹션 포함 여부 확인
  - 로케일/사용자명 파라미터 반영 확인
- [ ] `BaselineImage` Codable 테스트:
  - metadata.json 직렬화/역직렬화
- [ ] `DiskImageService` 확장 메서드 테스트:
  - 오버레이 + efi-vars 복사

#### 9.2 통합 테스트

- [ ] 실제 Windows 11 ARM64 ISO로 베이스라인 생성 E2E 테스트:
  - 다운로드 → 설치 → 베이스라인 저장 → 샌드박스 시작 → 종료 → 오버레이 삭제
- [ ] Unattend가 정상 작동하여 무인 설치가 완료되는지 확인
- [ ] 설치 후 자동 종료(shutdown)가 동작하는지 확인
- [ ] COW 오버레이에서 부팅이 정상적인지 확인
- [ ] 여러 번 샌드박스 시작/종료 반복 시 베이스라인 무결성 유지 확인

#### 9.3 엣지 케이스

- [ ] 설치 중 사용자가 앱을 종료하는 경우 처리
  - 미완성 베이스라인 상태 `.creating` → 재시작 시 정리 또는 재개 옵션
- [ ] 디스크 공간 부족 시 사전 검사 및 에러 메시지
- [ ] ISO 파일이 손상된 경우 (QEMU 비정상 종료 → 에러 처리)
- [ ] 베이스라인 생성 중 타임아웃 처리

---

### Phase 10: 빌드 및 배포

#### 10.1 의존성 업데이트

- [ ] `scripts/bundle_qemu.py` 수정:
  - `hdiutil`은 macOS 기본 제공 → 추가 번들링 불필요
  - (선택) `wimlib` 번들링 시 lockfile에 추가
- [ ] `build.sh` 수정:
  - 빌드 시 `Resources/templates/autounattend.xml` 번들링 (있는 경우)

#### 10.2 문서 업데이트

- [ ] README.md에 Setup Mode / Sandbox Mode 설명 추가
- [ ] 사용자 가이드: 베이스라인 생성 절차 설명
- [ ] 기술 문서: Unattend.xml 파라미터 설명

---

## 구현 우선순위

| 순서 | 항목 | 설명 | 의존성 |
| ------ | ------ | ------ | -------- |
| 1 | Phase 1 | 모델 정의 | 없음 |
| 2 | Phase 2 | Unattend.xml 생성 | 없음 |
| 3 | Phase 3 | Virtio 드라이버 확인 | 없음 |
| 4 | Phase 4.1–4.3 | BaselineBuilderService 핵심 | Phase 1, 2 |
| 5 | Phase 4.4 | 설치 완료 감지 | Phase 4.1–4.3 |
| 6 | Phase 4.5 | 베이스라인 관리 | Phase 4.1 |
| 7 | Phase 5 | Sandbox Mode 개선 | Phase 4.5 |
| 8 | Phase 6 | ViewModel 통합 | Phase 4, 5 |
| 9 | Phase 7 | UI 구현 | Phase 6 |
| 10 | Phase 8 | ESD 처리 확장 | Phase 4 |
| 11 | Phase 9 | 테스트 | Phase 7 |
| 12 | Phase 10 | 빌드/배포 | Phase 9 |

---

## 핵심 기술 결정 사항

### 1. Sysprep 미사용 결정 근거

- Sysprep은 OOBE 재진입 → 추가 부팅 시간 발생
- 베이스라인 이미지는 OOBE 완료 + 로그인 완료 상태 보존
- COW 오버레이가 매번 새 "인스턴스"를 제공하므로 sysprep 불필요
- 동일 SID 문제: 네트워크 격리(NAT) 환경이므로 무관

### 2. 설치 완료 감지 전략

- `FirstLogonCommands`에서 `shutdown /s /t 30` 실행이 가장 신뢰성 높음
- QEMU 프로세스 종료 = 설치 완료로 판단
- QMP는 보조 수단으로만 사용 (복잡도 대비 이점 적음)

### 3. 드라이버 전략 (ARM64)

- virtio-win이 ARM64를 지원하는지 먼저 확인 필요
- ARM64 미지원 시: NVMe 에뮬레이션 (`-device nvme`) 사용이 차선책
  - Windows에 NVMe 기본 드라이버 내장
  - 성능은 virtio-blk 대비 약간 저하되나 설치 호환성 보장

### 4. Unattend 전달 방식

- ISO로 패키징하는 방식 권장 (가장 호환성 높음)
- `hdiutil makehybrid`로 macOS에서 ISO 생성 가능
- virtio-9p는 드라이버 의존성 문제로 설치 단계에서 사용 불가

---

## 참고 자료

- [Microsoft Unattend 레퍼런스](https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/)
- [Windows PE 구성 요소](https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-setup)
- [virtio-win 드라이버](https://github.com/virtio-win/virtio-win-pkg-scripts)
- [QEMU ARM virt 머신](https://www.qemu.org/docs/master/system/arm/virt.html)
- [EDK2 AARCH64 UEFI](https://github.com/tianocore/edk2)
