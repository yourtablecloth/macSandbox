#!/usr/bin/env python3
"""Recursively copy a Mach-O executable's/dylib's non-system dependency dylibs into dest
and rewrite their install names to @rpath/<name> (making the .app self-contained).

Usage: bundle_dylibs.py <macho> <dest_frameworks_dir> [--add-rpath @executable_path/../Frameworks]
- System libraries (/usr/lib, /System) are skipped.
- A name already present in dest is not re-copied; only its references are fixed.
- install_name_tool breaks code-signing, so always re-sign after calling this.
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
                continue  # self id reference
            real = os.path.realpath(dep) if dep.startswith("/") else None
            if not real or not os.path.exists(real):
                print(f"  ⚠️  unresolvable dependency: {dep} (check manually)")
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
    print(f"Bundling complete → {dest} ({len(os.listdir(dest))} file(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main())
