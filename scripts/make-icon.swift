#!/usr/bin/env swift
// Renders Orbit's app icon into App/Assets.xcassets/AppIcon.appiconset.
// Usage: swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = root.appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    let cg = context.cgContext
    let s = CGFloat(size) / 1024
    cg.scaleBy(x: s, y: s)

    // Squircle body with a soft shadow (macOS icon grid: 824pt body inside 1024).
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor(red: 0.25, green: 0.18, blue: 0.62, alpha: 1).setFill()
    shape.fill()
    cg.restoreGState()

    cg.saveGState()
    shape.addClip()
    let background = NSGradient(colors: [
        NSColor(red: 0.47, green: 0.40, blue: 0.99, alpha: 1),
        NSColor(red: 0.29, green: 0.20, blue: 0.75, alpha: 1),
        NSColor(red: 0.13, green: 0.09, blue: 0.38, alpha: 1),
    ], atLocations: [0, 0.55, 1], colorSpace: .deviceRGB)!
    background.draw(in: body, angle: -60)
    // Starfield
    let stars: [(CGFloat, CGFloat, CGFloat)] = [(240, 760, 7), (330, 830, 4), (780, 790, 6), (840, 640, 4), (200, 330, 5), (760, 230, 7), (630, 860, 3), (300, 200, 3)]
    NSColor.white.withAlphaComponent(0.75).setFill()
    for (x, y, r) in stars { NSBezierPath(ovalIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)).fill() }
    cg.restoreGState()

    let center = CGPoint(x: 512, y: 500)
    let ringTransform = { (cg: CGContext) in
        cg.translateBy(x: center.x, y: center.y)
        cg.rotate(by: 20 * .pi / 180)
    }
    let ringRect = CGRect(x: -330, y: -120, width: 660, height: 240)

    // Back half of the ring (behind the planet).
    cg.saveGState()
    ringTransform(cg)
    cg.clip(to: CGRect(x: -400, y: 0, width: 800, height: 300))
    cg.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor)
    cg.setLineWidth(26)
    cg.strokeEllipse(in: ringRect)
    cg.restoreGState()

    // Planet
    let planet = CGRect(x: center.x - 165, y: center.y - 165, width: 330, height: 330)
    cg.saveGState()
    cg.setShadow(offset: .zero, blur: 60, color: NSColor(red: 0.75, green: 0.72, blue: 1, alpha: 0.6).cgColor)
    NSColor.white.setFill()
    NSBezierPath(ovalIn: planet).fill()
    cg.restoreGState()
    let planetGradient = NSGradient(colors: [
        NSColor(red: 1, green: 1, blue: 1, alpha: 1),
        NSColor(red: 0.84, green: 0.82, blue: 1, alpha: 1),
        NSColor(red: 0.58, green: 0.53, blue: 0.98, alpha: 1),
    ], atLocations: [0, 0.5, 1], colorSpace: .deviceRGB)!
    planetGradient.draw(in: NSBezierPath(ovalIn: planet), relativeCenterPosition: NSPoint(x: -0.35, y: 0.4))

    // Front half of the ring (over the planet).
    cg.saveGState()
    ringTransform(cg)
    cg.clip(to: CGRect(x: -400, y: -300, width: 800, height: 300))
    cg.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
    cg.setLineWidth(26)
    cg.strokeEllipse(in: ringRect)
    cg.restoreGState()

    // Satellite on the front of the ring.
    let angle: CGFloat = -0.5
    let local = CGPoint(x: 330 * cos(angle), y: 120 * sin(angle))
    let rotation = 20 * CGFloat.pi / 180
    let satellite = CGPoint(x: center.x + local.x * cos(rotation) - local.y * sin(rotation),
                            y: center.y + local.x * sin(rotation) + local.y * cos(rotation))
    cg.saveGState()
    cg.setShadow(offset: .zero, blur: 40, color: NSColor(red: 1, green: 0.75, blue: 0.2, alpha: 0.9).cgColor)
    let satelliteRect = CGRect(x: satellite.x - 58, y: satellite.y - 58, width: 116, height: 116)
    NSGradient(colors: [NSColor(red: 1, green: 0.9, blue: 0.5, alpha: 1), NSColor(red: 1, green: 0.62, blue: 0.1, alpha: 1)])!
        .draw(in: NSBezierPath(ovalIn: satelliteRect), relativeCenterPosition: NSPoint(x: -0.3, y: 0.3))
    cg.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [String] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try! render(size: pixels).write(to: iconset.appendingPathComponent(name))
        images.append("""
            { "filename" : "\(name)", "idiom" : "mac", "scale" : "\(scale)x", "size" : "\(points)x\(points)" }
        """)
    }
}
let contents = "{\n  \"images\" : [\n\(images.joined(separator: ",\n"))\n  ],\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\n}\n"
try! contents.write(to: iconset.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
try! render(size: 512).write(to: root.appendingPathComponent("docs/icon.png"))
print("Wrote \(iconset.path)")
