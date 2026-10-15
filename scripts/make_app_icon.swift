#!/usr/bin/env swift
// Draws the Lightbench app icon (a half-white / half-amber disc over a short bar, on a dark rounded square — geometry from the designer's
// lightbench-master-square.svg, 100-unit viewBox) and writes every size macOS needs into Sources/App/Assets.xcassets/AppIcon.appiconset.
// Usage: swift scripts/make_app_icon.swift [output-directory]   (default: the appiconset above)
import AppKit
import CoreGraphics

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let outDir = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : root.appendingPathComponent("Sources/App/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func render(pixels: Int) -> Data {
    let s = CGFloat(pixels)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    func color(_ hex: UInt32) -> CGColor {
        CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, 1])!
    }

    // macOS icon grid: the artwork fills ~82% of the canvas, corner radius ~22.5% of that.
    let inset = s * 0.09
    let tile = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = tile.width * 0.225
    let tilePath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Soft drop shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.45))
    ctx.addPath(tilePath); ctx.setFillColor(color(0x15171A)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    // SVG units (0...100, y down) -> tile points (y up).
    let u = tile.width / 100
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: tile.minX + x * u, y: tile.maxY - y * u) }
    let centre = pt(50, 44)
    let r = 24 * u
    // Left half warm white, right half amber (the two half-discs meet on the vertical diameter).
    ctx.setFillColor(color(0xF5F3EF))
    ctx.addArc(center: centre, radius: r, startAngle: .pi / 2, endAngle: -.pi / 2, clockwise: false)   // top -> bottom through the left
    ctx.closePath(); ctx.fillPath()
    ctx.setFillColor(color(0xFFC24D))
    ctx.addArc(center: centre, radius: r, startAngle: .pi / 2, endAngle: -.pi / 2, clockwise: true)    // top -> bottom through the right
    ctx.closePath(); ctx.fillPath()
    // The bar under the disc.
    let bar = CGRect(x: tile.minX + 28 * u, y: tile.maxY - 80 * u, width: 44 * u, height: 4 * u)
    ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 2 * u, cornerHeight: 2 * u, transform: nil))
    ctx.setFillColor(color(0xF5F3EF)); ctx.fillPath()
    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// (point size, scale) as macOS asks for them.
let entries: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
var images: [[String: String]] = []
for (size, scale) in entries {
    let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
    try render(pixels: size * scale).write(to: outDir.appendingPathComponent(name))
    images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(size)x\(size)"])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: outDir.appendingPathComponent("Contents.json"))
let catalogInfo = outDir.deletingLastPathComponent().appendingPathComponent("Contents.json")
if !FileManager.default.fileExists(atPath: catalogInfo.path) {
    try JSONSerialization.data(withJSONObject: ["info": ["author": "xcode", "version": 1]], options: [.prettyPrinted]).write(to: catalogInfo)
}
print("wrote \(entries.count) icons to \(outDir.path)")
