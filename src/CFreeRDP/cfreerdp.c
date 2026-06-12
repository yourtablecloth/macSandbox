// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Copyright (C) 2026 Nam Jung Hyun (rkttu) <rkttu.official@gmail.com>
//
// This file is part of MacSandbox, which is dual-licensed:
//   (1) under the GNU Affero General Public License v3.0 or later (see LICENSE), or
//   (2) under a commercial license (see COMMERCIAL-LICENSE.md).
// You may use this file under the terms of either license.
//
// MacSandbox is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE.

#include "CFreeRDP.h"

#include <freerdp/freerdp.h>
#include <freerdp/version.h>

#include <stdio.h>

const char *cfreerdp_link_test(void) {
    // freerdp 인스턴스 생성/해제 — 심볼이 실제로 링크돼야 성공한다.
    freerdp *instance = freerdp_new();
    static char buf[64];
    if (instance) {
        freerdp_free(instance);
        snprintf(buf, sizeof(buf), "libfreerdp %s (freerdp_new OK)", FREERDP_VERSION_FULL);
    } else {
        snprintf(buf, sizeof(buf), "libfreerdp %s (freerdp_new NULL)", FREERDP_VERSION_FULL);
    }
    return buf;
}
