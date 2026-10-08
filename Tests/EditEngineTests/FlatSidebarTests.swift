import AppKit
import SwiftUI
import XCTest
@testable import PhotoApp

/// Step 4 of the minimal look: a quieter section header (no icon), a slider without the glossy white fill / thumb shadow, a flat style
/// pad. Offscreen renders; dark greys are compared against plain rectangles through the same pipeline.
@MainActor
final class FlatSidebarTests: XCTestCase {
    private func render<V: View>(_ content: V, size: CGSize) -> NSBitmapImageRep {
        let view = content.environment(\.colorScheme, .dark).frame(width: size.width, height: size.height)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)!
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.orderOut(nil)
        return rep
    }

    private func pixel(_ rep: NSBitmapImageRep, _ x: CGFloat, _ y: CGFloat, width: CGFloat) throws -> NSColor {
        let scale = CGFloat(rep.pixelsWide) / width
        return try XCTUnwrap(rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB))
    }

    // MARK: Slider

    private func sliderRender() -> (rep: NSBitmapImageRep, size: CGSize, thumbX: CGFloat) {
        let size = CGSize(width: 200, height: 22)
        let rep = render(ThinSlider(value: .constant(0.5), range: 0...1), size: size)
        let thumbX = ThinSliderGeometry.thumbCenterX(fraction: 0.5, trackWidth: 200, thumbWidth: 5)
        return (rep, size, CGFloat(thumbX))
    }

    func testTheFilledTrackIsDimmerThanTheThumb() throws {
        let (rep, size, thumbX) = sliderRender()
        let filled = try pixel(rep, thumbX / 2, 11, width: size.width)      // on the filled part of the track
        let thumb = try pixel(rep, thumbX, 3, width: size.width)            // thumb above/below the 4 pt track
        XCTAssertGreaterThan(thumb.alphaComponent, 0.95, "thumb is solid")
        XCTAssertGreaterThan(thumb.redComponent, 0.95, "thumb is white")
        XCTAssertGreaterThan(filled.alphaComponent, 0.4, "the filled track is drawn")
        XCTAssertLessThan(filled.alphaComponent, 0.75, "...but not solid white like the thumb")
    }

    func testTheThumbHasNoShadow() throws {
        let (rep, size, thumbX) = sliderRender()
        // Just outside the 5 pt thumb, above the track: nothing may be drawn (a shadow would put dark pixels here).
        for dx in [-4.0, 4.0] as [CGFloat] {
            let c = try pixel(rep, thumbX + dx, 3, width: size.width)
            XCTAssertEqual(c.alphaComponent, 0, accuracy: 0.01, "no shadow beside the thumb (dx \(dx))")
        }
    }

    // MARK: Style pad

    func testTheStylePadIsAFlatRaisedFillNotAGradient() throws {
        let side: CGFloat = 190
        let size = CGSize(width: side, height: side)
        let pad = StylePadView(tone: .constant(0), color: .constant(0))
        let rep = render(pad, size: size)
        let reference = render(Theme.raised, size: size)
        // Two interior points far apart vertically, away from the cross lines and the edge labels.
        let top = try pixel(rep, 40, 40, width: side), bottom = try pixel(rep, 40, 150, width: side)
        let want = try pixel(reference, 40, 40, width: side)
        for c in [top, bottom] {
            XCTAssertEqual(c.alphaComponent, 1, accuracy: 0.001)
            XCTAssertEqual(c.redComponent, want.redComponent, accuracy: 0.015, "flat: both match the raised grey")
        }
    }

    // MARK: Section header

    /// Rightmost bright (text / chevron) pixel of a collapsed section header, in points.
    private func headerRightEdge(_ container: some View) -> CGFloat {
        let size = CGSize(width: 300, height: 40)
        let rep = render(container, size: size)
        let scale = CGFloat(rep.pixelsWide) / size.width
        var maxX: CGFloat = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.5, c.redComponent > 0.8 {
                    maxX = max(maxX, CGFloat(x) / scale)
                }
            }
        }
        return maxX
    }

    /// The header is the title next to the chevron — no 17 pt icon and no larger headline font — so its content ends well to the left of
    /// where the old icon + headline header ended. Calibrated against the real icon header (the mutant that puts it back).
    func testTheSectionHeaderIsJustATitleNextToTheChevron() throws {
        let quiet = headerRightEdge(AdjustSectionContainer(title: "Light", isExpanded: .constant(false)) { Text("body") })
        XCTAssertGreaterThan(quiet, 20, "the header drew something (chevron + title): \(quiet)")
        XCTAssertLessThan(quiet, FlatSidebarTests.maxQuietHeaderRightEdge, "no icon / headline font: right edge \(quiet)")
    }

    /// Guards the calibration above: the OLD style (icon + headline) really does end further right than the limit.
    func testTheOldIconHeaderWouldHaveEndedBeyondTheLimit() throws {
        let old = headerRightEdge(DisclosureGroup(isExpanded: .constant(false)) { Text("body") } label: {
            Label("Light", systemImage: "sun.max").font(.headline)
        })
        XCTAssertGreaterThan(old, FlatSidebarTests.maxQuietHeaderRightEdge, "old header right edge \(old)")
    }

    static let maxQuietHeaderRightEdge: CGFloat = 55
}
