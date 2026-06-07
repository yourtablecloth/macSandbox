#!/usr/bin/env python3
"""
MacSandbox QEMU Bundler
=======================
Homebrew GHCR에서 QEMU + 의존성 bottle을 다운받아
self-contained vendor/qemu 번들로 패키징합니다.

사용법:
    python3 scripts/bundle_qemu.py [--force] [--lockfile PATH]
    python3 scripts/bundle_qemu.py --force --fallback-brew   # GHCR 실패 시 brew fetch 폴백

의존성: Python 3.9+ 표준 라이브러리만 사용 (외부 패키지 불필요)
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
# 상수
# ---------------------------------------------------------------------------

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_DIR = SCRIPT_DIR.parent
VENDOR_DIR = PROJECT_DIR / "vendor" / "qemu"
DEFAULT_LOCKFILE = SCRIPT_DIR / "qemu-bottles.lock.json"
CACHE_DIR = PROJECT_DIR / ".bottle-cache"

# GHCR (GitHub Container Registry) URL 패턴
GHCR_BASE = "https://ghcr.io/v2/homebrew/core"

# 번들에 포함할 QEMU 바이너리
QEMU_BINARIES = ["qemu-system-aarch64", "qemu-system-x86_64", "qemu-img"]

# Homebrew placeholder 패턴
HOMEBREW_PATTERNS = (
    "@@HOMEBREW_PREFIX@@",
    "@@HOMEBREW_CELLAR@@",
    "/opt/homebrew",
    "/usr/local",
)


# ---------------------------------------------------------------------------
# 유틸리티
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
# Lockfile 읽기
# ---------------------------------------------------------------------------

def load_lockfile(path: Path) -> dict:
    with open(path) as f:
        data = json.load(f)
    if data.get("lockfile_version") != 1:
        sys.exit(f"오류: 지원하지 않는 lockfile 버전 — {data.get('lockfile_version')}")
    return data


# ---------------------------------------------------------------------------
# 다운로드 & 검증
# ---------------------------------------------------------------------------

def ghcr_url(package: str, sha256: str) -> str:
    """Homebrew GHCR blob URL을 생성합니다."""
    pkg_path = package.replace("@", "/")
    return f"{GHCR_BASE}/{pkg_path}/blobs/sha256:{sha256}"


# GHCR 토큰 캐시 (패키지별)
_ghcr_tokens: dict[str, str] = {}


def ghcr_token(package: str) -> str:
    """GHCR 익명 bearer 토큰을 획득합니다."""
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
    """GHCR에서 bottle을 다운로드합니다. 성공 시 True, 404면 False."""
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
    """brew fetch로 bottle을 다운로드합니다 (Homebrew 설치 필요). 성공 시 True."""
    # brew가 있는지 확인
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

    # brew 캐시에서 파일 경로 획득
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
    """bottle을 다운받고 SHA256을 검증합니다. 캐시된 파일이 있으면 재사용."""
    filename = info["filename"]
    expected_sha = info["sha256"]
    cached = cache_dir / filename

    # 캐시 확인
    if cached.exists():
        actual_sha = sha256_file(cached)
        if actual_sha == expected_sha:
            log(f"캐시 사용: {package} ({info['version']})", indent=1)
            return cached
        else:
            log(f"캐시 SHA256 불일치, 재다운로드: {package}", indent=1)
            cached.unlink()

    log(f"다운로드: {package} ({info['version']})", indent=1)

    # 1차: GHCR 직접 다운로드
    try:
        ok = _download_ghcr(package, info, cached)
    except Exception as e:
        ok = False
        log(f"GHCR 오류: {e}", indent=2)

    # 2차: GHCR 실패 시 brew fetch 폴백
    if not ok:
        if fallback_brew:
            log(f"GHCR에서 {package} bottle이 삭제됨 → brew fetch 폴백", indent=2)
            ok = _download_brew_fetch(package, info, cached, bottle_tag)
            if not ok:
                if cached.exists():
                    cached.unlink()
                sys.exit(
                    f"오류: {package} bottle을 어디서도 가져올 수 없습니다.\n"
                    f"  lockfile이 오래되었을 수 있습니다.\n"
                    f"  실행: python3 scripts/update_lock.py"
                )
        else:
            if cached.exists():
                cached.unlink()
            sys.exit(
                f"오류: {package} ({info['version']}) bottle이 GHCR에서 삭제되었습니다.\n"
                f"  Homebrew가 구 버전을 정리한 것 같습니다.\n"
                f"  해결 방법:\n"
                f"    1) python3 scripts/update_lock.py   ← lockfile을 최신 버전으로 갱신\n"
                f"    2) python3 scripts/bundle_qemu.py --force --fallback-brew   ← brew fetch 폴백 사용"
            )

    # 해시 검증 (brew fetch 폴백은 최신 버전일 수 있으므로 경고만)
    actual_sha = sha256_file(cached)
    if actual_sha != expected_sha:
        if fallback_brew:
            log(
                f"경고: {package} SHA256이 lockfile과 다릅니다 (brew fetch가 최신 버전을 가져왔을 수 있음)",
                indent=2,
            )
            log(f"  lockfile: {expected_sha[:16]}...", indent=2)
            log(f"  실제:     {actual_sha[:16]}...", indent=2)
            log("  lockfile 갱신을 권장합니다: python3 scripts/update_lock.py", indent=2)
        else:
            cached.unlink()
            sys.exit(
                f"오류: {package} SHA256 불일치!\n"
                f"  예상: {expected_sha}\n"
                f"  실제: {actual_sha}"
            )

    return cached


# ---------------------------------------------------------------------------
# 추출
# ---------------------------------------------------------------------------

def extract_bottle(tarball: Path, dest: Path, package: str) -> Path:
    """bottle tarball을 추출합니다. Cellar 구조를 반환."""
    pkg_dir = dest / package.replace("@", "_").replace("/", "_")
    pkg_dir.mkdir(parents=True, exist_ok=True)

    with tarfile.open(tarball, "r:gz") as tf:
        # 안전 검사: path traversal 방지
        for member in tf.getmembers():
            member_path = os.path.normpath(member.name)
            if member_path.startswith("..") or os.path.isabs(member_path):
                sys.exit(f"오류: 위험한 경로 발견 — {member.name}")

        tf.extractall(pkg_dir, filter="data")

    return pkg_dir


# ---------------------------------------------------------------------------
# 파일 수집
# ---------------------------------------------------------------------------

def collect_files(cellar_dir: Path, vendor_dir: Path) -> None:
    """추출된 cellar에서 필요한 파일을 vendor/qemu로 복사합니다."""
    bin_dir = vendor_dir / "bin"
    lib_dir = vendor_dir / "lib"
    share_dir = vendor_dir / "share"

    bin_dir.mkdir(parents=True, exist_ok=True)
    lib_dir.mkdir(parents=True, exist_ok=True)
    share_dir.mkdir(parents=True, exist_ok=True)

    # 1) QEMU 바이너리
    for binname in QEMU_BINARIES:
        found = list(cellar_dir.rglob(binname))
        found = [f for f in found if f.is_file()]
        if found:
            dest = bin_dir / binname
            shutil.copy2(found[0], dest)
            dest.chmod(0o755)
            log(f"bin: {binname}", indent=1)

    # 2) QEMU share 디렉토리 (펌웨어, keymaps)
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

    # 3) dylib 수집 — 실제 파일 (*.dylib, *.dylib.*)
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
            # symlink이면 타겟의 실제 파일을 복사
            src = lib.resolve() if lib.is_symlink() else lib
            if src.is_file():
                shutil.copy2(src, dest)
                collected.add(libname)

    log(f"lib: {len(collected)} dylibs 수집됨", indent=1)


# ---------------------------------------------------------------------------
# dylib 경로 재작성
# ---------------------------------------------------------------------------

def otool_deps(filepath: Path) -> list[str]:
    """otool -L 로 의존성 경로를 파싱합니다."""
    result = run(["otool", "-L", str(filepath)], check=False)
    if result.returncode != 0:
        return []
    deps = []
    for line in result.stdout.splitlines()[1:]:
        line = line.strip()
        if line:
            # "path (compatibility ...)" 형태
            dep = line.split()[0]
            deps.append(dep)
    return deps


def otool_id(filepath: Path) -> str | None:
    """otool -D 로 install name ID를 가져옵니다."""
    result = run(["otool", "-D", str(filepath)], check=False)
    if result.returncode != 0:
        return None
    lines = result.stdout.strip().splitlines()
    return lines[-1] if len(lines) >= 2 else None


def needs_rewrite(dep: str, staging_dir: Path | None = None) -> bool:
    """이 의존성 경로가 재작성 대상인지 확인합니다."""
    for pat in HOMEBREW_PATTERNS:
        if dep.startswith(pat):
            return True
    if staging_dir and dep.startswith(str(staging_dir)):
        return True
    return False


def is_relocatable_id(ident: str) -> bool:
    """이 install name ID가 이미 relocatable(@loader_path 등)인지 확인."""
    return ident.startswith(("@loader_path", "@executable_path", "@rpath"))


def rewrite_dylib_paths(vendor_dir: Path) -> None:
    """vendor/qemu의 모든 바이너리와 라이브러리의 dylib 경로를 재작성합니다."""
    bin_dir = vendor_dir / "bin"
    lib_dir = vendor_dir / "lib"

    lib_names = {f.name for f in lib_dir.iterdir() if f.is_file()} if lib_dir.exists() else set()

    def make_writable(p: Path) -> None:
        p.chmod(p.stat().st_mode | 0o200)

    def rewrite_file(filepath: Path, *, is_binary: bool) -> None:
        rpath = "@executable_path/../lib" if is_binary else "@loader_path"
        make_writable(filepath)

        # 의존성 경로 재작성
        for dep in otool_deps(filepath):
            depname = os.path.basename(dep)
            if needs_rewrite(dep) and depname in lib_names:
                run([
                    "install_name_tool", "-change", dep,
                    f"{rpath}/{depname}", str(filepath),
                ], check=False)

        # install name ID 재작성 (라이브러리만)
        if not is_binary:
            current_id = otool_id(filepath)
            if current_id and not is_relocatable_id(current_id):
                run([
                    "install_name_tool", "-id",
                    f"@loader_path/{filepath.name}", str(filepath),
                ], check=False)

    # 바이너리 처리
    if bin_dir.exists():
        for binfile in bin_dir.iterdir():
            if not binfile.is_file():
                continue
            log(f"rewrite: bin/{binfile.name}", indent=1)
            rewrite_file(binfile, is_binary=True)
            # rpath 추가
            run([
                "install_name_tool", "-add_rpath",
                "@executable_path/../lib", str(binfile),
            ], check=False)

    # 라이브러리 처리
    if lib_dir.exists():
        count = 0
        for libfile in sorted(lib_dir.iterdir()):
            if not libfile.is_file() or ".dylib" not in libfile.name:
                continue
            rewrite_file(libfile, is_binary=False)
            count += 1
        log(f"rewrite: {count} dylibs 처리됨", indent=1)


# ---------------------------------------------------------------------------
# 코드 서명
# ---------------------------------------------------------------------------

def codesign_all(vendor_dir: Path) -> None:
    """ad-hoc 코드 서명을 적용합니다."""
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

    log(f"코드 서명: {count}개 파일", indent=1)

    # qemu-system-aarch64는 HVF 사용을 위해 hypervisor entitlement로 재서명(없으면 부팅 시 HVF 실패).
    ent = SCRIPT_DIR / "hypervisor.entitlements"
    qemu_hvf = bin_dir / "qemu-system-aarch64"
    if ent.exists() and qemu_hvf.exists():
        run(["codesign", "--force", "--sign", "-", "--entitlements", str(ent), str(qemu_hvf)])
        log("hypervisor entitlement: qemu-system-aarch64", indent=1)


# ---------------------------------------------------------------------------
# 검증
# ---------------------------------------------------------------------------

def validate(vendor_dir: Path) -> int:
    """미해결 Homebrew 경로가 있는지 검증합니다."""
    errors = 0
    bin_dir = vendor_dir / "bin"
    lib_dir = vendor_dir / "lib"

    # 바이너리 확인
    for binname in QEMU_BINARIES:
        binpath = bin_dir / binname
        if not binpath.exists():
            log(f"오류: {binname} 바이너리가 없습니다!", indent=1)
            errors += 1
            continue

        unresolved = [d for d in otool_deps(binpath) if needs_rewrite(d)]
        if unresolved:
            log(f"경고: {binname}에 미해결 경로 {len(unresolved)}개", indent=1)
            for u in unresolved:
                log(f"  {u}", indent=2)
            errors += len(unresolved)
        else:
            log(f"✓ {binname} — 모든 경로 정상", indent=1)

    # 라이브러리 확인
    lib_errors = 0
    if lib_dir.exists():
        for libfile in sorted(lib_dir.iterdir()):
            if not libfile.is_file() or ".dylib" not in libfile.name:
                continue
            unresolved = [d for d in otool_deps(libfile) if needs_rewrite(d)]
            if unresolved:
                log(f"경고: {libfile.name}에 미해결 경로 {len(unresolved)}개", indent=2)
                for u in unresolved:
                    log(f"  {u}", indent=3)
                lib_errors += len(unresolved)
    errors += lib_errors
    if lib_errors == 0:
        log("✓ 라이브러리 경로 검증 완료", indent=1)

    return errors


# ---------------------------------------------------------------------------
# 정보 출력
# ---------------------------------------------------------------------------

def print_summary(vendor_dir: Path, lockdata: dict) -> None:
    """번들 요약을 출력합니다."""
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
    log(" 완료!")
    log(f" 위치: {vendor_dir}")
    log(f" 크기: {size}")
    log(f" QEMU: {qemu_ver}")
    log("========================================")
    log("")
    log("번들 구조:")
    log("  vendor/qemu/")
    log(f"  ├── bin/ ({bin_count}개)")
    if bin_dir.exists():
        for f in sorted(bin_dir.iterdir()):
            log(f"  │   └── {f.name}")
    log(f"  ├── lib/ ({lib_count} dylibs)")
    log("  └── share/")


# ---------------------------------------------------------------------------
# 메인
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(description="MacSandbox QEMU Bundler")
    parser.add_argument("--force", action="store_true", help="기존 번들 삭제 후 재생성")
    parser.add_argument("--lockfile", type=Path, default=DEFAULT_LOCKFILE, help="lockfile 경로")
    parser.add_argument(
        "--fallback-brew", action="store_true",
        help="GHCR에서 bottle을 찾을 수 없을 때 brew fetch를 폴백으로 사용",
    )
    args = parser.parse_args()

    # 아키텍처 확인
    if platform.machine() != "arm64":
        sys.exit(f"오류: Apple Silicon (arm64) 전용입니다. 현재: {platform.machine()}")

    # lockfile 로드
    if not args.lockfile.exists():
        sys.exit(f"오류: lockfile이 없습니다 — {args.lockfile}")
    lockdata = load_lockfile(args.lockfile)
    packages = lockdata["packages"]
    qemu_ver = packages.get("qemu", {}).get("version", "?")

    log("========================================")
    log(" MacSandbox QEMU Bundler")
    log(f" QEMU {qemu_ver} ({lockdata.get('bottle_tag', '?')})")
    log(f" {len(packages)}개 패키지")
    log("========================================")
    log("")

    # 기존 번들 확인
    if VENDOR_DIR.exists() and not args.force:
        # 검증만 수행
        qemu_bin = VENDOR_DIR / "bin" / "qemu-system-x86_64"
        if qemu_bin.exists():
            log("기존 번들이 존재합니다. --force 로 재빌드하세요.")
            return
    elif VENDOR_DIR.exists() and args.force:
        log("기존 번들 삭제 중...")
        shutil.rmtree(VENDOR_DIR)

    # 캐시 디렉토리 생성
    CACHE_DIR.mkdir(parents=True, exist_ok=True)

    # 스테이징 디렉토리
    staging = Path(tempfile.mkdtemp(prefix="qemu-bundle-"))
    try:
        # --- Step 1: 다운로드 & 추출 ---
        log("[1/4] Bottle 다운로드 및 추출...")
        cellar_dir = staging / "cellar"
        cellar_dir.mkdir()

        for pkg_name, pkg_info in packages.items():
            tarball = download_bottle(
                pkg_name, pkg_info, CACHE_DIR,
                fallback_brew=args.fallback_brew,
                bottle_tag=lockdata.get("bottle_tag", "arm64_tahoe"),
            )
            extract_bottle(tarball, cellar_dir, pkg_name)

        # --- Step 2: 파일 수집 ---
        log("")
        log("[2/4] 바이너리 및 라이브러리 복사...")
        VENDOR_DIR.mkdir(parents=True, exist_ok=True)
        collect_files(cellar_dir, VENDOR_DIR)

        # --- Step 3: dylib 경로 재작성 ---
        log("")
        log("[3/4] dylib 경로 재작성...")
        rewrite_dylib_paths(VENDOR_DIR)
        codesign_all(VENDOR_DIR)

        # --- Step 4: 검증 ---
        log("")
        log("[4/4] 검증...")
        errors = validate(VENDOR_DIR)

        # --- 요약 ---
        print_summary(VENDOR_DIR, lockdata)

        if errors > 0:
            log(f"\n경고: {errors}개 미해결 경로 발견!")
            sys.exit(1)

    finally:
        shutil.rmtree(staging, ignore_errors=True)


if __name__ == "__main__":
    main()
