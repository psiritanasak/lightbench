import AppKit
import SwiftUI
import XCTest
@testable import PhotoApp

/// The system focus effect is off on `ThinSlider`, so a keyboard-focused knob must show its own outline. Real focus cannot be driven
/// offscreen, so the knob view is rendered with `isFocused` both ways.
@MainActor
final class ThinSliderFocusRenderTests: XCTestCase {
    private let size = CGSize(width: 40, height: 40)

    private func render(isFocused: Bool) -> NSBitmapImageRep {
        let view = ThinSliderThumb(width: 5, height: 18, isFocused: isFocused).frame(width: size.width, height: size.height)
            .background(Color.black).environment(\.colorScheme, .dark)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)!
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.orderOut(nil)
        return rep
    }

    /// Lit pixels at least 4 pt away (horizontally) from the knob's centre column: the knob itself is 5 pt wide, so anything there is ring.
    private func ringPixels(_ rep: NSBitmapImageRep) -> Int {
        let scale = rep.pixelsWide / Int(size.width)
        var n = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where abs(Double(x) / Double(scale) - 20) >= 4 {
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.redComponent > 0.25 { n += 1 }
            }
        }
        return n
    }

    func testAFocusedKnobDrawsAnOutlineAndAnUnfocusedOneDoesNot() {
        XCTAssertEqual(ringPixels(render(isFocused: false)), 0, "no ring unfocused")
        XCTAssertGreaterThan(ringPixels(render(isFocused: true)), 20, "a ring around the focused knob")
    }
}
