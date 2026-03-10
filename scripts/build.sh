#!/bin/bash
set -euo pipefail

# MacSandbox 빌드 + QEMU 번들 패키징 스크립트
# 사용법: ./scripts/build.sh [debug|release]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
CONFIG="${1:-debug}"

cd "${PROJECT_DIR}"

# QEMU 번들이 없으면 자동 생성
if [ ! -f "vendor/qemu/bin/qemu-system-x86_64" ]; then
    echo "QEMU 번들이 없습니다. 다운로드를 시작합니다..."
    python3 "${SCRIPT_DIR}/bundle_qemu.py"
fi

# Swift 빌드
echo ""
echo "Swift 빌드 (${CONFIG})..."
if [ "${CONFIG}" = "release" ]; then
    swift build -c release
else
    swift build
fi

echo ""
echo "빌드 완료."
echo "실행: swift run MacSandbox"
