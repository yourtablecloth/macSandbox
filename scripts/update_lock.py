#!/usr/bin/env python3
"""
MacSandbox QEMU Lockfile Updater
=================================
Homebrew API에서 최신 bottle 정보를 조회하여
qemu-bottles.lock.json을 갱신합니다.

사용법:
    python3 scripts/update_lock.py [--tag arm64_tahoe] [--output PATH]
    python3 scripts/update_lock.py --check   # GHCR에 bottle이 아직 존재하는지 확인

의존성: Python 3.9+ 표준 라이브러리만 사용
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import date
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_LOCKFILE = SCRIPT_DIR / "qemu-bottles.lock.json"

# Homebrew formulae API
HOMEBREW_API = "https://formulae.brew.sh/api/formula"

# 번들에 필요한 패키지 목록 (qemu + 전이 의존성)
REQUIRED_PACKAGES = [
    "qemu",
    "capstone",
    "dtc",
    "glib",
    "gnutls",
    "jpeg-turbo",
    "libpng",
    "libslirp",
    "libssh",
    "libusb",
    "lzo",
    "ncurses",
    "pixman",
    "snappy",
    "vde",
    "zstd",
    # glib 의존성
    "pcre2",
    "gettext",
    # gnutls 의존성
    "nettle",
    "libtasn1",
    "libunistring",
    "p11-kit",
    "ca-certificates",
    "gmp",
    # libssh 의존성
    "openssl@3",
    # gnutls 추가 의존성
    "libidn2",
    "unbound",
    # unbound 의존성
    "libevent",
    "libnghttp2",
]


def fetch_formula(package: str) -> dict:
    """Homebrew API에서 formula 정보를 가져옵니다."""
    # @ → %40 (URL encoding은 하지 않고 Homebrew API는 @ 그대로 사용)
    url = f"{HOMEBREW_API}/{package}.json"
    req = urllib.request.Request(url, headers={
        "User-Agent": "MacSandbox-LockUpdater/1.0",
    })
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read())
    except Exception as e:
        print(f"  오류: {package} 정보를 가져올 수 없습니다 — {e}", file=sys.stderr)
        return {}


def extract_bottle_info(formula: dict, tag: str) -> dict | None:
    """formula JSON에서 bottle 정보를 추출합니다."""
    try:
        bottle = formula["bottle"]["stable"]
    except (KeyError, TypeError):
        return None

    # 지정 tag → all → None
    files = bottle.get("files", {})
    bottle_file = files.get(tag) or files.get("all")
    if not bottle_file:
        return None

    sha256 = bottle_file["sha256"]
    cellar = bottle_file.get("cellar", ":any")

    # filename 계산
    version = formula["versions"]["stable"]
    revision = formula.get("revision", 0)
    ver_str = f"{version}_{revision}" if revision else version

    name = formula["name"]
    actual_tag = tag if tag in files else "all"

    # Homebrew 표준 파일명 패턴
    # {sha256prefix}--{name}--{version}.{tag}.bottle[.rebuild].tar.gz
    # 정확한 파일명은 API에 없으므로, 다운로드 시 sha256만으로 GHCR에서 가져옴
    # 하지만 캐시 식별을 위해 filename을 기록해둡니다
    filename = f"{name}--{ver_str}.{actual_tag}.bottle.tar.gz"

    return {
        "version": ver_str,
        "sha256": sha256,
        "filename": filename,
    }


# ---------------------------------------------------------------------------
# GHCR 가용성 확인
# ---------------------------------------------------------------------------

GHCR_BASE = "https://ghcr.io/v2/homebrew/core"


def _ghcr_token(package: str) -> str:
    """GHCR 익명 bearer 토큰을 획득합니다."""
    pkg_path = package.replace("@", "/")
    token_url = (
        f"https://ghcr.io/token?"
        f"scope=repository%3Ahomebrew%2Fcore%2F{urllib.parse.quote(pkg_path, safe='')}%3Apull"
    )
    req = urllib.request.Request(token_url, headers={
        "User-Agent": "MacSandbox-LockUpdater/1.0",
    })
    with urllib.request.urlopen(req) as resp:
        data = json.loads(resp.read())
    return data["token"]


def check_ghcr_availability(lockfile_path: Path) -> None:
    """lockfile의 모든 bottle이 GHCR에 아직 존재하는지 HEAD 요청으로 확인합니다."""
    if not lockfile_path.exists():
        sys.exit(f"오류: lockfile이 없습니다 — {lockfile_path}")

    with open(lockfile_path) as f:
        lockdata = json.load(f)

    packages = lockdata.get("packages", {})
    print(f"GHCR bottle 가용성 확인 중... ({len(packages)}개 패키지)")
    print()

    available = 0
    gone = 0
    errors_list: list[str] = []

    for pkg_name, pkg_info in packages.items():
        sha = pkg_info["sha256"]
        pkg_path = pkg_name.replace("@", "/")
        url = f"{GHCR_BASE}/{pkg_path}/blobs/sha256:{sha}"

        try:
            token = _ghcr_token(pkg_name)
            req = urllib.request.Request(url, method="HEAD", headers={
                "Accept": "application/vnd.oci.image.layer.v1.tar+gzip",
                "Authorization": f"Bearer {token}",
                "User-Agent": "MacSandbox-LockUpdater/1.0",
            })
            with urllib.request.urlopen(req):
                pass
            print(f"  ✓ {pkg_name} ({pkg_info['version']})")
            available += 1
        except urllib.error.HTTPError as e:
            if e.code in (404, 410):
                print(f"  ✗ {pkg_name} ({pkg_info['version']}) — 삭제됨!")
                gone += 1
                errors_list.append(pkg_name)
            else:
                print(f"  ? {pkg_name} ({pkg_info['version']}) — HTTP {e.code}")
                errors_list.append(pkg_name)
        except Exception as e:
            print(f"  ? {pkg_name} ({pkg_info['version']}) — {e}")
            errors_list.append(pkg_name)

    print()
    print(f"결과: {available}개 정상 / {gone}개 삭제됨 / {len(errors_list) - gone}개 오류")

    if gone > 0:
        print()
        print("⚠ 삭제된 bottle이 있습니다. lockfile을 갱신하세요:")
        print("  python3 scripts/update_lock.py")
        sys.exit(1)
    elif errors_list:
        print("\n일부 패키지 확인에 실패했습니다.")
        sys.exit(1)
    else:
        print("✓ 모든 bottle이 GHCR에 존재합니다.")


def main() -> None:
    parser = argparse.ArgumentParser(description="QEMU Lockfile Updater")
    parser.add_argument("--tag", default="arm64_tahoe", help="bottle tag (기본: arm64_tahoe)")
    parser.add_argument("--output", type=Path, default=DEFAULT_LOCKFILE, help="출력 lockfile 경로")
    parser.add_argument("--dry-run", action="store_true", help="변경 사항만 출력하고 파일은 수정하지 않음")
    parser.add_argument("--check", action="store_true", help="GHCR에 bottle이 아직 존재하는지 확인")
    parser.add_argument("--root", help="이 formula + 전이 의존성(brew deps)으로 패키지 목록 산출 (예: freerdp)")
    args = parser.parse_args()

    # --root: brew deps로 패키지 목록을 동적으로 산출 (기본 qemu 목록 대신)
    global REQUIRED_PACKAGES
    if args.root:
        r = subprocess.run(["brew", "deps", args.root], capture_output=True, text=True)
        if r.returncode != 0:
            sys.exit(f"오류: brew deps {args.root} 실패 — {r.stderr.strip()}")
        deps = [d for d in r.stdout.split() if d]
        REQUIRED_PACKAGES = [args.root] + deps
        print(f"'{args.root}' + 전이 의존성 {len(deps)}개 → {len(REQUIRED_PACKAGES)}개 패키지")

    # --check 모드: GHCR 가용성만 확인하고 종료
    if args.check:
        check_ghcr_availability(args.output)
        return

    print(f"Homebrew API에서 bottle 정보 조회 중... (tag: {args.tag})")
    print()

    # 기존 lockfile 로드 (비교용)
    old_packages: dict = {}
    if args.output.exists():
        try:
            with open(args.output) as f:
                old_data = json.load(f)
            old_packages = old_data.get("packages", {})
        except (json.JSONDecodeError, KeyError):
            pass

    packages: dict = {}
    errors: list[str] = []

    for pkg in REQUIRED_PACKAGES:
        formula = fetch_formula(pkg)
        if not formula:
            errors.append(pkg)
            continue

        info = extract_bottle_info(formula, args.tag)
        if not info:
            print(f"  경고: {pkg}에 {args.tag} bottle이 없습니다.")
            errors.append(pkg)
            continue

        # 변경 사항 표시
        old = old_packages.get(pkg)
        if old and old.get("version") != info["version"]:
            print(f"  갱신: {pkg} {old['version']} → {info['version']}")
        elif not old:
            print(f"  추가: {pkg} {info['version']}")
        else:
            print(f"  유지: {pkg} {info['version']}")

        packages[pkg] = info

    if errors:
        print(f"\n경고: {len(errors)}개 패키지 조회 실패: {', '.join(errors)}")

    lockdata = {
        "lockfile_version": 1,
        "created": str(date.today()),
        "bottle_tag": args.tag,
        "packages": packages,
    }

    if args.dry_run:
        print("\n--- dry-run: 아래 내용이 기록될 예정 ---")
        print(json.dumps(lockdata, indent=2, ensure_ascii=False))
        return

    with open(args.output, "w") as f:
        json.dump(lockdata, f, indent=2, ensure_ascii=False)
        f.write("\n")

    print(f"\n✓ {args.output} 에 {len(packages)}개 패키지 기록 완료")


if __name__ == "__main__":
    main()
