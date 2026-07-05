#!/usr/bin/env swift
// One-off generator for Packaging/AppIcon.iconset (Infra B packaging asset).
// Reproduces the "App icon" mockup from the Clean Mac visual style guide
// exactly: a 200x200 reference grid with a 140x140 rounded tile (30px margin,
// 30px corner radius) in Ink (#1C1C1E), carrying the aperture-ring mark —
// a 34pt-radius, 10pt-stroke ring at 30% white for the track and full white
// for the ~75%-closed progress arc (dasharray 160 of a 213.63 circumference,
// matching section 02/07 of the guide).
import AppKit
import Foundation

let referenceCanvas: CGFloat = 200
let tileMargin: CGFloat = 30
let tileSize: CGFloat = 140
let tileCornerRadius: CGFloat = 30
let ringRadius: CGFloat = 34
let ringLineWidth: CGFloat = 10
let ringFraction: CGFloat = 160.0 / (2 * .pi * ringRadius) // ≈ 0.749, from the guide's own dasharray

let ink = NSColor(calibratedRed: 0x1C / 255.0, green: 0x1C / 255.0, blue: 0x1E / 255.0, alpha: 1)

func render(size: Int) -> Data {
    let scale = CGFloat(size) / referenceCanvas
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("could not allocate bitmap") }
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let tileRect = NSRect(x: tileMargin * scale, y: tileMargin * scale,
                          width: tileSize * scale, height: tileSize * scale)
    ink.setFill()
    NSBezierPath(roundedRect: tileRect, xRadius: tileCornerRadius * scale,
                yRadius: tileCornerRadius * scale).fill()

    let center = NSPoint(x: CGFloat(size) / 2, y: CGFloat(size) / 2)
    let radius = ringRadius * scale
    let lineWidth = ringLineWidth * scale

    let track = NSBezierPath()
    track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
    track.lineWidth = lineWidth
    NSColor.white.withAlphaComponent(0.3).setStroke()
    track.stroke()

    // Top (90°), sweeping clockwise (decreasing angle in AppKit's math
    // convention) by the brand's ~75% fraction — leaves the "space you got
    // back" gap at upper-left, matching the guide's default lockup.
    let sweepDegrees = 360.0 * ringFraction
    let arc = NSBezierPath()
    arc.appendArc(withCenter: center, radius: radius,
                 startAngle: 90, endAngle: 90 - sweepDegrees, clockwise: true)
    arc.lineWidth = lineWidth
    arc.lineCapStyle = .round
    NSColor.white.setStroke()
    arc.stroke()

    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("PNG encoding failed")
    }
    return png
}

let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Packaging/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let targets: [(name: String, size: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

for target in targets {
    let data = render(size: target.size)
    let path = "\(outDir)/\(target.name)"
    try! data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path) (\(target.size)x\(target.size))")
}
