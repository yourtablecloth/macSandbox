#!/bin/bash
set -euo pipefail

# MacSandbox build script (QEMU + HVF)
# Usage: ./scripts/build.sh [debug|release]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
CONFIG="${1:-debug}"

cd "${PROJECT_DIR}"

QEMU_BIN="vendor/qemu/bin/qemu-system-aarch64"
ENTITLEMENTS="${SCRIPT_DIR}/hypervisor.entitlements"

if [ ! -x "${QEMU_BIN}" ]; then
    echo "Error: ${QEMU_BIN} is missing. A QEMU (arm64) bundle is required." >&2
    exit 1
fi

# Code-sign the QEMU binary with the hypervisor entitlement to enable HVF (idempotent)
if ! codesign -d --entitlements - "${QEMU_BIN}" 2>/dev/null | grep -q "com.apple.security.hypervisor"; then
    echo "Code-signing QEMU with the hypervisor entitlement..."
    codesign --force --sign - --entitlements "${ENTITLEMENTS}" "${QEMU_BIN}"
else
    echo "QEMU hypervisor entitlement confirmed."
fi

echo ""
echo "Swift build (${CONFIG})..."
if [ "${CONFIG}" = "release" ]; then
    swift build -c release
else
    swift build
fi

echo ""
echo "Build complete. Run: swift run MacSandbox"
