#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Nam Jung Hyun (rkttu)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
QEMU_TAG="v10.2.1"
EDK2_COMMIT="4dfdca63a93497203f197ec98ba20e2327e4afe4"
OUTPUT_DIR="${MACSANDBOX_FIRMWARE_OUTPUT_DIR:-$PROJECT_DIR/.build/firmware}"
OUTPUT_FIRMWARE="$OUTPUT_DIR/edk2-aarch64-code.fd"
OUTPUT_MANIFEST="$OUTPUT_DIR/macsandbox-firmware.json"

run_in_container() {
    local engine="$1"
    local image="docker.io/library/ubuntu:24.04"
    local -a resource_args=(--cpus 4 --memory 4G)

    if [[ "$engine" == "container" ]]; then
        resource_args+=(--progress plain)
    fi

    echo "Building EDK II in an Ubuntu container with $engine..."
    "$engine" run --rm \
        "${resource_args[@]}" \
        -v "$PROJECT_DIR:/workspace" \
        -w /workspace \
        "$image" \
        bash -lc 'apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends acpica-tools build-essential ca-certificates gcc-aarch64-linux-gnu git nasm python3 uuid-dev && scripts/build_firmware.sh --native'
}

if [[ "${1:-}" != "--native" ]] && [[ "$(uname -s)" != "Linux" ]]; then
    for engine in docker podman container; do
        if command -v "$engine" >/dev/null 2>&1; then
            run_in_container "$engine"
            exit 0
        fi
    done

    echo "Error: Docker, Podman, or Apple container is required for the Linux EDK II toolchain." >&2
    exit 1
fi

for command_name in aarch64-linux-gnu-gcc git iasl make nasm python3; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "Error: required command is missing: $command_name" >&2
        exit 1
    fi
done

WORK_DIR="$(mktemp -d)"
cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

echo "Cloning QEMU $QEMU_TAG and its pinned EDK II submodule..."
git clone --quiet --depth 1 --branch "$QEMU_TAG" https://gitlab.com/qemu-project/qemu.git "$WORK_DIR/qemu"
git -C "$WORK_DIR/qemu" submodule update --init --depth 1 roms/edk2
# ArmVirt needs several EDK II top-level submodules. Do not recurse into
# OpenSSL's test-only submodules, which are not part of the firmware build.
git -C "$WORK_DIR/qemu/roms/edk2" submodule update --init --depth 1

actual_edk2_commit="$(git -C "$WORK_DIR/qemu/roms/edk2" rev-parse HEAD)"
if [[ "$actual_edk2_commit" != "$EDK2_COMMIT" ]]; then
    echo "Error: QEMU $QEMU_TAG points to unexpected EDK II commit $actual_edk2_commit" >&2
    exit 1
fi

git -C "$WORK_DIR/qemu/roms/edk2" apply --unidiff-zero --ignore-space-change "$PROJECT_DIR/firmware/macsandbox-edk2.patch"
cp "$PROJECT_DIR/assets/BootLogo.bmp" "$WORK_DIR/qemu/roms/edk2/MdeModulePkg/Logo/Logo.bmp"

jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
(
    cd "$WORK_DIR/qemu/roms"
    python3 edk2-build.py \
        --config edk2-build.config \
        --match armvirt.aa64 \
        --jobs "$jobs" \
        --version-override "MacSandbox-edk2-${EDK2_COMMIT:0:12}" \
        --silent
)

built_firmware="$WORK_DIR/qemu/pc-bios/edk2-aarch64-code.fd"
if [[ ! -f "$built_firmware" ]]; then
    echo "Error: EDK II build did not produce $built_firmware" >&2
    exit 1
fi

built_size="$(wc -c < "$built_firmware" | tr -d ' ')"
if [[ "$built_size" != "67108864" ]]; then
    echo "Error: firmware size is $built_size bytes, expected 67108864" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
cp "$built_firmware" "$OUTPUT_FIRMWARE"
python3 - "$OUTPUT_FIRMWARE" "$OUTPUT_MANIFEST" "$QEMU_TAG" "$EDK2_COMMIT" <<'PY'
import hashlib
import json
import pathlib
import sys

firmware = pathlib.Path(sys.argv[1])
manifest = pathlib.Path(sys.argv[2])
manifest.write_text(json.dumps({
    "format_version": 1,
    "qemu_tag": sys.argv[3],
    "edk2_commit": sys.argv[4],
    "firmware": firmware.name,
    "sha256": hashlib.sha256(firmware.read_bytes()).hexdigest(),
}, indent=2) + "\n")
PY

vendor_share="$PROJECT_DIR/vendor/qemu/share/qemu"
if [[ -d "$vendor_share" ]]; then
    cp "$OUTPUT_FIRMWARE" "$vendor_share/edk2-aarch64-code.fd"
    cp "$OUTPUT_MANIFEST" "$vendor_share/macsandbox-firmware.json"
    echo "Installed custom firmware into vendor/qemu/share/qemu."
fi

echo "Custom firmware: $OUTPUT_FIRMWARE"
echo "Manifest: $OUTPUT_MANIFEST"
