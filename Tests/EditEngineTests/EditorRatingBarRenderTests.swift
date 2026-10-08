import AppKit
import SwiftUI
import XCTest
@testable import PhotoApp

/// Renders the REAL `EditorRatingBar` offscreen: the bar shows the open photo's rating / flag / label and is inert without a catalog
/// row. Clicks and keys are not driven (synthetic events do not reach this app) — see the manual checklist in PROGRESS.md.
@MainActor
final class EditorRatingBarRenderTests: XCTestCase {
    private let size = CGSize(width: 600, height: 36)

    private func render(_ meta: EditorPhotoMeta) -> NSBitmapImageRep {
        let view = EditorRatingBar(meta: meta, canCopy: true, onCopy: {}).frame(width: size.width, height: size.height)
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
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

    private func meta(rating: Int = 0, flag: FlagStatus = .none, label: ColorLabel = .none, resolved: Bool = true) async -> EditorPhotoMeta {
        let row = Photo(id: 1, path: "/a.jpg", filename: "a", fileSize: nil, importedAt: Date(timeIntervalSince1970: 0),
                        rating: rating, flagStatus: flag, colorLabel: label)
        let m = EditorPhotoMeta(resolve: { _ in resolved ? row : nil })
        await m.sync(path: "/a.jpg", isLoading: false)?.value
        return m
    }

    /// Pixels matching `predicate` (r, g, b in 0...1) among opaque pixels.
    private func count(_ rep: NSBitmapImageRep, _ predicate: (CGFloat, CGFloat, CGFloat) -> Bool) -> Int {
        var n = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.5 else { continue }
                if predicate(c.redComponent, c.greenComponent, c.blueComponent) { n += 1 }
            }
        }
        return n
    }

    private func isYellow(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Bool { r > 0.85 && g > 0.7 && b < 0.35 }
    private func isRed(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Bool { r > 0.9 && g < 0.5 && b < 0.45 && r - g > 0.4 }
    private func isWhite(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Bool { r > 0.8 && g > 0.8 && b > 0.8 }

    func testMoreStarsFillMoreYellow() async {
        let none = count(render(await meta(rating: 0)), isYellow)
        let three = count(render(await meta(rating: 3)), isYellow)
        let five = count(render(await meta(rating: 5)), isYellow)
        XCTAssertGreaterThan(three, none)
        XCTAssertGreaterThan(five, three)
    }

    func testRejectedAndLabelShowRed() async {
        let plain = count(render(await meta()), isRed)
        let rejected = count(render(await meta(flag: .rejected)), isRed)
        XCTAssertGreaterThan(rejected, plain, "the Reject icon turns red when set")
        // The photo's own label dot gets a bright ring; the others keep a faint one.
        let ringPlain = count(render(await meta()), isWhite)
        let ringLabelled = count(render(await meta(label: .red)), isWhite)
        XCTAssertGreaterThan(ringLabelled, ringPlain, "the selected label dot is ringed")
    }

    /// The lookup finding nothing leaves no row (the bar then draws its empty, disabled state — the render of that state is
    /// `testMoreStarsFillMoreYellow`'s zero-rating case plus the hint text).
    func testNoCatalogRowLeavesNoPhoto() async {
        let m = await meta(rating: 4, resolved: false)
        XCTAssertNil(m.photo)
    }
}
