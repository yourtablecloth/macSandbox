#!/usr/bin/env python3
"""Collect the corresponding source code of GPL/LGPL components into gpl-sources/, matched to the bundled versions.

For fulfilling the "provide corresponding source" obligation of GPLv2 §3 / GPLv3 §6 / LGPL. Since the bundle is
pulled from Homebrew bottles (scripts/qemu-bottles.lock.json), getting the same sources from Homebrew is the closest match.

Usage: python3 scripts/fetch_gpl_sources.py          # collect the sources of GPL/LGPL components
       python3 scripts/fetch_gpl_sources.py --all     # collect the entire bundle (including permissive-licensed)

Note: Homebrew (brew) is required. If the current formula version differs from the lock version, a warning is emitted
(if an exact match is required, fetch from the formula for that specific version).
"""
import json
import os
import shutil
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOCK = os.path.join(REPO, "scripts", "qemu-bottles.lock.json")
OUT = os.path.join(REPO, "gpl-sources")

# Bundle components subject to the source-provision obligation (= GPL/LGPL family) + separate tools.
GPL_LGPL = {
    "qemu", "dtc", "glib", "gnutls", "libssh", "libusb", "lzo", "vde",
    "zstd", "gettext", "nettle", "libtasn1", "libunistring", "gmp", "libidn2",
    "wimlib",  # build tool (separate process)
}


def brew_available() -> bool:
    return shutil.which("brew") is not None


def brew_cache_for(formula: str) -> str | None:
    # ⚠️ Without --build-from-source you get the bottle (binary) path. The GPL obligation is for 'source', so it's required.
    try:
        out = subprocess.run(["brew", "--cache", "--build-from-source", "--formula", formula],
                             capture_output=True, text=True, check=True)
        return out.stdout.strip() or None
    except subprocess.CalledProcessError:
        return None


def upstream_basename(cache_path: str) -> str:
    # The cache filename has the form "<sha>--name-version.tar.gz" → use the original name after '--'.
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
        print("❌ Homebrew (brew) is required. Can be substituted with the written offer in WRITTEN-OFFER.txt.")
        return 1
    if not os.path.exists(LOCK):
        print(f"❌ lock file not found: {LOCK}")
        return 1

    lock = json.load(open(LOCK))
    pkgs = lock.get("packages", {})
    fetch_all = "--all" in sys.argv
    targets = list(pkgs) if fetch_all else [p for p in pkgs if p in GPL_LGPL]
    # wimlib may not be in the bottle lock, so add it in GPL/LGPL mode
    if not fetch_all and "wimlib" not in targets:
        targets.append("wimlib")

    os.makedirs(OUT, exist_ok=True)
    ok, warn, fail = 0, 0, 0
    for name in targets:
        want = pkgs.get(name, {}).get("version") if isinstance(pkgs.get(name), dict) else None
        # brew fetch: download the source tarball into the cache
        r = subprocess.run(["brew", "fetch", "--formula", "--build-from-source", name],
                           capture_output=True, text=True)
        cache = brew_cache_for(name)
        have = installed_version(name)
        if r.returncode != 0 or not cache or not os.path.exists(cache):
            print(f"  ⚠️  {name}: source collection failed (brew fetch). Manual collection required.")
            fail += 1
            continue
        dst = os.path.join(OUT, upstream_basename(cache))  # preserve the original source tarball name
        shutil.copy2(cache, dst)
        if want and have and want.split("_")[0] != have.split("_")[0]:
            print(f"  ⚠️  {name}: bundled {want} ≠ collected {have} (if an exact match is required, use the formula for that version)")
            warn += 1
        else:
            print(f"  ✓ {name} {have} → {os.path.relpath(dst, REPO)}")
            ok += 1

    print(f"\nCollection complete: matched {ok}, version warnings {warn}, failed {fail} → {os.path.relpath(OUT, REPO)}/")
    print("Bundle gpl-sources/ with your distribution, or provide it via WRITTEN-OFFER.txt (written offer).")
    return 0 if fail == 0 else 2


if __name__ == "__main__":
    sys.exit(main())
