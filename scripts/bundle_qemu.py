#!/usr/bin/env python3
"""
MacSandbox QEMU Bundler
=======================
Downloads the QEMU + dependency bottles from Homebrew GHCR and
packages them into a self-contained vendor/qemu bundle.

Usage:
    python3 scripts/bundle_qemu.py [--force] [--lockfile PATH]
    python3 scripts/bundle_qemu.py --force --fallback-brew   # fall back to brew fetch if GHCR fails

Dependencies: Python 3.9+ standard library only (no external packages required)
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.parse
import urllib.request
from pathlib import Path


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_DIR = SCRIPT_DIR.parent
VENDOR_DIR = PROJECT_DIR / "vendor" / "qemu"
DEFAULT_LOCKFILE = SCRIPT_DIR / "qemu-bottles.lock.json"
CACHE_DIR = PROJECT_DIR / ".bottle-cache"

# GHCR (GitHub Container Registry) URL pattern
GHCR_BASE = "https://ghcr.io/v2/homebrew/core"

# QEMU binaries to include in the bundle
QEMU_BINARIES = ["qemu-system-aarch64", "qemu-system-x86_64", "qemu-img"]

# Homebrew placeholder patterns
HOMEBREW_PATTERNS = (
    "@@HOMEBREW_PREFIX@@",
    "@@HOMEBREW_CELLAR@@",
    "/opt/homebrew",
    "/usr/local",
)


# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------

def log(msg: str, *, indent: int = 0) -> None:
    prefix = "  " * indent
    print(f"{prefix}{msg}", flush=True)


def run(cmd: list[str], *, check: bool = True, capture: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, check=check, capture_output=capture, text=True)


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# ---------------------------------------------------------------------------
# Reading the lockfile
# ---------------------------------------------------------------------------

def load_lockfile(path: Path) -> dict:
    with open(path) as f:
        data = json.load(f)
    if data.get("lockfile_version") != 1:
        sys.exit(f"Error: unsupported lockfile version — {data.get('lockfile_version')}")
    return data


# ---------------------------------------------------------------------------
# Download & verification
# ---------------------------------------------------------------------------

def ghcr_url(package: str, sha256: str) -> str:
    """Build a Homebrew GHCR blob URL."""
    pkg_path = package.replace("@", "/")
    return f"{GHCR_BASE}/{pkg_path}/blobs/sha256:{sha256}"


# GHCR token cache (per package)
_ghcr_tokens: dict[str, str] = {}


def ghcr_token(package: str) -> str:
    """Obtain an anonymous GHCR bearer token."""
    pkg_path = package.replace("@", "/")
    if pkg_path in _ghcr_tokens:
        return _ghcr_tokens[pkg_path]

    token_url = (
        f"https://ghcr.io/token?"
        f"scope=repository%3Ahomebrew%2Fcore%2F{urllib.parse.quote(pkg_path, safe='')}%3Apull"
    )
    req = urllib.request.Request(token_url, headers={
        "User-Agent": "MacSandbox-Bundler/1.0",
    })
    with urllib.request.urlopen(req) as resp:
        data = json.loads(resp.read())
    token = data["token"]
    _ghcr_tokens[pkg_path] = token
    return token


def _download_ghcr(package: str, info: dict, cached: Path) -> bool:
    """Download a bottle from GHCR. Returns True on success, False on 404."""
    url = ghcr_url(package, info["sha256"])
    token = ghcr_token(package)

    req = urllib.request.Request(url, headers={
        "Accept": "application/vnd.oci.image.layer.v1.tar+gzip",
        "Authorization": f"Bearer {token}",
        "User-Agent": "MacSandbox-Bundler/1.0",
    })
    try:
        with urllib.request.urlopen(req) as resp, open(cached, "wb") as out:
            shutil.copyfileobj(resp, out)
        return True
    except urllib.error.HTTPError as e:
        if e.code in (404, 410):
            return False
        raise


def _download_brew_fetch(package: str, info: dict, cached: Path, bottle_tag: str) -> bool:
    """Download a bottle via brew fetch (requires Homebrew installed). Returns True on success."""
    # Check whether brew is available
    if not shutil.which("brew"):
        return False

    for tag in (bottle_tag, "arm64_sequoia", "arm64_sonoma"):
        result = run(
            ["brew", "fetch", f"--bottle-tag={tag}", package],
            check=False,
        )
        if result.returncode == 0:
            break
    else:
        return False

    # Get the file path from the brew cache
    result = run(["brew", "--cache", package], check=False)
    brew_cached = result.stdout.strip() if result.returncode == 0 else ""
    if not brew_cached or not Path(brew_cached).is_file():
        return False

    shutil.copy2(brew_cached, cached)
    return True


def download_bottle(
    package: str,
    info: dict,
    cache_dir: Path,
    *,
    fallback_brew: bool = False,
    bottle_tag: str = "arm64_tahoe",
) -> Path:
    """Download a bottle and verify its SHA256. Reuses a cached file if present."""
    filename = info["filename"]
    expected_sha = info["sha256"]
    cached = cache_dir / filename

    # Check the cache
    if cached.exists():
        actual_sha = sha256_file(cached)
        if actual_sha == expected_sha:
            log(f"Using cache: {package} ({info['version']})", indent=1)
            return cached
        else:
            log(f"Cache SHA256 mismatch, re-downloading: {package}", indent=1)
            cached.unlink()

    log(f"Downloading: {package} ({info['version']})", indent=1)

    # First: download directly from GHCR
    try:
        ok = _download_ghcr(package, info, cached)
    except Exception as e:
        ok = False
        log(f"GHCR error: {e}", indent=2)

    # Second: fall back to brew fetch if GHCR fails
    if not ok:
        if fallback_brew:
            log(f"{package} bottle removed from GHCR → falling back to brew fetch", indent=2)
            ok = _download_brew_fetch(package, info, cached, bottle_tag)
            if not ok:
                if cached.exists():
                    cached.unlink()
                sys.exit(
                    f"Error: could not fetch the {package} bottle from anywhere.\n"
                    f"  The lockfile may be out of date.\n"
                    f"  Run: python3 scripts/update_lock.py"
                )
        else:
            if cached.exists():
                cached.unlink()
            sys.exit(
                f"Error: the {package} ({info['version']}) bottle was removed from GHCR.\n"
                f"  Homebrew likely cleaned up the old version.\n"
                f"  How to fix:\n"
                f"    1) python3 scripts/update_lock.py   ← update the lockfile to the latest version\n"
                f"    2) python3 scripts/bundle_qemu.py --force --fallback-brew   ← use the brew fetch fallback"
            )

    # Hash verification (the brew fetch fallback may pull a newer version, so warn only)
    actual_sha = sha256_file(cached)
    if actual_sha != expected_sha:
        if fallback_brew:
            log(
                f"Warning: {package} SHA256 differs from the lockfile (brew fetch may have pulled a newer version)",
                indent=2,
            )
            log(f"  lockfile: {expected_sha[:16]}...", indent=2)
            log(f"  actual:   {actual_sha[:16]}...", indent=2)
            log("  Updating the lockfile is recommended: python3 scripts/update_lock.py", indent=2)
        else:
            cached.unlink()
            sys.exit(
                f"Error: {package} SHA256 mismatch!\n"
                f"  expected: {expected_sha}\n"
                f"  actual:   {actual_sha}"
            )

    return cached


# ---------------------------------------------------------------------------
# Extraction
# ---------------------------------------------------------------------------

def extract_bottle(tarball: Path, dest: Path, package: str) -> Path:
    """Extract a bottle tarball. Returns the Cellar structure."""
    pkg_dir = dest / package.replace("@", "_").replace("/", "_")
    pkg_dir.mkdir(parents=True, exist_ok=True)

    with tarfile.open(tarball, "r:gz") as tf:
        # Safety check: prevent path traversal
        for member in tf.getmembers():
            member_path = os.path.normpath(member.name)
            if member_path.startswith("..") or os.path.isabs(member_path):
                sys.exit(f"Error: dangerous path detected — {member.name}")

        tf.extractall(pkg_dir, filter="data")

    return pkg_dir


# ---------------------------------------------------------------------------
# File collection
# ---------------------------------------------------------------------------

def collect_files(cellar_dir: Path, vendor_dir: Path) -> None:
    """Copy the required files from the extracted cellar into vendor/qemu."""
    bin_dir = vendor_dir / "bin"
    lib_dir = vendor_dir / "lib"
    share_dir = vendor_dir / "share"

    bin_dir.mkdir(parents=True, exist_ok=True)
    lib_dir.mkdir(parents=True, exist_ok=True)
    share_dir.mkdir(parents=True, exist_ok=True)

    # 1) QEMU binaries
    for binname in QEMU_BINARIES:
        found = list(cellar_dir.rglob(binname))
        found = [f for f in found if f.is_file()]
        if found:
            dest = bin_dir / binname
            shutil.copy2(found[0], dest)
            dest.chmod(0o755)
            log(f"bin: {binname}", indent=1)

    # 2) QEMU share directory (firmware, keymaps)
    qemu_shares = [
        d for d in cellar_dir.rglob("qemu")
        if d.is_dir() and "share" in str(d)
    ]
    if qemu_shares:
        share_dest = share_dir / "qemu"
        if share_dest.exists():
            shutil.rmtree(share_dest)
        shutil.copytree(qemu_shares[0], share_dest)
        log("share: qemu (firmware, keymaps)", indent=1)

    # 3) Collect dylibs — actual files (*.dylib, *.dylib.*)
    collected: set[str] = set()
    for pattern in ("*.dylib", "*.dylib.*"):
        for lib in cellar_dir.rglob(pattern):
            libname = lib.name
            if libname in collected:
                continue
            dest = lib_dir / libname
            if dest.exists():
                collected.add(libname)
                continue
            # If it's a symlink, copy the target's actual file
            src = lib.resolve() if lib.is_symlink() else lib
            if src.is_file():
                shutil.copy2(src, dest)
                collected.add(libname)

    log(f"lib: {len(collected)} dylibs collected", indent=1)


# ---------------------------------------------------------------------------
# Rewriting dylib paths
# ---------------------------------------------------------------------------

def otool_deps(filepath: Path) -> list[str]:
    """Parse dependency paths with otool -L."""
    result = run(["otool", "-L", str(filepath)], check=False)
    if result.returncode != 0:
        return []
    deps = []
    for line in result.stdout.splitlines()[1:]:
        line = line.strip()
        if line:
            # "path (compatibility ...)" form
            dep = line.split()[0]
            deps.append(dep)
    return deps


def otool_id(filepath: Path) -> str | None:
    """Get the install name ID with otool -D."""
    result = run(["otool", "-D", str(filepath)], check=False)
    if result.returncode != 0:
        return None
    lines = result.stdout.strip().splitlines()
    return lines[-1] if len(lines) >= 2 else None


def needs_rewrite(dep: str, staging_dir: Path | None = None) -> bool:
    """Check whether this dependency path needs to be rewritten."""
    for pat in HOMEBREW_PATTERNS:
        if dep.startswith(pat):
            return True
    if staging_dir and dep.startswith(str(staging_dir)):
        return True
    return False


def is_relocatable_id(ident: str) -> bool:
    """Check whether this install name ID is already relocatable (@loader_path, etc.)."""
    return ident.startswith(("@loader_path", "@executable_path", "@rpath"))


def rewrite_dylib_paths(vendor_dir: Path) -> None:
    """Rewrite the dylib paths of every binary and library in vendor/qemu."""
    bin_dir = vendor_dir / "bin"
    lib_dir = vendor_dir / "lib"

    lib_names = {f.name for f in lib_dir.iterdir() if f.is_file()} if lib_dir.exists() else set()

    def make_writable(p: Path) -> None:
        p.chmod(p.stat().st_mode | 0o200)

    def rewrite_file(filepath: Path, *, is_binary: bool) -> None:
        rpath = "@executable_path/../lib" if is_binary else "@loader_path"
        make_writable(filepath)

        # Rewrite dependency paths
        for dep in otool_deps(filepath):
            depname = os.path.basename(dep)
            if needs_rewrite(dep) and depname in lib_names:
                run([
                    "install_name_tool", "-change", dep,
                    f"{rpath}/{depname}", str(filepath),
                ], check=False)

        # Rewrite the install name ID (libraries only)
        if not is_binary:
            current_id = otool_id(filepath)
            if current_id and not is_relocatable_id(current_id):
                run([
                    "install_name_tool", "-id",
                    f"@loader_path/{filepath.name}", str(filepath),
                ], check=False)

    # Process binaries
    if bin_dir.exists():
        for binfile in bin_dir.iterdir():
            if not binfile.is_file():
                continue
            log(f"rewrite: bin/{binfile.name}", indent=1)
            rewrite_file(binfile, is_binary=True)
            # Add rpath
            run([
                "install_name_tool", "-add_rpath",
                "@executable_path/../lib", str(binfile),
            ], check=False)

    # Process libraries
    if lib_dir.exists():
        count = 0
        for libfile in sorted(lib_dir.iterdir()):
            if not libfile.is_file() or ".dylib" not in libfile.name:
                continue
            rewrite_file(libfile, is_binary=False)
            count += 1
        log(f"rewrite: {count} dylibs processed", indent=1)


# ---------------------------------------------------------------------------
# Code-signing
# ---------------------------------------------------------------------------

def codesign_all(vendor_dir: Path) -> None:
    """Apply ad-hoc code-signing."""
    bin_dir = vendor_dir / "bin"
    lib_dir = vendor_dir / "lib"
    count = 0

    for d in (bin_dir, lib_dir):
        if not d.exists():
            continue
        for f in d.iterdir():
            if not f.is_file():
                continue
            if d == lib_dir and ".dylib" not in f.name:
                continue
            run(["codesign", "--force", "--sign", "-", str(f)], check=False)
            count += 1

    log(f"code-signing: {count} file(s)", indent=1)

    # Re-sign qemu-system-aarch64 with the hypervisor entitlement to enable HVF (without it, HVF fails at boot).
    ent = SCRIPT_DIR / "hypervisor.entitlements"
    qemu_hvf = bin_dir / "qemu-system-aarch64"
    if ent.exists() and qemu_hvf.exists():
        run(["codesign", "--force", "--sign", "-", "--entitlements", str(ent), str(qemu_hvf)])
        log("hypervisor entitlement: qemu-system-aarch64", indent=1)


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

def validate(vendor_dir: Path) -> int:
    """Verify that no unresolved Homebrew paths remain."""
    errors = 0
    bin_dir = vendor_dir / "bin"
    lib_dir = vendor_dir / "lib"

    # Check binaries
    for binname in QEMU_BINARIES:
        binpath = bin_dir / binname
        if not binpath.exists():
            log(f"Error: the {binname} binary is missing!", indent=1)
            errors += 1
            continue

        unresolved = [d for d in otool_deps(binpath) if needs_rewrite(d)]
        if unresolved:
            log(f"Warning: {binname} has {len(unresolved)} unresolved path(s)", indent=1)
            for u in unresolved:
                log(f"  {u}", indent=2)
            errors += len(unresolved)
        else:
            log(f"✓ {binname} — all paths OK", indent=1)

    # Check libraries
    lib_errors = 0
    if lib_dir.exists():
        for libfile in sorted(lib_dir.iterdir()):
            if not libfile.is_file() or ".dylib" not in libfile.name:
                continue
            unresolved = [d for d in otool_deps(libfile) if needs_rewrite(d)]
            if unresolved:
                log(f"Warning: {libfile.name} has {len(unresolved)} unresolved path(s)", indent=2)
                for u in unresolved:
                    log(f"  {u}", indent=3)
                lib_errors += len(unresolved)
    errors += lib_errors
    if lib_errors == 0:
        log("✓ Library path validation complete", indent=1)

    return errors


# ---------------------------------------------------------------------------
# Info output
# ---------------------------------------------------------------------------

def print_summary(vendor_dir: Path, lockdata: dict) -> None:
    """Print a summary of the bundle."""
    result = run(["du", "-sh", str(vendor_dir)], check=False)
    size = result.stdout.split()[0] if result.returncode == 0 else "?"

    qemu_ver = lockdata["packages"].get("qemu", {}).get("version", "?")

    bin_dir = vendor_dir / "bin"
    lib_dir = vendor_dir / "lib"

    bin_count = sum(1 for f in bin_dir.iterdir() if f.is_file()) if bin_dir.exists() else 0
    lib_count = sum(
        1 for f in lib_dir.iterdir()
        if f.is_file() and ".dylib" in f.name
    ) if lib_dir.exists() else 0

    log("")
    log("========================================")
    log(" Done!")
    log(f" Location: {vendor_dir}")
    log(f" Size: {size}")
    log(f" QEMU: {qemu_ver}")
    log("========================================")
    log("")
    log("Bundle structure:")
    log("  vendor/qemu/")
    log(f"  ├── bin/ ({bin_count})")
    if bin_dir.exists():
        for f in sorted(bin_dir.iterdir()):
            log(f"  │   └── {f.name}")
    log(f"  ├── lib/ ({lib_count} dylibs)")
    log("  └── share/")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(description="MacSandbox QEMU Bundler")
    parser.add_argument("--force", action="store_true", help="delete the existing bundle and regenerate")
    parser.add_argument("--lockfile", type=Path, default=DEFAULT_LOCKFILE, help="lockfile path")
    parser.add_argument(
        "--fallback-brew", action="store_true",
        help="use brew fetch as a fallback when a bottle cannot be found on GHCR",
    )
    args = parser.parse_args()

    # Architecture check
    if platform.machine() != "arm64":
        sys.exit(f"Error: Apple Silicon (arm64) only. Current: {platform.machine()}")

    # Load the lockfile
    if not args.lockfile.exists():
        sys.exit(f"Error: lockfile is missing — {args.lockfile}")
    lockdata = load_lockfile(args.lockfile)
    packages = lockdata["packages"]
    qemu_ver = packages.get("qemu", {}).get("version", "?")

    log("========================================")
    log(" MacSandbox QEMU Bundler")
    log(f" QEMU {qemu_ver} ({lockdata.get('bottle_tag', '?')})")
    log(f" {len(packages)} packages")
    log("========================================")
    log("")

    # Check for an existing bundle
    if VENDOR_DIR.exists() and not args.force:
        # Validation only
        qemu_bin = VENDOR_DIR / "bin" / "qemu-system-x86_64"
        if qemu_bin.exists():
            log("An existing bundle is present. Use --force to rebuild.")
            return
    elif VENDOR_DIR.exists() and args.force:
        log("Deleting the existing bundle...")
        shutil.rmtree(VENDOR_DIR)

    # Create the cache directory
    CACHE_DIR.mkdir(parents=True, exist_ok=True)

    # Staging directory
    staging = Path(tempfile.mkdtemp(prefix="qemu-bundle-"))
    try:
        # --- Step 1: download & extract ---
        log("[1/4] Downloading and extracting bottles...")
        cellar_dir = staging / "cellar"
        cellar_dir.mkdir()

        for pkg_name, pkg_info in packages.items():
            tarball = download_bottle(
                pkg_name, pkg_info, CACHE_DIR,
                fallback_brew=args.fallback_brew,
                bottle_tag=lockdata.get("bottle_tag", "arm64_tahoe"),
            )
            extract_bottle(tarball, cellar_dir, pkg_name)

        # --- Step 2: collect files ---
        log("")
        log("[2/4] Copying binaries and libraries...")
        VENDOR_DIR.mkdir(parents=True, exist_ok=True)
        collect_files(cellar_dir, VENDOR_DIR)

        # --- Step 3: rewrite dylib paths ---
        log("")
        log("[3/4] Rewriting dylib paths...")
        rewrite_dylib_paths(VENDOR_DIR)
        codesign_all(VENDOR_DIR)

        # --- Step 4: validation ---
        log("")
        log("[4/4] Validating...")
        errors = validate(VENDOR_DIR)

        # --- Summary ---
        print_summary(VENDOR_DIR, lockdata)

        if errors > 0:
            log(f"\nWarning: {errors} unresolved path(s) found!")
            sys.exit(1)

    finally:
        shutil.rmtree(staging, ignore_errors=True)


if __name__ == "__main__":
    main()
