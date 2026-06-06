#!/usr/bin/env python3
"""GPL/LGPL 구성요소의 대응 소스 코드를 동봉 버전과 맞춰 gpl-sources/로 수집한다.

GPLv2 §3 / GPLv3 §6 / LGPL의 "대응 소스 제공" 의무 이행용. 번들은 Homebrew 보틀에서
가져오므로(scripts/qemu-bottles.lock.json), 동일 소스도 Homebrew로 받는 것이 가장 일치한다.

사용: python3 scripts/fetch_gpl_sources.py          # GPL/LGPL 구성요소 소스 수집
      python3 scripts/fetch_gpl_sources.py --all     # 번들 전체(허용형 포함) 수집

주의: Homebrew(brew) 필요. 현재 formula 버전이 lock 버전과 다르면 경고한다(정확 일치가
필요하면 해당 버전 formula로 받아야 함).
"""
import json
import os
import shutil
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOCK = os.path.join(REPO, "scripts", "qemu-bottles.lock.json")
OUT = os.path.join(REPO, "gpl-sources")

# 소스 제공 의무가 있는(=GPL/LGPL 계열) 번들 구성요소 + 별도 도구.
GPL_LGPL = {
    "qemu", "dtc", "glib", "gnutls", "libssh", "libusb", "lzo", "vde",
    "zstd", "gettext", "nettle", "libtasn1", "libunistring", "gmp", "libidn2",
    "wimlib",  # 빌드 도구(별도 프로세스)
}


def brew_available() -> bool:
    return shutil.which("brew") is not None


def brew_cache_for(formula: str) -> str | None:
    # ⚠️ --build-from-source 없으면 바틀(바이너리) 경로가 나온다. GPL 의무는 '소스'이므로 필수.
    try:
        out = subprocess.run(["brew", "--cache", "--build-from-source", "--formula", formula],
                             capture_output=True, text=True, check=True)
        return out.stdout.strip() or None
    except subprocess.CalledProcessError:
        return None


def upstream_basename(cache_path: str) -> str:
    # 캐시 파일명은 "<sha>--name-version.tar.gz" 형식 → '--' 뒤의 원본 이름 사용.
    base = os.path.basename(cache_path)
    return base.split("--", 1)[1] if "--" in base else base


def installed_version(formula: str) -> str | None:
    try:
        out = subprocess.run(["brew", "list", "--versions", formula],
                             capture_output=True, text=True, check=True)
        parts = out.stdout.split()
        return parts[1] if len(parts) >= 2 else None
    except subprocess.CalledProcessError:
        return None


def main() -> int:
    if not brew_available():
        print("❌ Homebrew(brew)가 필요합니다. WRITTEN-OFFER.txt의 서면 약정으로 대체 가능.")
        return 1
    if not os.path.exists(LOCK):
        print(f"❌ lock 파일 없음: {LOCK}")
        return 1

    lock = json.load(open(LOCK))
    pkgs = lock.get("packages", {})
    fetch_all = "--all" in sys.argv
    targets = list(pkgs) if fetch_all else [p for p in pkgs if p in GPL_LGPL]
    # wimlib은 보틀 lock에 없을 수 있으니 GPL/LGPL 모드에서 보강
    if not fetch_all and "wimlib" not in targets:
        targets.append("wimlib")

    os.makedirs(OUT, exist_ok=True)
    ok, warn, fail = 0, 0, 0
    for name in targets:
        want = pkgs.get(name, {}).get("version") if isinstance(pkgs.get(name), dict) else None
        # brew fetch: 소스 tarball을 캐시에 내려받음
        r = subprocess.run(["brew", "fetch", "--formula", "--build-from-source", name],
                           capture_output=True, text=True)
        cache = brew_cache_for(name)
        have = installed_version(name)
        if r.returncode != 0 or not cache or not os.path.exists(cache):
            print(f"  ⚠️  {name}: 소스 수집 실패 (brew fetch). 수동 수집 필요.")
            fail += 1
            continue
        dst = os.path.join(OUT, upstream_basename(cache))  # 원본 소스 tarball명 보존
        shutil.copy2(cache, dst)
        if want and have and want.split("_")[0] != have.split("_")[0]:
            print(f"  ⚠️  {name}: 번들 {want} ≠ 수집 {have} (정확 일치 필요 시 해당 버전 formula 사용)")
            warn += 1
        else:
            print(f"  ✓ {name} {have} → {os.path.relpath(dst, REPO)}")
            ok += 1

    print(f"\n수집 완료: 일치 {ok}, 버전경고 {warn}, 실패 {fail} → {os.path.relpath(OUT, REPO)}/")
    print("배포본에 gpl-sources/를 동봉하거나 WRITTEN-OFFER.txt(서면 약정)로 제공하세요.")
    return 0 if fail == 0 else 2


if __name__ == "__main__":
    sys.exit(main())
