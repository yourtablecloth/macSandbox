# macOS IPSW Downloader

macOS IPSW 이미지를 현재 시스템 기준으로 다운로드할 수 있는 Swift CLI 유틸리티입니다.

## 기능

- 🔍 현재 시스템과 호환되는 macOS IPSW/복구 이미지 자동 검색
- 📥 간편한 다운로드 인터페이스
- 📊 실시간 다운로드 진행률 표시
- 🎯 여러 소스에서 이미지 정보 수집 (ipsw.me, Apple 카탈로그)
- 💾 중복 다운로드 방지

## 요구사항

- macOS 13.0 이상
- Swift 5.9 이상

## 설치

```bash
# 저장소 클론
git clone <repository-url>
cd macosdownloader

# 빌드 및 서명 (권장)
./build.sh

# 또는 수동 빌드
swift build -c release
codesign --force --sign - --entitlements macosdownloader.entitlements .build/release/macosdownloader

# 실행 파일 복사 (선택사항)
cp .build/release/macosdownloader /usr/local/bin/
```

## 중요: Entitlement 설정

Virtualization framework를 사용하여 **실제 Apple 공식 IPSW 이미지**를 가져오려면 entitlement가 필요합니다.

`./build.sh` 스크립트는 자동으로 entitlement를 적용합니다.

수동으로 서명하려면:

```bash
codesign --force --sign - --entitlements macosdownloader.entitlements .build/release/macosdownloader
```

서명 확인:

```bash
codesign -d --entitlements - .build/release/macosdownloader
```

## 사용법

### 기본 사용

```bash
# 현재 디렉토리에 다운로드
./macosdownloader

# 특정 디렉토리에 다운로드
./macosdownloader --output ~/Downloads

# 줄여서
./macosdownloader -o ~/Downloads
```

### 목록만 확인

```bash
# 다운로드 없이 사용 가능한 이미지 목록만 표시
./macosdownloader --list
```

### 상세 정보 출력

```bash
# 시스템 정보와 URL 등 상세 정보 표시
./macosdownloader --verbose

# 목록 + 상세 정보
./macosdownloader --list --verbose
```

### 도움말

```bash
./macosdownloader --help
```

## 예제 출력

```text
🍎 macOS IPSW 다운로더
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

🔍 호환되는 IPSW 이미지를 검색 중...
✅ 3개의 이미지를 찾았습니다.

[1] macOS Recovery 14.2
    버전: 14.2
    빌드: 23C64
    크기: 12.5 GB

[2] macOS Recovery 14.1.1
    버전: 14.1.1
    빌드: 23B81
    크기: 12.4 GB

[3] macOS Recovery 14.0
    버전: 14.0
    빌드: 23A344
    크기: 12.3 GB

다운로드할 이미지 번호를 입력하세요 (1-3): 1

📥 다운로드 중: macOS Recovery 14.2
진행률: 45.2% (5.6 GB / 12.5 GB)
```

## 작동 원리

1. **시스템 정보 수집**: `sysctl`과 `ioreg`를 사용하여 현재 Mac의 하드웨어 정보를 수집합니다.
2. **이미지 검색**:
   - ipsw.me API
   - Apple 공식 소프트웨어 업데이트 카탈로그
3. **호환성 필터링**: 현재 시스템과 호환되는 이미지만 표시합니다.
4. **다운로드**: 선택한 이미지를 진행률과 함께 다운로드합니다.

## 데이터 소스

- **Apple Virtualization Framework** (macOS 12.0+) - 공식 macOS 복구 이미지 (권장)
- Apple 소프트웨어 업데이트 카탈로그 - 공식 macOS 업데이트 정보
- 샘플 데이터 - API 실패시 폴백

### Virtualization Framework 사용

최신 macOS에서 Apple의 Virtualization framework를 통해 **실제 공식 복구 이미지**를 가져옵니다:

```bash
# Entitlement가 적용된 빌드 실행
./build.sh

# 출력 예시:
# ✅ Virtualization framework에서 공식 이미지를 가져왔습니다.
# [1] macOS Sequoia 15.0.1 (공식)
#     버전: 15.0.1
#     빌드: 24A348
#     크기: 18.27 GB
#     URL: https://updates.cdn-apple.com/.../Restore.ipsw
```

## 주의사항

- 네트워크 연결이 필요합니다.
- IPSW 파일은 매우 크므로 (10GB 이상) 충분한 저장 공간이 필요합니다.
- 다운로드 시간은 인터넷 속도에 따라 다릅니다.
- **Virtualization framework 사용을 위해 entitlement 서명이 필요합니다.** (`./build.sh` 자동 처리)

## 트러블슈팅

### "샘플 데이터를 표시합니다" 메시지가 나올 때

Entitlement가 적용되지 않았을 수 있습니다:

```bash
# 재서명
codesign --force --sign - --entitlements macosdownloader.entitlements .build/release/macosdownloader

# 확인
codesign -d --entitlements - .build/release/macosdownloader

# 다시 실행
.build/release/macosdownloader --list
```

자세한 내용은 [VIRTUALIZATION_SETUP.md](VIRTUALIZATION_SETUP.md)를 참고하세요.

## 개발 노트

### 빌드 완료 ✅

프로젝트가 성공적으로 빌드되었으며 다음 기능이 작동합니다:

- ✅ 시스템 정보 감지 (모델, 아키텍처, 보드 ID)
- ✅ Apple Silicon / Intel 구분
- ✅ 이미지 목록 표시
- ✅ 명령줄 인터페이스 (ArgumentParser)
- ✅ 다운로드 진행률 표시 기능
- ⚠️  실제 Apple API 연동 (샘플 데이터 사용 중)

### 실행 파일 위치

```bash
# 디버그 빌드
.build/debug/macosdownloader

# 릴리즈 빌드 (최적화됨, 권장)
.build/release/macosdownloader
```

### 빠른 테스트

```bash
# 시스템 정보 확인
.build/release/macosdownloader --list --verbose
```

## 라이선스

MIT

## 기여

이슈와 풀 리퀘스트를 환영합니다!
