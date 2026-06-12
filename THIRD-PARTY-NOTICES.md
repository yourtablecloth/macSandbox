# Third-Party Notices — MacSandbox

MacSandbox는 다음 제3자 소프트웨어를 포함(번들)하거나 링크합니다. 각 구성요소는
해당 라이선스의 적용을 받습니다. GPL/LGPL 구성요소의 소스 코드는
[WRITTEN-OFFER.txt](WRITTEN-OFFER.txt)에 따라 제공됩니다.

이 문서는 편의를 위한 요약이며, 각 라이선스 전문은 해당 프로젝트 배포본 또는
`gpl-sources/`(GPL/LGPL 소스 동봉 시)에 포함됩니다.

---

## 1. 앱 바이너리에 링크되는 구성요소

| 구성요소 | 버전 | 라이선스 | 비고 |
|---|---|---|---|
| **FreeRDP / WinPR** | 3.26.0 | **Apache-2.0** | 임베드 RDP 뷰가 직접 링크. NOTICE 보존 필요. |

> Apache-2.0은 AGPL-3.0과 호환되어(단방향), AGPL-3.0 오픈소스 에디션과 상용 에디션 모두에
> 포함될 수 있습니다.

## 2. 펌웨어 (QEMU에 전달)

| 구성요소 | 라이선스 |
|---|---|
| **edk2** (`edk2-aarch64-code.fd`, `edk2-arm-vars.fd`) | **BSD-2-Clause-Patent** (라이선스 전문: `vendor/qemu/share/qemu/edk2-licenses.txt`) |

## 3. 빌드 도구 (별도 프로세스)

| 구성요소 | 버전 | 라이선스 |
|---|---|---|
| **wimlib** (`wimlib-imagex`) | 1.14.5 | **LGPL-3.0-or-later** (도구 일부 GPL-3.0). 베이스라인 빌드(ISO 에디션 나열·적용)에 사용. |

## 4. 가상화 런타임 — QEMU 및 의존 라이브러리 (별도 프로세스로 번들)

`vendor/qemu`로 동봉되는 구성요소(`scripts/qemu-bottles.lock.json` 기준, bottle: `arm64_tahoe`).
QEMU는 **별도 프로그램**으로 실행되며 MacSandbox 코드와 링크되지 않습니다(단순 묶음, aggregation).

| 구성요소 | 버전 | 라이선스(요지) |
|---|---|---|
| **qemu** | 10.2.1 | **GPL-2.0-only** (+ 일부 LGPL-2.1, BSD) |
| capstone | 5.0.7 | BSD-3-Clause |
| dtc / libfdt | 1.7.2 | GPL-2.0-or-later **및** BSD-2-Clause (libfdt 듀얼) |
| glib | 2.86.4 | LGPL-2.1-or-later |
| gnutls | 3.8.12 | LGPL-2.1-or-later (도구 GPL-3.0) |
| jpeg-turbo | 3.1.3 | BSD-3-Clause / IJG |
| libpng | 1.6.55 | PNG Reference Library License (libpng) |
| libslirp | 4.9.1 | BSD-3-Clause / MIT |
| libssh | 0.12.0 | LGPL-2.1 |
| libusb | 1.0.29 | LGPL-2.1-or-later |
| lzo | 2.10 | GPL-2.0-or-later |
| ncurses | 6.6 | MIT-style (X11) |
| pixman | 0.46.4 | MIT |
| snappy | 1.2.2 | BSD-3-Clause |
| vde | 2.3.3 | GPL-2.0-or-later (+ BSD/LGPL 부분) |
| zstd | 1.5.7 | BSD-3-Clause (또는 GPL-2.0 듀얼) |
| pcre2 | 10.47 | BSD-3-Clause |
| gettext (libintl) | (runtime) | LGPL-2.1-or-later (도구 GPL-3.0) |
| nettle | 3.10.2 | LGPL-3.0-or-later **또는** GPL-2.0-or-later |
| libtasn1 | 4.21.0 | LGPL-2.1-or-later |
| libunistring | 1.4.2 | LGPL-3.0-or-later **또는** GPL-2.0-or-later |
| p11-kit | 0.26.2 | BSD-3-Clause |
| ca-certificates | 2025-12-02 | MPL-2.0 (Mozilla CA 번들) |
| gmp | 6.3.0 | LGPL-3.0-or-later **또는** GPL-2.0-or-later |
| openssl@3 | 3.6.1 | Apache-2.0 |
| libidn2 | 2.3.8 | LGPL-3.0-or-later (+ GPL) |
| unbound | 1.24.2 | BSD-3-Clause |
| libevent | 2.1.12 | BSD-3-Clause |
| libnghttp2 | 1.68.0 | MIT |

> 위 라이선스 표기는 요약이며 일부 구성요소는 복수 라이선스/파일별 라이선스를 가집니다.
> 정확한 조건은 각 구성요소의 배포 라이선스 파일을 따릅니다. 배포 전 변호사 검토 권장.

---

## GPL/LGPL 소스 코드

GPL-2.0/LGPL/GPL-3.0이 적용되는 위 구성요소들의 **대응 소스 코드(Corresponding Source)** 는
`WRITTEN-OFFER.txt`의 서면 약정에 따라 제공됩니다. 배포본에 직접 동봉하려면
`python3 scripts/fetch_gpl_sources.py` 로 동봉 버전과 일치하는 소스 tarball을 `gpl-sources/`에 수집하세요.
