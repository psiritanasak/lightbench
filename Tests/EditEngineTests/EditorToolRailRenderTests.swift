import AppKit
import SwiftUI
import XCTest
@testable import PhotoApp

/// Renders the REAL `EditorToolRail` offscreen: the selected entry is the one that gets the accent tint. Clicks are not driven
/// (synthetic events do not reach this app) — see the manual checklist in PROGRESS.md.
@MainActor
final class EditorToolRailRenderTests: XCTestCase {
    private let size = CGSize(width: EditorToolRailMetrics.width, height: 300)

    private func render(selected: EditorTab) -> NSBitmapImageRep {
        let view = EditorToolRail(selectedTab: .constant(selected)).environment(\.colorScheme, .dark)
            .frame(width: size.width, height: size.height)
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

    /// How many pixels in one entry's rows differ between two renders (independent of the system accent colour).
    private func differingPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, entry: Int) -> Int {
        let scale = CGFloat(a.pixelsWide) / size.width
        let top = 8 + CGFloat(entry) * 54
        var n = 0
        for y in Int(top * scale)..<Int((top + 48) * scale) {
            for x in 0..<a.pixelsWide {
                guard let p = a.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      let q = b.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(p.redComponent - q.redComponent) + abs(p.greenComponent - q.greenComponent)
                    + abs(p.blueComponent - q.blueComponent) > 0.1 { n += 1 }
            }
        }
        return n
    }

    /// Selecting a tab restyles ITS entry only: renders with different selections differ in exactly the two entries involved.
    func testSelectionRestylesOnlyTheEntriesInvolved() {
        let tabs = EditorTab.railTabs
        let first = render(selected: tabs[0]), second = render(selected: tabs[1])
        XCTAssertGreaterThan(differingPixels(first, second, entry: 0), 20, "entry 0 changes when it is (de)selected")
        XCTAssertGreaterThan(differingPixels(first, second, entry: 1), 20, "entry 1 changes when it is (de)selected")
        XCTAssertEqual(differingPixels(first, second, entry: 2), 0, "an uninvolved entry must not change")
    }

    func testRailHasItsFixedWidth() {
        XCTAssertEqual(EditorToolRailMetrics.width, 56)
    }
}
