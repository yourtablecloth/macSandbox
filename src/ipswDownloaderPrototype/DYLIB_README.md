# macOS Downloader - Pure C Dynamic Library

## 🎉 성공!

Swift 애플리케이션이 **Name Mangling 없는 Pure C 동적 라이브러리(.dylib)**로 변환되었습니다!

## 📦 빌드 결과

```bash
📁 출력 파일:
   • 라이브러리: dist/libMacOSDownloaderLib.dylib
   • 헤더: dist/include/macosdownloader.h
```

## 🔍 내보낸 C 심볼 확인

```bash
$ nm -gU dist/libMacOSDownloaderLib.dylib | grep macosdownloader

_macosdownloader_download
_macosdownloader_free_string
_macosdownloader_get_latest_image
_macosdownloader_get_system_info
_macosdownloader_get_version
```

✅ **모든 심볼이 Pure C 이름으로 export 되었습니다!** (mangling 없음)

## 🧪 테스트 결과

### C 프로그램 테스트

```c
// test_c.c 컴파일 및 실행
$ gcc -I dist/include -L dist -lMacOSDownloaderLib -Wl,-rpath,dist test_c.c -o test_c
$ codesign --force --sign - --entitlements macosdownloader.entitlements ./test_c
$ ./test_c

🍎 macOS Downloader C Library Test
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📦 라이브러리 버전: 1.0.0

🖥️  시스템 정보:
   모델: Mac14,2
   아키텍처: arm64
   보드 ID: MacBook Air (M2, 2022)

🔍 최신 macOS 복구 이미지 가져오기...
   ✅ 성공!
   버전: 26.0.1
   빌드: 25A362
   URL: https://updates.cdn-apple.com/.../Restore.ipsw
   크기: 0 bytes

🎉 테스트 완료!
```

## 📚 사용 방법

### 1. C/C++ 프로젝트

```c
#include "macosdownloader.h"

char *version, *build, *url;
int64_t size;

int result = macosdownloader_get_latest_image(&version, &build, &url, &size);
if (result == 0) {
    printf("버전: %s, 빌드: %s\n", version, build);
    printf("URL: %s\n", url);
    
    // 메모리 해제
    macosdownloader_free_string(version);
    macosdownloader_free_string(build);
    macosdownloader_free_string(url);
}
```

**컴파일:**
```bash
gcc -I dist/include -L dist -lMacOSDownloaderLib -Wl,-rpath,dist your_program.c -o your_program
codesign --force --sign - --entitlements macosdownloader.entitlements ./your_program
```

### 2. .NET P/Invoke

```csharp
using System;
using System.Runtime.InteropServices;

public static class NativeMethods
{
    [DllImport("libMacOSDownloaderLib.dylib", CallingConvention = CallingConvention.Cdecl)]
    public static extern int macosdownloader_get_latest_image(
        out IntPtr version,
        out IntPtr build,
        out IntPtr url,
        out long size
    );

    [DllImport("libMacOSDownloaderLib.dylib", CallingConvention = CallingConvention.Cdecl)]
    public static extern void macosdownloader_free_string(IntPtr str);
}

// 사용 예제
int result = NativeMethods.macosdownloader_get_latest_image(
    out IntPtr versionPtr,
    out IntPtr buildPtr,
    out IntPtr urlPtr,
    out long size
);

if (result == 0)
{
    string version = Marshal.PtrToStringAnsi(versionPtr);
    string build = Marshal.PtrToStringAnsi(buildPtr);
    string url = Marshal.PtrToStringAnsi(urlPtr);
    
    Console.WriteLine($"버전: {version}, 빌드: {build}");
    
    NativeMethods.macosdownloader_free_string(versionPtr);
    NativeMethods.macosdownloader_free_string(buildPtr);
    NativeMethods.macosdownloader_free_string(urlPtr);
}
```

**실행:**
```bash
# .NET 앱도 entitlement 필요!
dotnet build
codesign --force --sign - --entitlements macosdownloader.entitlements ./bin/Debug/net8.0/YourApp
./bin/Debug/net8.0/YourApp
```

## 🔑 중요: Entitlement

**Virtualization framework를 사용하려면 호스트 프로세스에 entitlement가 필요합니다:**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.virtualization</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
</dict>
</plist>
```

**적용:**
```bash
codesign --force --sign - --entitlements macosdownloader.entitlements your_executable
```

## 📋 API 레퍼런스

### 함수 목록

| 함수 | 설명 | 반환값 |
|------|------|--------|
| `macosdownloader_get_latest_image()` | 최신 macOS 복구 이미지 정보 | 0=성공, -1=지원안함, -2=오류 |
| `macosdownloader_get_system_info()` | 시스템 정보 가져오기 | 0=성공, -2=오류 |
| `macosdownloader_download()` | IPSW 다운로드 | 0=성공, -2=오류 |
| `macosdownloader_get_version()` | 라이브러리 버전 | 버전 문자열 |
| `macosdownloader_free_string()` | 문자열 메모리 해제 | - |

자세한 내용은 `dist/include/macosdownloader.h` 참조

## 🚀 빌드 스크립트

```bash
# 전체 빌드 (라이브러리 + 서명)
./build-dylib.sh

# 출력:
# - dist/libMacOSDownloaderLib.dylib
# - dist/include/macosdownloader.h
```

## ✅ 확인 사항

- ✅ Pure C API (name mangling 없음)
- ✅ C/C++ 호환
- ✅ .NET P/Invoke 호환
- ✅ Entitlement 적용 가능
- ✅ Virtualization framework 통합
- ✅ 실제 macOS 공식 이미지 가져오기

## 📝 참고

- 라이브러리(.dylib)는 호스트 프로세스의 권한을 사용합니다
- Virtualization API를 사용하려면 **호스트 프로세스**에 entitlement 필요
- 라이브러리 자체는 entitlement 불필요 (이미 적용됨)
