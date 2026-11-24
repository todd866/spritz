#!/usr/bin/env python3
"""Generate original AppIcon.icns and template MenuBarIcon.pdf via CoreGraphics/AppKit."""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

RESOURCES_DIR = Path(__file__).resolve().parent.parent / "macos" / "Resources"

SWIFT_DRAW = r'''
import AppKit
import CoreGraphics
import Foundation

let args = CommandLine.arguments
let iconsetDir = URL(fileURLWithPath: args[1], isDirectory: true)
let menuBarPDF = URL(fileURLWithPath: args[2])

func renderAppIcon(pixels: Int, to url: URL) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixels, height: pixels)
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext

    let s = CGFloat(pixels)
    let pad = s * 0.09
    let box = CGRect(x: pad, y: pad, width: s - pad * 2, height: s - pad * 2)
    let bgPath = CGPath(roundedRect: box, cornerWidth: s * 0.22, cornerHeight: s * 0.22, transform: nil)

    // Warm citrus gradient squircle
    cg.saveGState()
    cg.addPath(bgPath)
    cg.clip()
    let cs = CGColorSpaceCreateDeviceRGB()
    let colors = [
        CGColor(colorSpace: cs, components: [1.0, 0.72, 0.14, 1.0])!,
        CGColor(colorSpace: cs, components: [0.96, 0.37, 0.13, 1.0])!,
    ] as CFArray
    let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0.0, 1.0])!
    cg.drawLinearGradient(
        grad,
        start: CGPoint(x: box.minX, y: box.maxY),
        end: CGPoint(x: box.maxX, y: box.minY),
        options: []
    )

    // Subtle inner highlight border
    cg.restoreGState()
    cg.setStrokeColor(CGColor(colorSpace: cs, components: [1.0, 1.0, 1.0, 0.25])!)
    cg.setLineWidth(max(1.0, s * 0.015))
    cg.addPath(bgPath)
    cg.strokePath()

    // Crisp 2x2 instrument keycap grid representing one-key emoji selection
    let inner = box.insetBy(dx: box.width * 0.20, dy: box.height * 0.20)
    let gap = inner.width * 0.13
    let cell = (inner.width - gap) / 2.0
    let r = cell * 0.28

    for row in 0..<2 {
        for col in 0..<2 {
            let x = inner.minX + CGFloat(col) * (cell + gap)
            let y = inner.minY + CGFloat(1 - row) * (cell + gap)
            let cr = CGRect(x: x, y: y, width: cell, height: cell)
            let isAccentCell = (row == 0 && col == 1)
            let path = CGPath(roundedRect: cr, cornerWidth: r, cornerHeight: r, transform: nil)
            cg.setFillColor(
                CGColor(colorSpace: cs, components: isAccentCell ? [1.0, 0.96, 0.78, 1.0] : [1.0, 1.0, 1.0, 0.90])!
            )
            cg.addPath(path)
            cg.fillPath()
        }
    }

    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: url)
}

func renderMenuBarTemplate(to url: URL) {
    var box = CGRect(x: 0, y: 0, width: 16, height: 16)
    let pdfData = NSMutableData()
    guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
          let cg = CGContext(consumer: consumer, mediaBox: &box, nil) else {
        fatalError("Could not create PDF context")
    }
    cg.beginPDFPage(nil)
    cg.setFillColor(CGColor(gray: 0.0, alpha: 1.0))

    // Compact 2x2 rounded tiles + top-right diamond accent matching AppIcon motif
    let cells: [(CGFloat, CGFloat, Bool)] = [
        (2.0, 9.0, false),
        (9.0, 9.0, true),
        (2.0, 2.0, false),
        (9.0, 2.0, false),
    ]
    for (x, y, accent) in cells {
        if accent {
            let cx = x + 2.5
            let cy = y + 2.5
            let d: CGFloat = 2.7
            let diamond = CGMutablePath()
            diamond.move(to: CGPoint(x: cx, y: cy + d))
            diamond.addLine(to: CGPoint(x: cx + d, y: cy))
            diamond.addLine(to: CGPoint(x: cx, y: cy - d))
            diamond.addLine(to: CGPoint(x: cx - d, y: cy))
            diamond.closeSubpath()
            cg.addPath(diamond)
            cg.fillPath()
        } else {
            let rect = CGRect(x: x, y: y, width: 5.0, height: 5.0)
            cg.addPath(CGPath(roundedRect: rect, cornerWidth: 1.4, cornerHeight: 1.4, transform: nil))
            cg.fillPath()
        }
    }
    cg.endPDFPage()
    cg.closePDF()
    try! pdfData.write(to: url, options: .atomic)
}

let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]
for (px, name) in sizes {
    renderAppIcon(pixels: px, to: iconsetDir.appendingPathComponent(name))
}
renderMenuBarTemplate(to: menuBarPDF)
'''


def main() -> int:
    RESOURCES_DIR.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="spritz_icons_") as tmp:
        tmp_path = Path(tmp)
        iconset = tmp_path / "AppIcon.iconset"
        iconset.mkdir()
        swift_src = tmp_path / "gen.swift"
        swift_src.write_text(SWIFT_DRAW, encoding="utf-8")
        pdf_out = RESOURCES_DIR / "MenuBarIcon.pdf"
        icns_out = RESOURCES_DIR / "AppIcon.icns"

        subprocess.run(["swift", str(swift_src), str(iconset), str(pdf_out)], check=True)
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(icns_out)], check=True)
        print(f"Generated {icns_out} and {pdf_out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
