#!/usr/bin/env python3
"""
MacSandbox QEMU Lockfile Updater
=================================
Queries the Homebrew API for the latest bottle information and
updates qemu-bottles.lock.json.

Usage:
    python3 scripts/update_lock.py [--tag arm64_tahoe] [--output PATH]
    python3 scripts/update_lock.py --check   # check whether the bottles still exist on GHCR

Dependencies: Python 3.9+ standard library only
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

# List of packages required for the bundle (qemu + transitive dependencies)
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
    # glib dependencies
    "pcre2",
    "gettext",
    # gnutls dependencies
    "nettle",
    "libtasn1",
    "libunistring",
    "p11-kit",
    "ca-certificates",
    "gmp",
    # libssh dependencies
    "openssl@3",
    # additional gnutls dependencies
    "libidn2",
    "unbound",
    # unbound dependencies
    "libevent",
    "libnghttp2",
]


def fetch_formula(package: str) -> dict:
    """Fetch formula information from the Homebrew API."""
    # @ → %40 (no URL encoding; the Homebrew API uses @ as-is)
    url = f"{HOMEBREW_API}/{package}.json"
    req = urllib.request.Request(url, headers={
        "User-Agent": "MacSandbox-LockUpdater/1.0",
    })
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read())
    except Exception as e:
        print(f"  Error: could not fetch information for {package} — {e}", file=sys.stderr)
        return {}


def extract_bottle_info(formula: dict, tag: str) -> dict | None:
    """Extract bottle information from the formula JSON."""
    try:
        bottle = formula["bottle"]["stable"]
    except (KeyError, TypeError):
        return None

    # specified tag → all → None
    files = bottle.get("files", {})
    bottle_file = files.get(tag) or files.get("all")
    if not bottle_file:
        return None

    sha256 = bottle_file["sha256"]
    cellar = bottle_file.get("cellar", ":any")

    # compute filename
    version = formula["versions"]["stable"]
    revision = formula.get("revision", 0)
    ver_str = f"{version}_{revision}" if revision else version

    name = formula["name"]
    actual_tag = tag if tag in files else "all"

    # Homebrew standard filename pattern
    # {sha256prefix}--{name}--{version}.{tag}.bottle[.rebuild].tar.gz
    # The exact filename is not in the API, so downloads pull from GHCR using sha256 alone,
    # but we record filename for cache identification
    filename = f"{name}--{ver_str}.{actual_tag}.bottle.tar.gz"

    return {
        "version": ver_str,
        "sha256": sha256,
        "filename": filename,
    }


# ---------------------------------------------------------------------------
# GHCR availability check
# ---------------------------------------------------------------------------

GHCR_BASE = "https://ghcr.io/v2/homebrew/core"


def _ghcr_token(package: str) -> str:
    """Obtain an anonymous GHCR bearer token."""
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
    """Use HEAD requests to check whether all bottles in the lockfile still exist on GHCR."""
    if not lockfile_path.exists():
        sys.exit(f"Error: lockfile is missing — {lockfile_path}")

    with open(lockfile_path) as f:
        lockdata = json.load(f)

    packages = lockdata.get("packages", {})
    print(f"Checking GHCR bottle availability... ({len(packages)} packages)")
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
                print(f"  ✗ {pkg_name} ({pkg_info['version']}) — removed!")
                gone += 1
                errors_list.append(pkg_name)
            else:
                print(f"  ? {pkg_name} ({pkg_info['version']}) — HTTP {e.code}")
                errors_list.append(pkg_name)
        except Exception as e:
            print(f"  ? {pkg_name} ({pkg_info['version']}) — {e}")
            errors_list.append(pkg_name)

    print()
    print(f"Result: {available} OK / {gone} removed / {len(errors_list) - gone} errors")

    if gone > 0:
        print()
        print("⚠ Some bottles have been removed. Update the lockfile:")
        print("  python3 scripts/update_lock.py")
        sys.exit(1)
    elif errors_list:
        print("\nFailed to check some packages.")
        sys.exit(1)
    else:
        print("✓ All bottles exist on GHCR.")


def main() -> None:
    parser = argparse.ArgumentParser(description="QEMU Lockfile Updater")
    parser.add_argument("--tag", default="arm64_tahoe", help="bottle tag (default: arm64_tahoe)")
    parser.add_argument("--output", type=Path, default=DEFAULT_LOCKFILE, help="output lockfile path")
    parser.add_argument("--dry-run", action="store_true", help="print the changes only without modifying the file")
    parser.add_argument("--check", action="store_true", help="check whether the bottles still exist on GHCR")
    parser.add_argument("--root", help="derive the package list from this formula + its transitive dependencies (brew deps) (e.g. freerdp)")
    args = parser.parse_args()

    # --root: dynamically derive the package list with brew deps (instead of the default qemu list)
    global REQUIRED_PACKAGES
    if args.root:
        r = subprocess.run(["brew", "deps", args.root], capture_output=True, text=True)
        if r.returncode != 0:
            sys.exit(f"Error: brew deps {args.root} failed — {r.stderr.strip()}")
        deps = [d for d in r.stdout.split() if d]
        REQUIRED_PACKAGES = [args.root] + deps
        print(f"'{args.root}' + {len(deps)} transitive dependencies → {len(REQUIRED_PACKAGES)} packages")

    # --check mode: only check GHCR availability and exit
    if args.check:
        check_ghcr_availability(args.output)
        return

    print(f"Querying the Homebrew API for bottle information... (tag: {args.tag})")
    print()

    # Load the existing lockfile (for comparison)
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
            print(f"  Warning: {pkg} has no {args.tag} bottle.")
            errors.append(pkg)
            continue

        # Show changes
        old = old_packages.get(pkg)
        if old and old.get("version") != info["version"]:
            print(f"  Updated: {pkg} {old['version']} → {info['version']}")
        elif not old:
            print(f"  Added: {pkg} {info['version']}")
        else:
            print(f"  Unchanged: {pkg} {info['version']}")

        packages[pkg] = info

    if errors:
        print(f"\nWarning: failed to query {len(errors)} package(s): {', '.join(errors)}")

    lockdata = {
        "lockfile_version": 1,
        "created": str(date.today()),
        "bottle_tag": args.tag,
        "packages": packages,
    }

    if args.dry_run:
        print("\n--- dry-run: the following content would be written ---")
        print(json.dumps(lockdata, indent=2, ensure_ascii=False))
        return

    with open(args.output, "w") as f:
        json.dump(lockdata, f, indent=2, ensure_ascii=False)
        f.write("\n")

    print(f"\n✓ Wrote {len(packages)} package(s) to {args.output}")


if __name__ == "__main__":
    main()
