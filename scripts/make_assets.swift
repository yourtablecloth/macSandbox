// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Copyright (C) 2026 Nam Jung Hyun (rkttu)
//
// Renders the app icon (assets/AppIcon.png, 1024²) and the DMG background (assets/dmg-background.png, 660×400)
// with CoreGraphics. For trademark safety, it uses a macOS-style squircle + white window (traffic-light dots)
// motif rather than a Windows logo. Regenerate:  swift scripts/make_assets.swift
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

// ── App icon ────────────────────────────────────────────────────────────────
renderPNG(width: 1024, height: 1024, to: "AppIcon.png") { c in
    let S: CGFloat = 1024
    // macOS 11+ icon grid: margin + rounded rect (squircle approximation)
    let margin: CGFloat = 100
    let side = S - 2 * margin
    let shape = CGRect(x: margin, y: margin, width: side, height: side)
    let squircle = CGPath(roundedRect: shape, cornerWidth: side * 0.2237, cornerHeight: side * 0.2237, transform: nil)

    // Background gradient (blue → indigo)
    c.saveGState(); c.addPath(squircle); c.clip()
    let grad = CGGradient(colorsSpace: cs,
        colors: [rgb(0.31, 0.55, 0.97), rgb(0.29, 0.25, 0.79)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(grad, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0), options: [])
    // Soft highlight at the top
    let hl = CGGradient(colorsSpace: cs,
        colors: [rgb(1, 1, 1, 0.22), rgb(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
    c.drawRadialGradient(hl, startCenter: CGPoint(x: S/2, y: S*0.82), startRadius: 0,
                         endCenter: CGPoint(x: S/2, y: S*0.82), endRadius: S*0.55, options: [])
    c.restoreGState()

    // White window (title bar + traffic-light dots) — a desktop inside a Mac window = sandbox motif
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
    // Faint accent bar at the bottom of the body (desktop/taskbar hint)
    c.setFillColor(rgb(0.31, 0.55, 0.97, 0.16))
    c.fill(CGRect(x: win.minX, y: win.minY, width: winW, height: 46))
    c.restoreGState()
}

// ── DMG background ─────────────────────────────────────────────────────────────────
func drawText(_ s: String, font: NSFont, color: NSColor, centerX: CGFloat, baselineY: CGFloat) {
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let str = NSAttributedString(string: s, attributes: attrs)
    let size = str.size()
    str.draw(at: NSPoint(x: centerX - size.width/2, y: baselineY))
}

renderPNG(width: 660, height: 400, to: "dmg-background.png") { c in
    // Faint gradient background
    let bg = CGGradient(colorsSpace: cs,
        colors: [rgb(0.975, 0.982, 1.0), rgb(0.90, 0.93, 0.98)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(bg, start: CGPoint(x: 0, y: 400), end: CGPoint(x: 0, y: 0), options: [])

    // Guidance text (top) — image coordinates are y-up, and in Finder the top is up
    drawText("macSandbox for Windows",
             font: .systemFont(ofSize: 24, weight: .semibold), color: NSColor(white: 0.20, alpha: 1),
             centerX: 330, baselineY: 332)
    drawText("Drag the app into the Applications folder",
             font: .systemFont(ofSize: 14, weight: .regular), color: NSColor(white: 0.42, alpha: 1),
             centerX: 330, baselineY: 304)

    // Arrow pointing between the icons (app ↔ Applications) — vertically centered (aligned with the icon y)
    c.setStrokeColor(rgb(0.50, 0.56, 0.68, 0.9))
    c.setLineWidth(9); c.setLineCap(.round); c.setLineJoin(.round)
    let ay: CGFloat = 182   // 400 - 218 (Finder icon y)
    c.move(to: CGPoint(x: 268, y: ay)); c.addLine(to: CGPoint(x: 392, y: ay)); c.strokePath()
    c.move(to: CGPoint(x: 368, y: ay+20)); c.addLine(to: CGPoint(x: 394, y: ay)); c.addLine(to: CGPoint(x: 368, y: ay-20))
    c.strokePath()
}
