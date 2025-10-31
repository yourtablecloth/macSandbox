# Virtualization Framework와 Entitlements

## 문제 상황

현재 `VZMacOSRestoreImage.latestSupported` API 호출 시 다음 오류가 발생합니다:

```text
NSError domain: VZErrorDomain
NSError code: 10001
The restore image catalog failed to load.
Installation service returned an unexpected error.
```

## 원인

Virtualization framework를 사용하려면 다음 entitlement가 필요합니다:

- `com.apple.security.virtualization`
- `com.apple.security.network.client`
- `com.apple.security.app-sandbox`

**Swift Package Manager로 빌드한 CLI 도구는 entitlement를 포함하지 않습니다.**

## 해결 방법

### 옵션 1: Xcode 프로젝트로 빌드 (권장)

```bash
# Xcode 프로젝트 생성
./setup-xcode.sh

# 또는 수동으로:
swift package generate-xcodeproj
open macosdownloader.xcodeproj
```

#### Xcode에서 설정

1. Target `macosdownloader` 선택
2. **Signing & Capabilities** 탭
3. **+ Capability** 클릭
4. 다음 항목 추가:
   - **App Sandbox**
   - **Outgoing Connections (Client)** ✓
   - **User Selected File (Read/Write)** ✓

5. **Build Settings**에서:
   - `Code Signing Entitlements` → `macosdownloader.entitlements`

6. 빌드 (⌘+B)

#### 서명 및 실행

```bash
# 개발자 ID로 서명 (선택사항)
codesign --force --sign "Developer ID Application: Your Name" \
    --entitlements macosdownloader.entitlements \
    --options runtime \
    ./DerivedData/macosdownloader/Build/Products/Release/macosdownloader

# 실행
./DerivedData/macosdownloader/Build/Products/Release/macosdownloader --list
```

### 옵션 2: Ad-hoc 서명으로 로컬 테스트

```bash
# 릴리즈 빌드
swift build -c release

# Ad-hoc 서명 (로컬 머신에서만 작동)
codesign --force --sign - \
    --entitlements macosdownloader.entitlements \
    .build/release/macosdownloader

# 실행
.build/release/macosdownloader --list
```

**주의**: Ad-hoc 서명은 로컬 개발 머신에서만 작동하며, Virtualization framework가 여전히 제한될 수 있습니다.

### 옵션 3: Virtualization API 없이 사용

현재 구현은 Virtualization API가 실패하면 자동으로 폴백합니다:

```bash
# 샘플 데이터로 작동
.build/debug/macosdownloader --list
```

출력:

```text
⚠️  Virtualization framework 오류: ...
⚠️  실제 API에서 데이터를 가져올 수 없어 샘플 데이터를 표시합니다.
✅ 3개의 이미지를 찾았습니다.
```

## Entitlements 파일

프로젝트에 포함된 `macosdownloader.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.virtualization</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>
    <key>com.apple.security.app-sandbox</key>
    <true/>
</dict>
</plist>
```

## 테스트 방법

### 1. Entitlement 확인

```bash
codesign -d --entitlements - .build/release/macosdownloader
```

### 2. 서명 정보 확인

```bash
codesign -dvvv .build/release/macosdownloader
```

### 3. 실행 테스트

```bash
.build/release/macosdownloader --list --verbose
```

## 현재 상태

- ✅ Virtualization framework 통합 코드 완료
- ✅ Entitlements 파일 생성
- ✅ 폴백 메커니즘 작동
- ⚠️  Entitlement 적용은 Xcode 또는 수동 서명 필요
- ⚠️  Swift PM만으로는 Virtualization API 사용 불가

## 권장 사항

1. **개발/테스트**: 현재 상태로 사용 (샘플 데이터)
2. **프로덕션**: Xcode 프로젝트로 빌드 + 서명
3. **배포**: Developer ID 서명 + 공증(Notarization)

## 참고 문서

- [Apple: Virtualization Framework](https://developer.apple.com/documentation/virtualization)
- [Apple: VZMacOSRestoreImage](https://developer.apple.com/documentation/virtualization/vzmacosrestoreimage/latestsupported)
- [Apple: Entitlements](https://developer.apple.com/documentation/bundleresources/entitlements)
- [Apple: Code Signing](https://developer.apple.com/support/code-signing/)
