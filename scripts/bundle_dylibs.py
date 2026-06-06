#!/usr/bin/env python3
"""Mach-O 실행파일/dylib의 비시스템 의존 dylib를 재귀적으로 dest로 복사하고
install name을 @rpath/<name>으로 재작성한다(.app 자체완결화).

사용: bundle_dylibs.py <macho> <dest_frameworks_dir> [--add-rpath @executable_path/../Frameworks]
- 시스템 라이브러리(/usr/lib, /System)는 건너뜀.
- 이미 dest에 있는 동일 이름은 재복사하지 않고 참조만 수정.
- install_name_tool로 서명이 깨지므로 호출 후 반드시 재서명할 것.
"""
import os
import shutil
import subprocess
import sys

SYS = ("/usr/lib/", "/System/")


def deps(path):
    out = subprocess.run(["otool", "-L", path], capture_output=True, text=True).stdout
    res = []
    for line in out.splitlines()[1:]:
        s = line.strip()
        if not s:
            continue
        res.append(s.split(" (")[0].strip())
    return res


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    main_bin = sys.argv[1]
    dest = sys.argv[2]
    add_rpath = None
    if "--add-rpath" in sys.argv:
        add_rpath = sys.argv[sys.argv.index("--add-rpath") + 1]
    os.makedirs(dest, exist_ok=True)

    seen = set()

    def process(macho, is_main):
        self_id = os.path.basename(macho)
        for dep in deps(macho):
            if dep.startswith(SYS) or dep.startswith("@"):
                continue
            base = os.path.basename(dep)
            if base == self_id and not is_main:
                continue  # 자기 자신 id 참조
            real = os.path.realpath(dep) if dep.startswith("/") else None
            if not real or not os.path.exists(real):
                print(f"  ⚠️  해석 불가 의존: {dep} (수동 확인)")
                continue
            dst = os.path.join(dest, base)
            new = not os.path.exists(dst)
            if new:
                shutil.copy2(real, dst)
                os.chmod(dst, 0o755)
            subprocess.run(["install_name_tool", "-change", dep, f"@rpath/{base}", macho],
                           check=True, capture_output=True)
            if new and base not in seen:
                seen.add(base)
                subprocess.run(["install_name_tool", "-id", f"@rpath/{base}", dst], capture_output=True)
                process(dst, False)

    process(main_bin, True)
    if add_rpath:
        subprocess.run(["install_name_tool", "-add_rpath", add_rpath, main_bin], capture_output=True)
    print(f"번들 완료 → {dest} ({len(os.listdir(dest))}개)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
