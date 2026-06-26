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

/// Lightweight Markdown renderer (no dependencies) for static documents such as the terms.
///
/// Parses block by block: `#`/`##`/`###` headings, `-`/`*` bullet lists, `1.` numbered lists,
/// `>` quotes, `---` dividers, blank lines (paragraph separators), and other paragraphs. Inline (bold/italic/link/code) is
/// handled by `AttributedString(markdown:)` (inline-only). Complex elements such as tables/images/code fences
/// are not supported (sufficient for the terms level).
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

    // MARK: - Block parsing

    private struct Block: Identifiable {
        let id = UUID()
        let view: AnyView
    }

    private func blocks() -> [Block] {
        var result: [Block] = []
        var paragraph: [String] = []   // Merges consecutive body lines, up to a blank line, into a single paragraph

        // Emit the accumulated body lines as a single paragraph (so inline bold/italic matches even across lines).
        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let text = paragraph.joined(separator: " ")
            result.append(Block(view: AnyView(paragraphView(text))))
            paragraph.removeAll()
        }

        for rawLine in markdown.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flushParagraph(); continue }   // Paragraph boundary

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
                paragraph.append(line)   // Body — accumulate (emit merged when a blank line/another block is reached)
            }
        }
        flushParagraph()
        return result
    }

    private func heading(_ line: String) -> (Int, String)? {
        for level in [3, 2, 1] {   // Check ### first (longer prefix takes priority)
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

    // MARK: - Block rendering

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

    /// Interprets only inline Markdown (bold/italic/link/code). Block markers are removed before the call.
    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(s)
    }
}
