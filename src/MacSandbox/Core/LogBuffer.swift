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

import Foundation

/// UI용 스로틀링 로그 스토어.
///
/// QEMU 출력은 부팅 중 줄 단위로 빠르게 쏟아지는데, 한 줄마다 `@Published`를 갱신하면
/// 이를 관찰하는 뷰 트리 전체가 매번 재렌더되어 부팅 오버레이가 버벅인다.
/// 추가분을 모아 최대 4Hz로만 게시하고, 표시 길이도 상한을 둬 Text 렌더 비용을 묶는다.
@MainActor
final class LogBuffer: ObservableObject {

    @Published private(set) var text: String = ""

    /// 표시 상한(문자 수). 초과 시 앞부분을 잘라 최근 로그만 유지한다(전체 로그는 별도 보관 안 함).
    private let maxLength = 64 * 1024
    private let flushInterval: Duration = .milliseconds(250)

    private var pending = ""
    private var flushScheduled = false

    func append(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else { return }
        pending += trimmed + "\n"
        scheduleFlush()
    }

    func clear() {
        pending = ""
        text = ""
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: flushInterval)
            self.flush()
        }
    }

    private func flush() {
        flushScheduled = false
        guard !pending.isEmpty else { return }
        var merged = text + pending
        pending = ""
        if merged.count > maxLength {
            // 줄 경계에 맞춰 앞부분을 버린다.
            let cut = merged.index(merged.endIndex, offsetBy: -maxLength)
            if let nl = merged[cut...].firstIndex(of: "\n") {
                merged = String(merged[merged.index(after: nl)...])
            } else {
                merged = String(merged[cut...])
            }
        }
        text = merged
    }
}
