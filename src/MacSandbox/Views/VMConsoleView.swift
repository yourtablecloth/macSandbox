import SwiftUI

/// SwiftUI KeyPress → QEMU qcode 매핑
enum QKeyMap {
    /// 특수 키 (KeyEquivalent.character 기준)
    static let specialByChar: [Character: [String]] = [
        KeyEquivalent.return.character: ["ret"],
        KeyEquivalent.escape.character: ["esc"],
        KeyEquivalent.tab.character: ["tab"],
        KeyEquivalent.delete.character: ["backspace"],
        KeyEquivalent.deleteForward.character: ["delete"],
        KeyEquivalent.upArrow.character: ["up"],
        KeyEquivalent.downArrow.character: ["down"],
        KeyEquivalent.leftArrow.character: ["left"],
        KeyEquivalent.rightArrow.character: ["right"],
        KeyEquivalent.home.character: ["home"],
        KeyEquivalent.end.character: ["end"],
        KeyEquivalent.pageUp.character: ["pgup"],
        KeyEquivalent.pageDown.character: ["pgdn"],
        KeyEquivalent.space.character: ["spc"]
    ]

    /// 기호 → qcode 직접 매핑
    static let directSymbol: [Character: String] = [
        "-": "minus", "=": "equal", "[": "bracket_left", "]": "bracket_right",
        "\\": "backslash", ";": "semicolon", "'": "apostrophe", "`": "grave_accent",
        ",": "comma", ".": "dot", "/": "slash"
    ]

    /// shift 필요한 기호 → 기준 qcode
    static let shiftSymbol: [Character: String] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7",
        "*": "8", "(": "9", ")": "0", "_": "minus", "+": "equal",
        "{": "bracket_left", "}": "bracket_right", "|": "backslash",
        ":": "semicolon", "\"": "apostrophe", "~": "grave_accent",
        "<": "comma", ">": "dot", "?": "slash"
    ]

    static func qcodes(for press: KeyPress) -> [String]? {
        if let special = specialByChar[press.key.character] { return special }
        guard let ch = press.characters.first else { return nil }
        return qcodes(forCharacter: ch)
    }

    static func qcodes(forCharacter c: Character) -> [String]? {
        if c == " " { return ["spc"] }
        if let q = directSymbol[c] { return [q] }
        if let q = shiftSymbol[c] { return ["shift", q] }
        if c.isLetter {
            let lower = String(c).lowercased()
            guard lower.count == 1 else { return nil }
            return c.isUppercase ? ["shift", lower] : [lower]
        }
        if c.isNumber, c.isASCII { return [String(c)] }
        return nil
    }
}

/// 실행 중인 VM 화면을 표시하고 키보드/마우스 입력으로 개입할 수 있는 인터랙티브 콘솔.
struct VMConsoleView: View {
    @ObservedObject var console: VMConsole
    @FocusState private var focused: Bool

    private var aspectRatio: CGFloat {
        if let size = console.frame?.size, size.height > 0 {
            return size.width / size.height
        }
        return 4.0 / 3.0
    }

    var body: some View {
        VStack(spacing: 8) {
            screen
            helperBar
            Text(focused
                 ? "콘솔 포커스됨 — 키보드 입력이 게스트로 전달됩니다. 화면을 클릭하면 해당 위치로 클릭이 전달됩니다."
                 : "화면을 클릭해 포커스하면 키보드 입력이 게스트로 전달됩니다.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var screen: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let frame = console.frame {
                    Image(nsImage: frame)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                } else {
                    VStack(spacing: 8) {
                        ProgressView().tint(.white)
                        Text(console.isConnected ? "화면 수신 대기 중..." : "VM 연결 중...")
                            .font(.caption).foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        focused = true
                        guard geo.size.width > 0, geo.size.height > 0 else { return }
                        console.click(
                            fractionX: value.location.x / geo.size.width,
                            fractionY: value.location.y / geo.size.height
                        )
                    }
            )
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(focused ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: focused ? 2 : 1)
        )
        .focusable()
        .focused($focused)
        .onKeyPress(phases: .down) { press in
            guard let combo = QKeyMap.qcodes(for: press) else { return .ignored }
            console.sendKeyCombo(combo)
            return .handled
        }
    }

    private var helperBar: some View {
        HStack(spacing: 6) {
            keyButton("↓", ["down"])
            keyButton("Enter", ["ret"])
            keyButton("Esc", ["esc"])
            keyButton("Tab", ["tab"])
            keyButton("⌫", ["backspace"])
            Divider().frame(height: 16)
            Button("Ctrl+Alt+Del") { console.sendKeyCombo(["ctrl", "alt", "delete"]) }
                .controlSize(.small)
            Spacer()
            Circle()
                .fill(console.isConnected ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(console.isConnected ? "연결됨" : "대기").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func keyButton(_ label: String, _ qcodes: [String]) -> some View {
        Button(label) { console.sendKeyCombo(qcodes) }
            .controlSize(.small)
    }
}
