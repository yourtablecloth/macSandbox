#!/usr/bin/env python3
"""MacSandbox 자체 소스 파일에 듀얼 라이선스(SPDX) 헤더를 멱등하게 적용한다.

- 대상: src/**/*.{swift,c,m,h}  (우리 저작물만; vendor/, .build/ 제외)
- 이미 라이선스 헤더가 있으면 건너뜀.
사용: python3 scripts/apply_license_headers.py        # 적용
      python3 scripts/apply_license_headers.py --check # 미적용 파일만 출력(쓰지 않음)
"""
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOLDER = "Nam Jung Hyun (rkttu)"
YEAR = "2026"
TARGET_DIRS = ["src"]
EXTS = (".swift", ".c", ".m", ".h")

HEADER_LINES = [
    "SPDX-License-Identifier: AGPL-3.0-or-later",
    "",
    f"Copyright (C) {YEAR} {HOLDER}",
    "",
    "This file is part of MacSandbox, which is dual-licensed:",
    "  (1) under the GNU Affero General Public License v3.0 or later (see LICENSE), or",
    "  (2) under a commercial license (see COMMERCIAL-LICENSE.md).",
    "You may use this file under the terms of either license.",
    "",
    "MacSandbox is distributed in the hope that it will be useful, but WITHOUT",
    "ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or",
    "FITNESS FOR A PARTICULAR PURPOSE.",
]


def header_block() -> str:
    # 모든 대상 확장자가 // 주석을 지원(swift/c/objc).
    return "\n".join("// " + l if l else "//" for l in HEADER_LINES) + "\n\n"


def has_header(text: str) -> bool:
    head = text[:1200]
    return ("SPDX-License-Identifier" in head) or ("GNU General Public License" in head)


def iter_files():
    for d in TARGET_DIRS:
        for root, _, files in os.walk(os.path.join(REPO, d)):
            if "/.build" in root or "/vendor" in root:
                continue
            for f in files:
                if f.endswith(EXTS):
                    yield os.path.join(root, f)


def main():
    check = "--check" in sys.argv
    applied, skipped, missing = 0, 0, []
    for path in iter_files():
        with open(path, "r", encoding="utf-8") as fh:
            text = fh.read()
        if has_header(text):
            skipped += 1
            continue
        missing.append(os.path.relpath(path, REPO))
        if check:
            continue
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(header_block() + text)
        applied += 1

    rel = lambda n: n
    if check:
        print(f"[check] 헤더 없는 파일 {len(missing)}개:")
        for m in missing:
            print("  " + m)
    else:
        print(f"[apply] 적용 {applied}개, 이미 있음 {skipped}개")
    return 0


if __name__ == "__main__":
    sys.exit(main())
