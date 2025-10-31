#!/bin/bash

set -e

echo "🔨 macOS Downloader 동적 라이브러리 빌드 중..."

# 릴리즈 빌드
echo "📦 Swift 패키지 빌드 중..."
swift build -c release --product MacOSDownloaderLib

# 라이브러리 경로
DYLIB_PATH=".build/release/libMacOSDownloaderLib.dylib"

if [ ! -f "$DYLIB_PATH" ]; then
    echo "❌ 라이브러리 파일을 찾을 수 없습니다: $DYLIB_PATH"
    exit 1
fi

echo "✅ 라이브러리 빌드 완료: $DYLIB_PATH"

# Entitlement 적용
echo "🔐 코드 서명 중..."
codesign --force --sign - \
    --entitlements macosdownloader.entitlements \
    "$DYLIB_PATH"

echo "✅ 코드 서명 완료"

# 서명 확인
echo ""
echo "📋 서명 정보:"
codesign -dvvv "$DYLIB_PATH" 2>&1 | grep -E "Signature|Identifier|Entitlements" || true

echo ""
echo "📋 Entitlements:"
codesign -d --entitlements - "$DYLIB_PATH" 2>&1

# 심볼 확인
echo ""
echo "📋 내보낸 C 심볼:"
nm -gU "$DYLIB_PATH" | grep macosdownloader || echo "  (심볼을 찾을 수 없습니다)"

# 배포 디렉토리 생성
echo ""
echo "📄 배포 파일 준비 중..."
mkdir -p dist/include
cp Sources/CLib/include/macosdownloader.h dist/include/
cp "$DYLIB_PATH" dist/

echo ""
echo "🎉 빌드 완료!"
echo ""
echo "📁 출력 파일:"
echo "   • 라이브러리: dist/libMacOSDownloaderLib.dylib"
echo "   • 헤더: dist/include/macosdownloader.h"
echo ""
echo "📝 사용 방법:"
echo "   1. C/C++ 프로젝트:"
echo "      gcc -I dist/include -L dist -lMacOSDownloaderLib your_program.c"
echo ""
echo "   2. .NET P/Invoke:"
echo "      [DllImport(\"libMacOSDownloaderLib.dylib\")]"
echo ""
