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

/// Windows Sandbox `.wsb`(XML) 구성 파일 → SandboxConfig 변환 + 커맨드라인 스위치 파싱.
///
/// `.wsb` 스키마(Windows Sandbox와 호환): `<Configuration>` 아래
/// `VGpu`/`Networking`/`AudioInput`/`VideoInput`/`ClipboardRedirection`/`PrinterRedirection`
/// (값: `Enable`|`Disable`|`Default`), `MemoryInMB`, `LogonCommand><Command`,
/// `MappedFolders><MappedFolder><HostFolder`/`ReadOnly`.
/// 시작은 Windows Sandbox 표준 기본값(`SandboxConfig()`)이고, 파일/스위치에 명시된 항목만 덮어쓴다.
/// (HostFolder는 macOS 호스트 경로로 해석한다.)
enum WSBConfig {

    enum WSBError: LocalizedError {
        case unreadable(String)
        var errorDescription: String? {
            switch self {
            case .unreadable(let r): return L("error.wsbUnreadable", r)
            }
        }
    }

    /// `.wsb` 파일을 읽어 SandboxConfig로 변환.
    static func load(path: String) throws -> SandboxConfig {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let data = try? Data(contentsOf: url) else {
            throw WSBError.unreadable(url.path)
        }
        guard let doc = try? XMLDocument(data: data, options: []) else {
            throw WSBError.unreadable("XML parse failed: \(url.lastPathComponent)")
        }
        return parse(doc: doc)
    }

    /// XMLDocument → SandboxConfig (기본값에서 명시 항목만 덮어쓰기)
    static func parse(doc: XMLDocument) -> SandboxConfig {
        var c = SandboxConfig()
        guard let root = doc.rootElement() else { return c }

        func text(_ name: String, in parent: XMLElement) -> String? {
            parent.elements(forName: name).first?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        /// Enable/Disable/Default 3-상태. Default(또는 미지정/미인식)면 nil → 기본값 유지.
        func tri(_ name: String) -> Bool? {
            guard let v = text(name, in: root)?.lowercased() else { return nil }
            switch v {
            case "enable", "true", "1", "on", "yes": return true
            case "disable", "false", "0", "off", "no": return false
            default: return nil
            }
        }

        if let v = tri("VGpu") { c.vGpuEnabled = v }
        if let v = tri("Networking") { c.networkingEnabled = v }
        if let v = tri("AudioInput") { c.audioInputEnabled = v }
        if let v = tri("VideoInput") { c.videoInputEnabled = v }
        if let v = tri("ClipboardRedirection") { c.clipboardEnabled = v }
        if let v = tri("PrinterRedirection") { c.printerEnabled = v }
        if let m = text("MemoryInMB", in: root), let mb = Int(m) { c.memoryMB = mb }
        if let m = text("CpuCores", in: root), let n = Int(m) { c.cpuCores = n }  // 확장(WS엔 없음)

        if let lc = root.elements(forName: "LogonCommand").first,
           let cmd = text("Command", in: lc), !cmd.isEmpty {
            c.logonCommand = cmd
        }
        if let mf = root.elements(forName: "MappedFolders").first {
            for folder in mf.elements(forName: "MappedFolder") {
                guard let host = text("HostFolder", in: folder), !host.isEmpty else { continue }
                let ro = text("ReadOnly", in: folder)?.lowercased() == "true"
                let sandbox = text("SandboxFolder", in: folder) ?? ""  // 비우면 바탕화면 자동 마운트
                c.mappedFolders.append(MappedFolder(
                    hostPath: (host as NSString).expandingTildeInPath, readOnly: ro, sandboxPath: sandbox))
            }
        }
        return c
    }

    /// 불리언 스위치 값 파싱 (on/off/true/false/enable/disable/1/0). 인식 실패 시 true(존재=켜짐).
    static func boolFlag(_ s: String) -> Bool {
        switch s.lowercased() {
        case "off", "false", "0", "disable", "no", "n": return false
        default: return true
        }
    }

    /// 사람이 읽는 한 줄 요약 (UI/로그용)
    static func summaryLines(_ c: SandboxConfig) -> [(String, String)] {
        var rows: [(String, String)] = [
            ("Memory", "\(c.memoryMB) MB"),
            ("CPU cores", "\(c.cpuCores)"),
            ("Networking", c.networkingEnabled ? "on" : "off"),
            ("Clipboard", c.clipboardEnabled ? "on" : "off"),
            ("Audio/microphone", c.audioInputEnabled ? "on" : "off"),
            ("Printer", c.printerEnabled ? "on" : "off"),
            ("vGPU (console)", c.vGpuEnabled ? "virtio-gpu" : "ramfb"),
        ]
        if !c.mappedFolders.isEmpty {
            rows.append(("Shared folders", c.mappedFolders.map { ($0.hostPath as NSString).lastPathComponent }.joined(separator: ", ")))
        }
        if !c.logonCommand.isEmpty {
            rows.append(("Logon command", c.logonCommand))
        }
        return rows
    }
}
