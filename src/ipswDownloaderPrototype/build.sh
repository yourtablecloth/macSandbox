#!/bin/bash

# macOS IPSW Downloader 빌드 및 실행 스크립트

set -e

echo "🔨 빌드 중..."
swift build -c release

echo ""
echo "🔐 Entitlement 적용 중..."
codesign --force --sign - \
    --entitlements macosdownloader.entitlements \
    .build/release/macosdownloader

echo ""
echo "✅ 빌드 완료!"
echo ""
echo "실행 파일 위치: .build/release/macosdownloader"
echo ""
echo "사용 예시:"
echo "  .build/release/macosdownloader --help"
echo "  .build/release/macosdownloader --list"
echo "  .build/release/macosdownloader --list --verbose"
echo "  .build/release/macosdownloader -o ~/Downloads"
echo ""

# 실행 여부 확인
read -p "지금 실행하시겠습니까? (y/n): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]
then
    .build/release/macosdownloader --list --verbose
fi
