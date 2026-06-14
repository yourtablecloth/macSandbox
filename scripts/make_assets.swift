// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Copyright (C) 2026 Nam Jung Hyun (rkttu)
//
// 앱 아이콘(assets/AppIcon.png, 1024²)과 DMG 배경(assets/dmg-background.png, 660×400)을
// CoreGraphics로 렌더링한다. 트레이드마크 안전을 위해 Windows 로고가 아닌 macOS 스타일
// squircle + 흰 창(트래픽 라이트 점) 모티프를 쓴다. 재생성:  swift scripts/make_assets.swift
//
// MacSandbox is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY.

import AppKit

let projectDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let assetsDir = projectDir.appendingPathComponent("assets")
try? FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)

func renderPNG(width: Int, height: Int, to name: String, _ draw: (CGContext) -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    draw(ctx.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    let url = assetsDir.appendingPathComponent(name)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print("wrote \(url.path) (\(width)×\(height))")
}

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: a)
}

let cs = CGColorSpaceCreateDeviceRGB()

// ── 앱 아이콘 ────────────────────────────────────────────────────────────────
renderPNG(width: 1024, height: 1024, to: "AppIcon.png") { c in
    let S: CGFloat = 1024
    // macOS 11+ 아이콘 그리드: 여백 + 둥근 사각(squircle 근사)
    let margin: CGFloat = 100
    let side = S - 2 * margin
    let shape = CGRect(x: margin, y: margin, width: side, height: side)
    let squircle = CGPath(roundedRect: shape, cornerWidth: side * 0.2237, cornerHeight: side * 0.2237, transform: nil)

    // 배경 그라디언트(파랑 → 인디고)
    c.saveGState(); c.addPath(squircle); c.clip()
    let grad = CGGradient(colorsSpace: cs,
        colors: [rgb(0.31, 0.55, 0.97), rgb(0.29, 0.25, 0.79)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(grad, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0), options: [])
    // 상단 부드러운 하이라이트
    let hl = CGGradient(colorsSpace: cs,
        colors: [rgb(1, 1, 1, 0.22), rgb(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
    c.drawRadialGradient(hl, startCenter: CGPoint(x: S/2, y: S*0.82), startRadius: 0,
                         endCenter: CGPoint(x: S/2, y: S*0.82), endRadius: S*0.55, options: [])
    c.restoreGState()

    // 흰 창(타이틀바 + 트래픽 라이트 점) — Mac 창 안의 데스크톱 = 샌드박스 모티프
    let winW: CGFloat = 540, winH: CGFloat = 392
    let win = CGRect(x: (S-winW)/2, y: (S-winH)/2 - 8, width: winW, height: winH)
    let winPath = CGPath(roundedRect: win, cornerWidth: 46, cornerHeight: 46, transform: nil)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -16), blur: 44, color: rgb(0, 0, 0, 0.30))
    c.addPath(winPath); c.setFillColor(rgb(1, 1, 1)); c.fillPath()
    c.restoreGState()

    c.saveGState(); c.addPath(winPath); c.clip()
    let tbH: CGFloat = 96
    c.setFillColor(rgb(0.93, 0.94, 0.97))
    c.fill(CGRect(x: win.minX, y: win.maxY - tbH, width: winW, height: tbH))
    let dotY = win.maxY - tbH/2, dotR: CGFloat = 18
    let dots = [rgb(1.00, 0.37, 0.34), rgb(1.00, 0.74, 0.18), rgb(0.27, 0.84, 0.40)]
    for (i, col) in dots.enumerated() {
        let cx = win.minX + 50 + CGFloat(i) * 56
        c.setFillColor(col); c.fillEllipse(in: CGRect(x: cx-dotR, y: dotY-dotR, width: dotR*2, height: dotR*2))
    }
    // 본문 하단에 옅은 강조 바(데스크톱/작업표시줄 힌트)
    c.setFillColor(rgb(0.31, 0.55, 0.97, 0.16))
    c.fill(CGRect(x: win.minX, y: win.minY, width: winW, height: 46))
    c.restoreGState()
}

// ── DMG 배경 ─────────────────────────────────────────────────────────────────
func drawText(_ s: String, font: NSFont, color: NSColor, centerX: CGFloat, baselineY: CGFloat) {
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let str = NSAttributedString(string: s, attributes: attrs)
    let size = str.size()
    str.draw(at: NSPoint(x: centerX - size.width/2, y: baselineY))
}

renderPNG(width: 660, height: 400, to: "dmg-background.png") { c in
    // 옅은 그라디언트 배경
    let bg = CGGradient(colorsSpace: cs,
        colors: [rgb(0.975, 0.982, 1.0), rgb(0.90, 0.93, 0.98)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(bg, start: CGPoint(x: 0, y: 400), end: CGPoint(x: 0, y: 0), options: [])

    // 안내 문구(상단) — 이미지 좌표는 y-up, Finder 표시 시 위가 위쪽
    drawText("macSandbox for Windows",
             font: .systemFont(ofSize: 24, weight: .semibold), color: NSColor(white: 0.20, alpha: 1),
             centerX: 330, baselineY: 332)
    drawText("Drag the app into the Applications folder",
             font: .systemFont(ofSize: 14, weight: .regular), color: NSColor(white: 0.42, alpha: 1),
             centerX: 330, baselineY: 304)

    // 아이콘(앱 ↔ Applications) 사이를 가리키는 화살표 — 세로 중앙(아이콘 y와 정렬)
    c.setStrokeColor(rgb(0.50, 0.56, 0.68, 0.9))
    c.setLineWidth(9); c.setLineCap(.round); c.setLineJoin(.round)
    let ay: CGFloat = 182   // 400 - 218(Finder 아이콘 y)
    c.move(to: CGPoint(x: 268, y: ay)); c.addLine(to: CGPoint(x: 392, y: ay)); c.strokePath()
    c.move(to: CGPoint(x: 368, y: ay+20)); c.addLine(to: CGPoint(x: 394, y: ay)); c.addLine(to: CGPoint(x: 368, y: ay-20))
    c.strokePath()
}
