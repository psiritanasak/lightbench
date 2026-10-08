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

    /// `size` is the hosting view's size — larger than `pane` when a test needs to see pixels BEYOND the pane (the overlays clip themselves to
    /// `pane`, so anything drawn out there is a clipping failure).
    private func render<V: View>(_ view: V, size: CGSize? = nil) -> NSBitmapImageRep {
        let size = size ?? pane
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .topLeading))
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

    /// Alpha at a view point (y down), independent of the backing scale.
    private func alpha(_ rep: NSBitmapImageRep, _ p: CGPoint, width: CGFloat? = nil) -> CGFloat {
        let scale = CGFloat(rep.pixelsWide) / (width ?? pane.width)
        return rep.colorAt(x: Int(p.x * scale), y: Int(p.y * scale))?.alphaComponent ?? -1
    }

    private func spot(x: Double, y: Double, radius: Double) -> RetouchSpot {
        var s = RetouchSpot(); s.x = x; s.y = y; s.radius = radius; return s
    }

    func testEverySpotIsDrawnWhereItsNormalizedPositionSaysWithYFlipped() {
        let a = spot(x: 0.25, y: 0.75, radius: 0.05), b = spot(x: 0.8, y: 0.2, radius: 0.05)
        let rep = render(RetouchSpotsOverlay(fitRect: fit, paneSize: pane, spots: [a, b], selectedID: nil, isArmed: false, defaultRadius: 0.015,
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
        let rep = render(RetouchSpotsOverlay(fitRect: fit, paneSize: pane, spots: [a], selectedID: a.id, isArmed: false, defaultRadius: 0.015,
                                             onSelect: { _ in }, onPlace: { _, _, _ in }))
        let c = RetouchOverlayGeometry.centerPoint(of: a, in: fit)
        XCTAssertEqual(alpha(rep, CGPoint(x: c.x + 10, y: c.y)), 0, accuracy: 0.01, "not drawn twice")
    }

    func testTheRadiusHandleSitsOnTheRightEdgeOfTheSelectedCircle() {
        var s = spot(x: 0.25, y: 0.75, radius: 0.05)
        let rep = render(RetouchOverlayView(fitRect: fit, paneSize: pane, spot: Binding(get: { s }, set: { s = $0 })))
        let c = RetouchOverlayGeometry.centerPoint(of: s, in: fit)
        let r = RetouchOverlayGeometry.radiusPoints(of: s, in: fit)
        // Three points out from the ring only the handle's 9 pt dot covers: opaque there, empty on the opposite side.
        XCTAssertGreaterThan(alpha(rep, CGPoint(x: c.x + r + 3, y: c.y)), 0.9, "handle dot at the right edge")
        XCTAssertEqual(alpha(rep, CGPoint(x: c.x - r - 3, y: c.y)), 0, accuracy: 0.01, "nothing on the left edge")
        XCTAssertEqual(alpha(rep, CGPoint(x: c.x, y: c.y - r - 3)), 0, accuracy: 0.01, "nothing at the top edge")
    }

    // MARK: - Zoomed view

    func testUnderZoomTheRingsFollowTheZoomedPictureNotTheFitRect() {
        let s = spot(x: 0.5, y: 0.5, radius: 0.05)
        let zoomed = ZoomPanGeometry.displayedRect(fitRect: fit, zoom: 2, pan: CGSize(width: 0.1, height: -0.05))
        let rep = render(RetouchSpotsOverlay(fitRect: zoomed, paneSize: pane, spots: [s], selectedID: nil, isArmed: false, defaultRadius: 0.015,
                                             onSelect: { _ in }, onPlace: { _, _, _ in }))
        let c = RetouchOverlayGeometry.centerPoint(of: s, in: zoomed)
        let r = RetouchOverlayGeometry.radiusPoints(of: s, in: zoomed)
        XCTAssertEqual(r, 0.05 * 200 * 2, accuracy: 1e-9, "the circle grows with the zoom (its radius is a fraction of the picture)")
        XCTAssertGreaterThan(alpha(rep, CGPoint(x: c.x + r, y: c.y)), 0.3, "ring at the zoomed, panned position")
        let atFit = RetouchOverlayGeometry.centerPoint(of: s, in: fit)
        XCTAssertEqual(alpha(rep, CGPoint(x: atFit.x + 20, y: atFit.y)), 0, accuracy: 0.01, "nothing is left at the un-zoomed position")
    }

    func testRingsBeyondThePaneAreClipped() {
        let big = CGSize(width: 600, height: 400)
        let wide = CGRect(x: 50, y: 25, width: 800, height: 400)         // picture much wider than the 400 pt pane
        let inside = spot(x: 0.1, y: 0.8, radius: 0.05), outside = spot(x: 0.6, y: 0.8, radius: 0.05)
        let rep = render(RetouchSpotsOverlay(fitRect: wide, paneSize: pane, spots: [inside, outside], selectedID: nil, isArmed: false,
                                             defaultRadius: 0.015, onSelect: { _ in }, onPlace: { _, _, _ in }), size: big)
        let ci = RetouchOverlayGeometry.centerPoint(of: inside, in: wide), co = RetouchOverlayGeometry.centerPoint(of: outside, in: wide)
        XCTAssertLessThan(ci.x, pane.width); XCTAssertGreaterThan(co.x, pane.width, "premise: this spot sits beyond the pane's right edge")
        let ri = RetouchOverlayGeometry.radiusPoints(of: inside, in: wide), ro = RetouchOverlayGeometry.radiusPoints(of: outside, in: wide)
        XCTAssertGreaterThan(alpha(rep, CGPoint(x: ci.x + ri, y: ci.y), width: big.width), 0.3, "control: inside the pane it draws")
        XCTAssertEqual(alpha(rep, CGPoint(x: co.x + ro, y: co.y), width: big.width), 0, accuracy: 0.01, "beyond the pane it is clipped away")
    }

    func testTheSelectedHandlesAreClippedToThePaneToo() {
        let big = CGSize(width: 600, height: 400)
        let wide = CGRect(x: 50, y: 25, width: 800, height: 400)
        var s = spot(x: 0.6, y: 0.8, radius: 0.05)
        let rep = render(RetouchOverlayView(fitRect: wide, paneSize: pane, spot: Binding(get: { s }, set: { s = $0 })), size: big)
        let c = RetouchOverlayGeometry.centerPoint(of: s, in: wide), r = RetouchOverlayGeometry.radiusPoints(of: s, in: wide)
        XCTAssertGreaterThan(c.x, pane.width, "premise: the selected spot is beyond the pane")
        XCTAssertEqual(alpha(rep, CGPoint(x: c.x + r + 3, y: c.y), width: big.width), 0, accuracy: 0.01, "its handle must not draw out there")
    }
}

final class RetouchZoomedPressTests: XCTestCase {
    typealias G = RetouchOverlayGeometry
    private let pane = CGSize(width: 700, height: 450)
    private let fit = CGRect(x: 40, y: 25, width: 600, height: 400)

    func testAtFitSizeOnlyThePictureAcceptsPresses() {
        XCTAssertTrue(G.acceptsPress(at: CGPoint(x: 300, y: 200), pictureRect: fit, paneSize: pane))
        XCTAssertFalse(G.acceptsPress(at: CGPoint(x: 10, y: 200), pictureRect: fit, paneSize: pane), "the letterbox is not the picture")
        XCTAssertFalse(G.acceptsPress(at: CGPoint(x: 300, y: 10), pictureRect: fit, paneSize: pane))
    }

    func testZoomedTheWholePaneIsPictureButNothingOutsideIt() {
        let zoomed = ZoomPanGeometry.displayedRect(fitRect: fit, zoom: 2, pan: .zero)
        XCTAssertTrue(G.acceptsPress(at: CGPoint(x: 10, y: 10), pictureRect: zoomed, paneSize: pane), "zoomed, the picture fills the letterbox")
        XCTAssertTrue(G.acceptsPress(at: CGPoint(x: 690, y: 440), pictureRect: zoomed, paneSize: pane))
        XCTAssertFalse(G.acceptsPress(at: CGPoint(x: 710, y: 100), pictureRect: zoomed, paneSize: pane), "outside the pane")
        XCTAssertFalse(G.acceptsPress(at: CGPoint(x: -1, y: 100), pictureRect: zoomed, paneSize: pane))
    }

    func testAPanThatLeavesGapsOnlyAcceptsWherePictureIs() {
        // Picture panned so its left edge is inside the pane: the strip to its left is not picture.
        let moved = CGRect(x: 200, y: 25, width: 1200, height: 800)
        XCTAssertFalse(G.acceptsPress(at: CGPoint(x: 100, y: 200), pictureRect: moved, paneSize: pane))
        XCTAssertTrue(G.acceptsPress(at: CGPoint(x: 300, y: 200), pictureRect: moved, paneSize: pane))
    }

    func testBadInputIsRejected() {
        XCTAssertFalse(G.acceptsPress(at: CGPoint(x: CGFloat.nan, y: 5), pictureRect: fit, paneSize: pane))
        XCTAssertFalse(G.acceptsPress(at: CGPoint(x: 300, y: 200), pictureRect: fit, paneSize: .zero))
        XCTAssertFalse(G.acceptsPress(at: CGPoint(x: 300, y: 200), pictureRect: CGRect(x: 5000, y: 0, width: 10, height: 10), paneSize: pane))
    }

    func testAPlacementIsDroppedWhenTheViewMovedDuringThePress() {
        let a = fit, b = ZoomPanGeometry.displayedRect(fitRect: fit, zoom: 2, pan: .zero)
        XCTAssertTrue(G.isPlacementStillValid(pressRect: a, currentRect: a))
        XCTAssertFalse(G.isPlacementStillValid(pressRect: a, currentRect: b), "scroll-zoom mid-press")
        XCTAssertFalse(G.isPlacementStillValid(pressRect: a, currentRect: a.offsetBy(dx: 3, dy: 0)), "a pan mid-press")
        XCTAssertTrue(G.isPlacementStillValid(pressRect: nil, currentRect: a), "no change event seen: nothing is known to have moved — a plain click must not be dropped")
    }

    func testThePressRecordIsKeyedToTheStartPointSoMovingBackCannotHideAZoom() {
        let start = CGPoint(x: 100, y: 100)
        let a = fit, b = ZoomPanGeometry.displayedRect(fitRect: fit, zoom: 2, pan: .zero)
        let first = G.recordPress(nil, startLocation: start, currentRect: a)
        XCTAssertEqual(first, G.PressRecord(start: start, rect: a))
        // The view zooms mid-press, then the pointer comes back to exactly the start point: the ORIGINAL rect is kept.
        let again = G.recordPress(first, startLocation: start, currentRect: b)
        XCTAssertEqual(again.rect, a)
        XCTAssertFalse(G.isPlacementStillValid(pressRect: again.rect, currentRect: b))
        // A different press (different start point) replaces a stale record from a cancelled gesture.
        let next = G.recordPress(first, startLocation: CGPoint(x: 300, y: 50), currentRect: b)
        XCTAssertEqual(next, G.PressRecord(start: CGPoint(x: 300, y: 50), rect: b))
    }

    func testHandlesOffThePaneDoNotTakePresses() {
        XCTAssertTrue(G.isInsidePane(CGPoint(x: 10, y: 10), paneSize: pane))
        XCTAssertTrue(G.isInsidePane(CGPoint(x: 699, y: 449), paneSize: pane))
        XCTAssertFalse(G.isInsidePane(CGPoint(x: 701, y: 10), paneSize: pane))
        XCTAssertFalse(G.isInsidePane(CGPoint(x: -1, y: 10), paneSize: pane))
        XCTAssertFalse(G.isInsidePane(CGPoint(x: CGFloat.nan, y: 10), paneSize: pane))
        XCTAssertFalse(G.isInsidePane(CGPoint(x: 10, y: 10), paneSize: .zero))
    }
}
