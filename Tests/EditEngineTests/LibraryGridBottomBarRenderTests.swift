import AppKit
import SwiftUI
import XCTest
@testable import PhotoApp

/// Renders the REAL `LibraryGridBottomBar` offscreen: its ideal width, its fixed height and its status slot.
@MainActor
final class LibraryGridBottomBarRenderTests: XCTestCase {
    private let suiteName = "LibraryGridBottomBarRenderTests-\(UUID().uuidString)"

    override func tearDown() async throws {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    private func makeCatalog() throws -> CatalogModel {
        CatalogModel(database: try CatalogDatabase(inMemory: true), defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
    }

    private struct Host: View {
        @ObservedObject var catalog: CatalogModel
        @State var layout = "square"
        @State var size = 160.0
        var body: some View {
            LibraryGridBottomBar(catalog: catalog, gridLayout: $layout, thumbnailSize: $size, sizeRange: 120...240)
        }
    }

    private func mount<V: View>(_ view: V, width: CGFloat) -> (NSHostingView<some View>, NSWindow) {
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, .dark).background(Theme.panel))
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 120)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.appearance = NSAppearance(named: .darkAqua)
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        return (hosting, window)
    }

    private func fittingSize(_ catalog: CatalogModel) -> CGSize {
        let (hosting, window) = mount(Host(catalog: catalog).fixedSize(), width: 1400)
        let size = hosting.fittingSize
        window.orderOut(nil)
        return size
    }

    private func render(_ catalog: CatalogModel, width: CGFloat = 900) -> NSBitmapImageRep? {
        let (hosting, window) = mount(Host(catalog: catalog).frame(width: width, height: Theme.Metrics.barHeight), width: width)
        defer { window.orderOut(nil) }
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep
    }

    func testTheControlsFitTheNarrowestGridPane() throws {
        let catalog = try makeCatalog()
        catalog.sortOption = .captureOldest
        let size = fittingSize(catalog)
        print("BOTTOM BAR fittingSize.width=\(size.width) height=\(size.height)")
        XCTAssertGreaterThan(size.width, 100)
        XCTAssertLessThanOrEqual(size.width, 560, "bottom bar ideal width \(size.width) pt")
    }

    func testTheHeightIsFixedWhateverTheStatusSays() throws {
        let idle = try makeCatalog()
        let long = try makeCatalog()
        long.searchText = "iso:" + String(repeating: "x", count: 200)
        let warning = try makeCatalog()
        warning.searchText = "iso:abc"
        for (name, catalog) in [("idle", idle), ("long warning", long), ("warning", warning)] {
            XCTAssertEqual(fittingSize(catalog).height, Theme.Metrics.barHeight, name)
        }
    }

    func testAnUnreadableTermShowsAmberTextOnTheLeftAndNoBlue() throws {
        let idle = try makeCatalog()
        let bad = try makeCatalog()
        bad.searchText = "iso:abc"
        let a = try XCTUnwrap(render(idle)), b = try XCTUnwrap(render(bad))
        XCTAssertEqual(a.pixelsWide, b.pixelsWide)
        let third = a.pixelsWide / 3
        var differing = 0, amber = 0, blue = 0
        for y in 0..<a.pixelsHigh {
            for x in 0..<third {
                guard let p = a.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), let q = b.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(p.redComponent - q.redComponent) + abs(p.greenComponent - q.greenComponent) + abs(p.blueComponent - q.blueComponent) > 0.1 {
                    differing += 1
                    if q.redComponent > q.blueComponent { amber += 1 }
                    if q.blueComponent - q.redComponent > 0.25 { blue += 1 }
                }
            }
        }
        XCTAssertGreaterThan(differing, 40, "the warning text appears in the left third")
        XCTAssertGreaterThan(amber, differing / 2, "the differing pixels are amber (red above blue)")
        XCTAssertEqual(blue, 0)
    }

    func testALongWarningTruncatesInsteadOfPushingTheControls() throws {
        let idle = try makeCatalog()
        let long = try makeCatalog()
        long.searchText = "iso:" + String(repeating: "x", count: 200)
        let a = try XCTUnwrap(render(idle, width: 560)), b = try XCTUnwrap(render(long, width: 560))
        XCTAssertEqual(a.pixelsWide, b.pixelsWide)
        // The controls are right-aligned after the status slot; the bar's ideal width is about 511 pt, so the right 400 pt hold
        // Sort, the layout buttons and the slider only (the status has at most the remaining ~49 pt).
        let scale = a.pixelsWide / 560
        var differing = 0
        for y in 0..<a.pixelsHigh {
            for x in (160 * scale)..<a.pixelsWide {
                guard let p = a.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), let q = b.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(p.redComponent - q.redComponent) + abs(p.greenComponent - q.greenComponent) + abs(p.blueComponent - q.blueComponent) > 0.1 { differing += 1 }
            }
        }
        XCTAssertEqual(differing, 0, "the controls region (right of x=160 pt) is identical with a long warning")
    }
}
