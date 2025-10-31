# macOS IPSW Downloader - 빌드 및 테스트 결과

## ✅ 빌드 성공

프로젝트가 성공적으로 빌드되었으며, **실제 Apple Virtualization API**를 통해 공식 IPSW 이미지를 가져옵니다!

### 해결된 문제들

1. **`@main` 속성 오류** - Package.swift에 `-parse-as-library` 플래그 추가
2. **`formatBytes` 중복 선언** - Utilities.swift로 분리
3. **비동기 명령 availability 오류** - `@available(macOS 10.15, *)` 추가
4. **Virtualization framework 권한 오류** - Entitlement 파일 생성 및 서명 적용

## 🎯 작동하는 기능

### 1. 시스템 정보 감지

```text
시스템 정보:
  모델: Mac14,2
  아키텍처: arm64
  보드 ID: MacBook Air (M2, 2022)
```

### 2. 실제 Apple 공식 이미지 가져오기 ✨

**Virtualization framework를 통한 실시간 공식 이미지 조회:**

```text
✅ Virtualization framework에서 공식 이미지를 가져왔습니다.
[1] macOS macOS 26.0.1 (공식)
    버전: 26.0.1
    빌드: 25A362
    크기: 18.27 GB
    URL: https://updates.cdn-apple.com/.../Restore.ipsw
```

### 3. 이미지 목록 표시

- Apple Silicon과 Intel Mac을 자동 구분
- 버전별 정렬 (최신순)
- 파일 크기 자동 포맷팅
- 실제 Apple CDN URL 제공

### 4. 명령줄 옵션

- `--help`: 도움말
- `--list`: 목록만 표시
- `--verbose`: 상세 정보
- `-o, --output`: 다운로드 디렉토리

## 📦 사용 방법

### 빌드 (Entitlement 자동 적용)

```bash
./build.sh
```

또는 수동:

```bash
swift build -c release
codesign --force --sign - --entitlements macosdownloader.entitlements .build/release/macosdownloader
```

### 실행

```bash
# 목록 확인
.build/release/macosdownloader --list

# 상세 정보 포함
.build/release/macosdownloader --list --verbose

# 다운로드 (대화형)
.build/release/macosdownloader -o ~/Downloads
```

## 📝 현재 상태

- ✅ 핵심 기능 구현 완료
- ✅ 빌드 성공
- ✅ CLI 인터페이스 작동
- ✅ 시스템 정보 감지
- ✅ **Virtualization framework 통합 완료**
- ✅ **실제 Apple 공식 IPSW 이미지 가져오기 성공**
- ✅ **Entitlement 설정 및 코드 서명 완료**

## 🔄 다음 단계 (선택사항)

1. **다운로드 기능 개선**
   - 재시작 지원 (resume)
   - 병렬 다운로드
   - 체크섬 검증

2. **추가 기능**
   - 특정 버전 검색
   - 여러 이미지 비교
   - 다운로드 히스토리

3. **배포**
   - Homebrew formula 생성
   - GitHub Releases
   - Developer ID 서명 및 공증

## 🎉 결론

프로젝트가 **완전히 작동**합니다!

- ✅ Apple Virtualization framework 통합 성공
- ✅ 실제 공식 IPSW 이미지 URL 가져오기 성공
- ✅ Entitlement 설정 완료
- ✅ 모든 인프라 준비 완료

**현재 상태로 실제 macOS 복구 이미지를 다운로드할 수 있습니다!**
