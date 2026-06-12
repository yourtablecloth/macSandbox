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
import AppKit

/// 실행 중인 VM의 인터랙티브 콘솔.
///
/// QMP 단일 연결을 직렬 큐에서 다루며:
/// - 게스트 화면을 주기적으로 캡처해 `frame`으로 게시 (인앱 모니터링)
/// - 사용자의 키보드/마우스 입력을 게스트로 전달 (개입)
final class VMConsole: ObservableObject {

    @Published private(set) var frame: NSImage?
    @Published private(set) var isConnected = false

    private let injector: QMPInputInjector
    private let qmpQueue = DispatchQueue(label: "MacSandbox.qmp")
    private let framePath: String
    private let capturesFrames: Bool

    // qmpQueue 전용 상태
    private var running = false
    private var lastFrameData: Data?

    init(socketPath: String, capturesFrames: Bool) {
        self.injector = QMPInputInjector(socketPath: socketPath)
        self.capturesFrames = capturesFrames
        self.framePath = "/tmp/msbx-frame-\(UUID().uuidString.prefix(8)).png"
    }

    // MARK: - 수명주기

    /// 연결 + 화면 폴링 시작.
    func start() {
        qmpQueue.async { [weak self] in
            guard let self else { return }
            self.running = true
            let ok = self.injector.connect()
            DispatchQueue.main.async { self.isConnected = ok }
            if ok { self.tick() }
        }
    }

    func stop() {
        qmpQueue.async { [weak self] in
            self?.running = false
            self?.injector.close()
        }
        DispatchQueue.main.async { [weak self] in self?.isConnected = false }
    }

    // MARK: - 입력 (UI에서 호출)

    func sendKey(_ qcode: String) {
        qmpQueue.async { [weak self] in self?.injector.sendKey(qcode) }
    }

    func sendKeyCombo(_ qcodes: [String]) {
        qmpQueue.async { [weak self] in self?.injector.sendKeyCombo(qcodes) }
    }

    /// 화면 비율 좌표(0...1)로 클릭
    func click(fractionX: Double, fractionY: Double, button: String = "left") {
        let x = Int((max(0, min(1, fractionX))) * 32767)
        let y = Int((max(0, min(1, fractionY))) * 32767)
        qmpQueue.async { [weak self] in
            self?.injector.moveAbsolute(x: x, y: y)
            self?.injector.click(button: button)
        }
    }

    // MARK: - Private (qmpQueue)

    private func tick() {
        guard running else { return }

        // 화면 캡처 → 게시. 직전 프레임과 같으면 게시를 생략해
        // 정적 화면(부팅 단계 등)에서 불필요한 뷰 재렌더를 막는다.
        if capturesFrames {
            injector.screendump(to: framePath)
            if let data = try? Data(contentsOf: URL(fileURLWithPath: framePath)),
               data != lastFrameData,
               let image = NSImage(data: data) {
                lastFrameData = data
                DispatchQueue.main.async { [weak self] in self?.frame = image }
            }
        }

        qmpQueue.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.tick() }
    }
}
