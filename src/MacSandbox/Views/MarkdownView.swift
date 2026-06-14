// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Copyright (C) 2026 Nam Jung Hyun (rkttu)
//
// This file is part of MacSandbox, which is dual-licensed:
//   (1) under the GNU Affero General Public License v3.0 or later (see LICENSE), or
//   (2) under a commercial license (see COMMERCIAL-LICENSE.md).
// You may use this file under the terms of either license.
//
// MacSandbox is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE.

import SwiftUI

/// 약관 등 정적 문서를 위한 가벼운 마크다운 렌더러(의존성 없음).
///
/// 블록 단위로 파싱한다: `#`/`##`/`###` 헤딩, `-`/`*` 글머리 목록, `1.` 번호 목록,
/// `>` 인용, `---` 구분선, 빈 줄(문단 구분), 그 외 문단. 인라인(굵게/기울임/링크/코드)은
/// `AttributedString(markdown:)`(inline-only)로 처리한다. 표·이미지·코드펜스 등 복잡한
/// 요소는 지원하지 않는다(약관 수준엔 충분).
struct MarkdownView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(blocks().enumerated()), id: \.offset) { _, block in
                block.view
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    // MARK: - 블록 파싱

    private struct Block: Identifiable {
        let id = UUID()
        let view: AnyView
    }

    private func blocks() -> [Block] {
        var result: [Block] = []
        var paragraph: [String] = []   // 빈 줄 전까지 연속된 본문 줄을 한 문단으로 합친다

        // 본문 줄 누적분을 하나의 문단으로 방출(인라인 굵게/이탤릭이 줄에 걸쳐도 매칭되도록).
        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let text = paragraph.joined(separator: " ")
            result.append(Block(view: AnyView(paragraphView(text))))
            paragraph.removeAll()
        }

        for rawLine in markdown.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flushParagraph(); continue }   // 문단 경계

            if line == "---" || line == "***" || line == "___" {
                flushParagraph()
                result.append(Block(view: AnyView(Divider().padding(.vertical, 2))))
            } else if let (level, text) = heading(line) {
                flushParagraph()
                result.append(Block(view: AnyView(headingView(level: level, text: text))))
            } else if let item = bullet(line) {
                flushParagraph()
                result.append(Block(view: AnyView(listRow(marker: "•", text: item))))
            } else if let (number, item) = numbered(line) {
                flushParagraph()
                result.append(Block(view: AnyView(listRow(marker: "\(number).", text: item))))
            } else if let quote = blockquote(line) {
                flushParagraph()
                result.append(Block(view: AnyView(quoteView(quote))))
            } else {
                paragraph.append(line)   // 본문 — 누적(빈 줄/다른 블록을 만나면 합쳐 방출)
            }
        }
        flushParagraph()
        return result
    }

    private func heading(_ line: String) -> (Int, String)? {
        for level in [3, 2, 1] {   // ### 먼저 검사(더 긴 접두어 우선)
            let prefix = String(repeating: "#", count: level) + " "
            if line.hasPrefix(prefix) { return (level, String(line.dropFirst(prefix.count))) }
        }
        return nil
    }

    private func bullet(_ line: String) -> String? {
        for p in ["- ", "* "] where line.hasPrefix(p) { return String(line.dropFirst(2)) }
        return nil
    }

    private func numbered(_ line: String) -> (Int, String)? {
        guard let dot = line.firstIndex(of: "."),
              let n = Int(line[line.startIndex..<dot]),
              line.index(after: dot) < line.endIndex,
              line[line.index(after: dot)] == " " else { return nil }
        return (n, String(line[line.index(dot, offsetBy: 2)...]))
    }

    private func blockquote(_ line: String) -> String? {
        line.hasPrefix("> ") ? String(line.dropFirst(2)) : (line == ">" ? "" : nil)
    }

    // MARK: - 블록 렌더

    private func headingView(level: Int, text: String) -> some View {
        let font: Font = level == 1 ? .title2.bold()
            : (level == 2 ? .title3.bold() : .headline)
        return Text(inline(text))
            .font(font)
            .padding(.top, level <= 2 ? 6 : 2)
    }

    private func listRow(marker: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(marker).foregroundStyle(.secondary).monospacedDigit()
            Text(inline(text)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 6)
    }

    private func quoteView(_ text: String) -> some View {
        HStack(spacing: 8) {
            Rectangle().fill(.secondary.opacity(0.4)).frame(width: 3)
            Text(inline(text)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 4)
    }

    private func paragraphView(_ text: String) -> some View {
        Text(inline(text)).fixedSize(horizontal: false, vertical: true)
    }

    /// 인라인 마크다운(굵게/기울임/링크/코드)만 해석. 블록 마커는 호출 전 제거됨.
    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(s)
    }
}
