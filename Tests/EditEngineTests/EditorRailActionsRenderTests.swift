import AppKit
import SwiftUI
import XCTest
@testable import PhotoApp

/// Renders the REAL `EditorRailActions` group offscreen (7 icon-only entries, each 36 pt tall with 6 pt gaps from y = 0). Clicks and menus are
/// not driven (synthetic events do not reach this app) — see the manual checklist in PROGRESS.md.
@MainActor
final class EditorRailActionsRenderTests: XCTestCase {
    private let size = CGSize(width: EditorToolRailMetrics.width, height: 7 * 42)
    private let document = ImageDocumentModel()

    private func render(compare: CompareViewMode = .off, filmstrip: Bool = false, history: Bool = false,
                        canCompare: Bool = true, canEnhance: Bool = true) -> NSBitmapImageRep {
        let view = EditorRailActions(
            document: document, compareMode: .constant(compare), splitOrientation: .constant(.vertical),
            isHistoryPresented: .constant(history), isFilmstripVisible: .constant(filmstrip),
            canCompare: canCompare, canEnhance: canEnhance, onEnhance: {})
            .environment(\.colorScheme, .dark)
            .frame(width: size.width, height: size.height, alignment: .top)
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

    /// Pixels in entry `index` that differ between two renders (alpha included: dimming changes a pixel's alpha, not its colour).
    private func differing(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, entry index: Int) -> Int {
        let scale = CGFloat(a.pixelsWide) / size.width
        let top = CGFloat(index) * 42
        var n = 0
        for y in Int(top * scale)..<Int((top + 36) * scale) {
            for x in 0..<a.pixelsWide {
                guard let p = a.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), let q = b.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(p.redComponent - q.redComponent) + abs(p.greenComponent - q.greenComponent) + abs(p.blueComponent - q.blueComponent)
                    + abs(p.alphaComponent - q.alphaComponent) > 0.1 {
                    n += 1
                }
            }
        }
        return n
    }

    private func differingEntries(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> [Int] {
        (0..<7).filter { differing(a, b, entry: $0) > 20 }
    }

    // Entry order: 0 Undo, 1 Redo, 2 Revert, 3 History, 4 Compare, 5 Filmstrip, 6 Enhance.

    func testEnhanceAvailabilityRestylesOnlyTheEnhanceEntry() {
        XCTAssertEqual(differingEntries(render(canEnhance: true), render(canEnhance: false)), [6])
    }

    func testFilmstripOnStateRestylesOnlyTheFilmstripEntry() {
        XCTAssertEqual(differingEntries(render(filmstrip: false), render(filmstrip: true)), [5])
    }

    // The Compare entry is deliberately NOT pixel-tested: it is a native `Menu`, whose offscreen render is not stable (its active and
    // disabled looks showed identical pixels in some runs and a difference in others). Whether it is available is
    // `EditorRailActionRules.canCompare`'s tested rule; its look is on the manual checklist.

    func testHistoryOpenRestylesOnlyTheHistoryEntry() {
        // The History entry is disabled with no image, so "on" alone is the visible difference only if it still tints; compare on/off.
        XCTAssertEqual(differingEntries(render(history: false), render(history: true)), [3])
    }
}
