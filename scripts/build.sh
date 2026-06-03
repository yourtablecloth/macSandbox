#!/bin/bash
set -euo pipefail

# MacSandbox 빌드 스크립트 (QEMU + HVF)
# 사용법: ./scripts/build.sh [debug|release]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
CONFIG="${1:-debug}"

cd "${PROJECT_DIR}"

QEMU_BIN="vendor/qemu/bin/qemu-system-aarch64"
ENTITLEMENTS="${SCRIPT_DIR}/hypervisor.entitlements"

if [ ! -x "${QEMU_BIN}" ]; then
    echo "오류: ${QEMU_BIN} 이(가) 없습니다. QEMU(arm64) 번들이 필요합니다." >&2
    exit 1
fi

# HVF 사용을 위해 QEMU 바이너리에 hypervisor entitlement 서명 (멱등)
if ! codesign -d --entitlements - "${QEMU_BIN}" 2>/dev/null | grep -q "com.apple.security.hypervisor"; then
    echo "QEMU에 hypervisor entitlement 서명 중..."
    codesign --force --sign - --entitlements "${ENTITLEMENTS}" "${QEMU_BIN}"
else
    echo "QEMU hypervisor entitlement 확인됨."
fi

echo ""
echo "Swift 빌드 (${CONFIG})..."
if [ "${CONFIG}" = "release" ]; then
    swift build -c release
else
    swift build
fi

echo ""
echo "빌드 완료. 실행: swift run MacSandbox"
