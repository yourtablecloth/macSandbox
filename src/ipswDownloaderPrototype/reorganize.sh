#!/bin/bash

set -e

echo "🔄 디렉토리 구조 재구성 중..."

# 디렉토리 생성
mkdir -p Sources/Core
mkdir -p Sources/CLI
mkdir -p Sources/CLib/include

# 공유 코드를 Core로 이동
if [ -f "Sources/SystemInfo.swift" ]; then
    mv Sources/SystemInfo.swift Sources/Core/
fi

if [ -f "Sources/IPSWFetcher.swift" ]; then
    mv Sources/IPSWFetcher.swift Sources/Core/
fi

if [ -f "Sources/IPSWDownloader.swift" ]; then
    mv Sources/IPSWDownloader.swift Sources/Core/
fi

if [ -f "Sources/Utilities.swift" ]; then
    mv Sources/Utilities.swift Sources/Core/
fi

if [ -f "Sources/VirtualizationImageFetcher.swift" ]; then
    mv Sources/VirtualizationImageFetcher.swift Sources/Core/
fi

# main.swift를 CLI로 이동
if [ -f "Sources/main.swift" ]; then
    mv Sources/main.swift Sources/CLI/
fi

echo "✅ 디렉토리 구조 재구성 완료"
echo ""
echo "📁 Sources/"
echo "   ├── CLI/           (CLI 실행 파일)"
echo "   ├── Core/          (공유 코어 로직)"
echo "   └── CLib/          (C 호환 라이브러리)"
echo "       └── include/   (C 헤더 파일)"
