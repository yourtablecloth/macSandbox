# MacSandbox 라이선스 안내 (Licensing)

> ⚠️ 이 문서와 함께 제공되는 `COMMERCIAL-LICENSE.md`, `CLA.md`는 **법적 자문이 아닌 초안 템플릿**입니다.
> 정식 상용/듀얼 라이선스 출시 전 반드시 IP 변호사의 검토를 받으세요.

## 요약

**MacSandbox가 직접 작성한 코드는 듀얼 라이선스입니다.**

| 대상 | 라이선스 |
|---|---|
| **MacSandbox 자체 코드** (`src/**`, `Package.swift`, `scripts/**` 등 본 저장소의 저작물) | **(1) GPL-3.0-or-later** (오픈소스 에디션) **또는 (2) 상용 라이선스** ([COMMERCIAL-LICENSE.md](COMMERCIAL-LICENSE.md)) 중 택일 |
| 동봉 **QEMU** + 그 의존 라이브러리 | 각자의 GPL/LGPL/허용형 라이선스 (별도 프로그램, 재라이선스하지 않음) |
| 링크된 **FreeRDP/WinPR** | Apache-2.0 |
| 동봉 **edk2** 펌웨어 | BSD-2-Clause-Patent |
| 빌드 도구 **wimlib** | LGPL-3.0-or-later |

전체 제3자 구성요소 목록과 라이선스는 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)를 보세요.

## 듀얼 라이선스가 성립하는 이유 (아키텍처 전제)

1. **GPL 코드는 앱 바이너리에 링크되지 않음** — QEMU·wimlib는 **별도 프로세스**(fork/exec + QMP/RDP 소켓)로 실행됩니다. 따라서 GPL copyleft가 MacSandbox 바이너리에 전이되지 않으며, 본 저작물 코드를 자유롭게 이중 배포할 수 있습니다.
2. **바이너리에 링크되는 유일한 외부 라이브러리는 FreeRDP/WinPR(Apache-2.0)** — Apache-2.0은 GPL-3.0과 호환되고(단방향), 상용/독점 포함도 허용하므로 두 에디션 모두에서 링크 가능합니다.
3. **GPL-3.0 선택은 필수에 가깝습니다** — Apache-2.0은 GPL**v2**와는 비호환이라, libfreerdp를 합법적으로 링크하려면 본 코드가 **GPLv3**여야 합니다.

> 🚨 **유지 규칙**: QEMU/wimlib를 *in-process(dylib 링크)* 로 바꾸면 GPL이 바이너리에 전이되어 **듀얼 라이선스가 깨집니다.** 반드시 별도 프로세스로 유지하세요.

## 상용 에디션의 범위

- 상용 라이선스는 **MacSandbox 자체 코드에만** 적용됩니다.
- 동봉되는 **QEMU/wimlib 등은 상용 에디션에서도 GPL/LGPL 그대로** 배포되며, 그 소스 제공 의무([WRITTEN-OFFER.txt](WRITTEN-OFFER.txt))는 유지됩니다.
- 따라서 "GPL이 전혀 없는 순수 독점 패키지"는 아닙니다. 최종 사용자가 *사용*하는 데에는 제약이 없고(사용은 GPL 의무를 발생시키지 않음), 상용 고객이 제품을 **재배포**할 경우 QEMU 등의 GPL 의무는 고객이 이행합니다.

## 기여 (Contributions)

외부 기여를 듀얼 라이선스(상용 포함)로 재배포하려면 기여자의 동의가 필요합니다.
모든 기여자는 [CLA.md](CLA.md)에 동의해야 합니다. (단독 개발 단계에서는 불필요.)

## 컴플라이언스 산출물

- `LICENSE` — GPL-3.0 전문
- `THIRD-PARTY-NOTICES.md` — 제3자 구성요소·라이선스 목록
- `WRITTEN-OFFER.txt` — GPL/LGPL 구성요소 소스 코드 제공 서면 약정
- `scripts/fetch_gpl_sources.py` — 동봉 버전과 일치하는 GPL/LGPL 소스 tarball 수집(배포 동봉용)
- `scripts/apply_license_headers.py` — 소스 파일에 SPDX/라이선스 헤더 적용
