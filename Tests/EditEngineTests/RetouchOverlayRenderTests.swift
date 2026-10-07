import AppKit
import SwiftUI
import XCTest
@testable import PhotoApp

/// Renders the REAL Place Spots overlays offscreen and reads pixels back. The point is the coordinate flip (spot y runs UP, the view's
/// y runs DOWN — the classic bug here) and that the selected spot's radius handle sits where `RetouchOverlayGeometry` says. The
/// pointer gestures themselves are not exercised (synthetic mouse events do not reach this app).
@MainActor
final class RetouchOverlayRenderTests: XCTestCase {
    private let pane = CGSize(width: 400, height: 300)
    private let fit = CGRect(x: 50, y: 25, width: 300, height: 200)

    private func render<V: View>(_ view: V) -> NSBitmapImageRep {
        let hosting = NSHostingView(rootView: view.frame(width: pane.width, height: pane.height))
        hosting.frame = NSRect(origin: .zero, size: pane)
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

    /// Alpha at a view point (y down), independent of the backing scale.
    private func alpha(_ rep: NSBitmapImageRep, _ p: CGPoint) -> CGFloat {
        let scale = CGFloat(rep.pixelsWide) / pane.width
        return rep.colorAt(x: Int(p.x * scale), y: Int(p.y * scale))?.alphaComponent ?? -1
    }

    private func spot(x: Double, y: Double, radius: Double) -> RetouchSpot {
        var s = RetouchSpot(); s.x = x; s.y = y; s.radius = radius; return s
    }

    func testEverySpotIsDrawnWhereItsNormalizedPositionSaysWithYFlipped() {
        let a = spot(x: 0.25, y: 0.75, radius: 0.05), b = spot(x: 0.8, y: 0.2, radius: 0.05)
        let rep = render(RetouchSpotsOverlay(fitRect: fit, spots: [a, b], selectedID: nil, isArmed: false, defaultRadius: 0.015,
                                             onSelect: { _ in }, onPlace: { _, _, _ in }))
        for s in [a, b] {
            let c = RetouchOverlayGeometry.centerPoint(of: s, in: fit)
            let r = RetouchOverlayGeometry.radiusPoints(of: s, in: fit)
            XCTAssertGreaterThan(alpha(rep, CGPoint(x: c.x + r, y: c.y)), 0.3, "ring at the right edge of the circle")
            XCTAssertEqual(alpha(rep, c), 0, accuracy: 0.01, "the circle is an outline, its centre is empty")
        }
        // The flipped position (spot y treated as screen y-down) must be empty.
        let wrong = CGPoint(x: fit.minX + 0.25 * fit.width + 10, y: fit.minY + 0.75 * fit.height)
        XCTAssertEqual(alpha(rep, wrong), 0, accuracy: 0.01)
    }

    func testTheSelectedSpotIsLeftToTheHandlesOverlay() {
        let a = spot(x: 0.25, y: 0.75, radius: 0.05)
        let rep = render(RetouchSpotsOverlay(fitRect: fit, spots: [a], selectedID: a.id, isArmed: false, defaultRadius: 0.015,
                                             onSelect: { _ in }, onPlace: { _, _, _ in }))
        let c = RetouchOverlayGeometry.centerPoint(of: a, in: fit)
        XCTAssertEqual(alpha(rep, CGPoint(x: c.x + 10, y: c.y)), 0, accuracy: 0.01, "not drawn twice")
    }

    func testTheRadiusHandleSitsOnTheRightEdgeOfTheSelectedCircle() {
        var s = spot(x: 0.25, y: 0.75, radius: 0.05)
        let rep = render(RetouchOverlayView(fitRect: fit, spot: Binding(get: { s }, set: { s = $0 })))
        let c = RetouchOverlayGeometry.centerPoint(of: s, in: fit)
        let r = RetouchOverlayGeometry.radiusPoints(of: s, in: fit)
        // Three points out from the ring only the handle's 9 pt dot covers: opaque there, empty on the opposite side.
        XCTAssertGreaterThan(alpha(rep, CGPoint(x: c.x + r + 3, y: c.y)), 0.9, "handle dot at the right edge")
        XCTAssertEqual(alpha(rep, CGPoint(x: c.x - r - 3, y: c.y)), 0, accuracy: 0.01, "nothing on the left edge")
        XCTAssertEqual(alpha(rep, CGPoint(x: c.x, y: c.y - r - 3)), 0, accuracy: 0.01, "nothing at the top edge")
    }
}
