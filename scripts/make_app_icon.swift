#!/usr/bin/env swift
// Draws the PLACEHOLDER app icon (a lens ring over three adjustment sliders on a dark rounded square) and writes every size macOS needs into
// Sources/App/Assets.xcassets/AppIcon.appiconset. Replace the artwork whenever a real icon exists — just overwrite the PNGs (or delete the
// appiconset and drop a designer's one in); nothing else depends on this script.
// Usage: swift scripts/make_app_icon.swift
import AppKit
import CoreGraphics

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let outDir = root.appendingPathComponent("Sources/App/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func render(pixels: Int) -> Data {
    let s = CGFloat(pixels)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    // macOS icon grid: the artwork fills ~82% of the canvas, corner radius ~22.5% of that.
    let inset = s * 0.09
    let tile = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = tile.width * 0.225
    let tilePath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Soft drop shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.45))
    ctx.addPath(tilePath); ctx.setFillColor(CGColor(red: 0.1, green: 0.09, blue: 0.14, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()

    // Background gradient (the app's dark purple-grey).
    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 0.22, green: 0.18, blue: 0.33, alpha: 1), CGColor(red: 0.07, green: 0.06, blue: 0.11, alpha: 1)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: tile.midX, y: tile.maxY), end: CGPoint(x: tile.midX, y: tile.minY), options: [])

    // Lens ring.
    let center = CGPoint(x: tile.midX, y: tile.midY + tile.height * 0.13)
    let ringR = tile.width * 0.235
    ctx.setStrokeColor(CGColor(red: 0.96, green: 0.96, blue: 0.98, alpha: 1))
    ctx.setLineWidth(tile.width * 0.045)
    ctx.strokeEllipse(in: CGRect(x: center.x - ringR, y: center.y - ringR, width: ringR * 2, height: ringR * 2))
    // Inner glass: a gentle highlight.
    let glassR = ringR - tile.width * 0.03
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: center.x - glassR, y: center.y - glassR, width: glassR * 2, height: glassR * 2)); ctx.clip()
    let glass = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 0.45, green: 0.62, blue: 0.95, alpha: 0.55), CGColor(red: 0.18, green: 0.2, blue: 0.4, alpha: 0.15)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(glass, start: CGPoint(x: center.x - glassR, y: center.y + glassR), end: CGPoint(x: center.x + glassR, y: center.y - glassR), options: [])
    ctx.restoreGState()

    // Three adjustment sliders under the lens.
    let sliderW = tile.width * 0.56
    let x0 = tile.midX - sliderW / 2
    let ys = [tile.minY + tile.height * 0.27, tile.minY + tile.height * 0.19, tile.minY + tile.height * 0.11]
    let knobs: [CGFloat] = [0.68, 0.30, 0.52]
    for (y, k) in zip(ys, knobs) {
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.28)); ctx.setLineWidth(tile.width * 0.018); ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: x0, y: y)); ctx.addLine(to: CGPoint(x: x0 + sliderW, y: y)); ctx.strokePath()
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.85))
        ctx.move(to: CGPoint(x: x0, y: y)); ctx.addLine(to: CGPoint(x: x0 + sliderW * k, y: y)); ctx.strokePath()
        let kr = tile.width * 0.026
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: x0 + sliderW * k - kr, y: y - kr, width: kr * 2, height: kr * 2))
    }
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
