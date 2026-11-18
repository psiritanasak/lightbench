import AppKit
import SwiftUI
import XCTest
@testable import PhotoApp

@MainActor
final class EditorHistogramHeaderRenderTests: XCTestCase {
    private func render(_ info: PhotoMetadataReader.Fields?, data: HistogramData, mode: HistogramDisplayMode = .luminance) -> (NSBitmapImageRep, CGFloat) {
        let size = CGSize(width: 360, height: 300)
        let view = EditorHistogramHeader(data: data, mode: .constant(mode), cameraInfo: info)
            .environment(\.colorScheme, .dark).frame(width: size.width, alignment: .top).background(Theme.panel)
        let hosting = NSHostingView(rootView: view)
        let fitting = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: CGSize(width: size.width, height: max(fitting.height, 1)))
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)!
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.orderOut(nil)
        return (rep, fitting.height)
    }

    private func lit(_ rep: NSBitmapImageRep, points: Range<Int>, height: CGFloat) -> Int {
        let scale = CGFloat(rep.pixelsHigh) / height
        let rows = Int(CGFloat(points.lowerBound) * scale)..<Int(CGFloat(points.upperBound) * scale)
        var n = 0
        for y in rows where y < rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.redComponent > 0.3 { n += 1 }
            }
        }
        return n
    }

    func testHeaderDrawsTheHistogramAndTheExifTextWithinTheHeightBudget() {
        var info = PhotoMetadataReader.Fields()
        info.iso = 800; info.aperture = 2.8; info.shutter = 0.004; info.focalLength = 50
        info.cameraMake = "NIKON CORPORATION"; info.cameraModel = "NIKON D610"
        let data = HistogramData(luminance: Array(repeating: 0.8, count: 256), red: [], green: [], blue: [])
        let (withInfo, height) = render(info, data: data)
        let (without, shortHeight) = render(nil, data: data)
        XCTAssertLessThanOrEqual(height, 112, "stays inside the ~100-110 pt budget")
        XCTAssertGreaterThan(height, shortHeight + 10, "the text lines add height")
        // The histogram sits in the top ~68 pt; the strip text lives below it.
        XCTAssertGreaterThan(lit(withInfo, points: 10..<66, height: height), 500, "histogram is drawn")
        XCTAssertGreaterThan(lit(withInfo, points: 72..<Int(height), height: height), 50, "EXIF text is drawn")
        XCTAssertLessThan(lit(without, points: 70..<Int(shortHeight), height: shortHeight), 20, "no info: no text below the histogram")
    }

    private func redDominant(_ rep: NSBitmapImageRep, points: Range<Int>, height: CGFloat) -> Int {
        let scale = CGFloat(rep.pixelsHigh) / height
        let rows = Int(CGFloat(points.lowerBound) * scale)..<Int(CGFloat(points.upperBound) * scale)
        var n = 0
        for y in rows where y < rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.redComponent > c.greenComponent + 0.25 { n += 1 }
            }
        }
        return n
    }

    func testRGBModeDrawsColourAndLuminanceDoesNot() {
        // Only the red series has data: RGB mode overlays it in red, Luminance mode draws just the (grey) luminance series.
        let data = HistogramData(luminance: Array(repeating: 0.3, count: 256), red: Array(repeating: 0.8, count: 256), green: [], blue: [])
        let (rgb, rgbHeight) = render(nil, data: data, mode: .rgb)
        let (lum, lumHeight) = render(nil, data: data, mode: .luminance)
        let rgbCount = redDominant(rgb, points: 10..<66, height: rgbHeight)
        let lumCount = redDominant(lum, points: 10..<66, height: lumHeight)
        // The thresholds (RGB > 300, Luminance < 20) were calibrated on the first run of this test; the counts measured then were
        // RGB = 40874 and Luminance = 0 red-dominant pixels in rows 10..<66.
        XCTAssertGreaterThan(rgbCount, 300, "RGB mode draws the red series")
        XCTAssertLessThan(lumCount, 20, "Luminance mode draws no colour")
    }
}
