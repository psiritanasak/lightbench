import AppKit
import SwiftUI
import XCTest
@testable import PhotoApp

/// Renders the REAL Library sidebar offscreen: it must be the same SOLID dark panel as the Editor's Adjust panel (`Theme.panel`),
/// not the system's translucent `.sidebar` material. Clicks / selection are not driven (synthetic events do not reach this app).
@MainActor
final class CollectionSidebarRenderTests: XCTestCase {
    private let size = CGSize(width: 220, height: 320)

    private func render<V: View>(_ content: V, size: CGSize? = nil) -> NSBitmapImageRep {
        let size = size ?? self.size
        let view = content.environment(\.colorScheme, .dark).frame(width: size.width, height: size.height)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)!
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.orderOut(nil)
        return rep
    }

    private func pixel(_ rep: NSBitmapImageRep, _ point: CGPoint) throws -> NSColor {
        let scale = CGFloat(rep.pixelsWide) / size.width
        return try XCTUnwrap(rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(.sRGB))
    }

    /// Mutation-checked: removing the solid background / hidden scroll background fails this. NOT covered: `.listStyle(.plain)` vs
    /// `.sidebar` on its own — with the explicit solid background in place both render the same offscreen, so that choice is by
    /// code review (and the user's eye on the real window), not by this test.
    /// The expected colour is a plain `Theme.panel` rectangle rendered through the SAME offscreen pipeline (the pipeline shifts dark
    /// greys, so comparing against the raw token value would be wrong).
    func testTheSidebarBackgroundIsTheSolidPanelColour() throws {
        let defaults = UserDefaults(suiteName: "CollectionSidebarRenderTests-\(UUID().uuidString)")!
        let catalog = CatalogModel(database: try CatalogDatabase(inMemory: true), defaults: defaults)
        let sidebar = render(CollectionSidebarView(catalog: catalog))
        let reference = render(Theme.panel)
        // The empty area at the bottom of the (nearly empty) list: only the background can be there.
        for point in [CGPoint(x: 150, y: 300), CGPoint(x: 30, y: 260), CGPoint(x: 200, y: 200)] {
            let got = try pixel(sidebar, point), want = try pixel(reference, point)
            XCTAssertEqual(got.alphaComponent, 1, accuracy: 0.001, "opaque at \(point)")
            XCTAssertEqual(got.redComponent, want.redComponent, accuracy: 0.01, "red at \(point)")
            XCTAssertEqual(got.greenComponent, want.greenComponent, accuracy: 0.01, "green at \(point)")
            XCTAssertEqual(got.blueComponent, want.blueComponent, accuracy: 0.01, "blue at \(point)")
        }
    }

    func testThePanelTokenIsTheEditorsSidebarGrey() {
        let c = NSColor(Theme.panel).usingColorSpace(.deviceGray)
        XCTAssertEqual(c?.whiteComponent ?? -1, 0.11, accuracy: 0.001)
    }

    /// Thin full-width horizontal lines (row separators) in a render of the sidebar with a few collections. A selected row's highlight is a
    /// full-width band too, but ~20 pt tall, so only runs thinner than 3 pt count.
    private func separatorLineCount(_ rep: NSBitmapImageRep, size: CGSize) throws -> Int {
        let scale = CGFloat(rep.pixelsWide) / size.width
        let background = try XCTUnwrap(rep.colorAt(x: Int(150 * scale), y: Int((size.height - 10) * scale))?.usingColorSpace(.sRGB))
        var fullWidthRows: [Bool] = []
        for y in 0..<rep.pixelsHigh {
            var differing = 0
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(c.redComponent - background.redComponent) > 0.02 || c.alphaComponent < 0.99 { differing += 1 }
            }
            fullWidthRows.append(Double(differing) / Double(rep.pixelsWide) > 0.7)
        }
        var lines = 0, run = 0
        for isFull in fullWidthRows + [false] {
            if isFull { run += 1 } else {
                if run > 0, CGFloat(run) < 3 * scale { lines += 1 }
                run = 0
            }
        }
        return lines
    }

    func testThereIsNoSeparatorLineBetweenCollectionRows() async throws {
        let defaults = UserDefaults(suiteName: "CollectionSidebarRenderTests-\(UUID().uuidString)")!
        let database = try CatalogDatabase(inMemory: true)
        for name in ["test1", "test2", "test3"] { _ = try await database.createCollection(name: name) }
        // A "Folders" section too: three folder roots (the tree rows are a different kind of row from the plain collections).
        // f1 has a child, so it is drawn as a disclosure row (collapsed); f2 and f3 are plain roots.
        let kid = FolderScanNode(url: URL(fileURLWithPath: "/tmp/sidebar-test/f1/kid"), imageFiles: [], children: [])
        _ = try await database.importFolderTree(FolderScanNode(url: URL(fileURLWithPath: "/tmp/sidebar-test/f1"), imageFiles: [], children: [kid]))
        for name in ["f2", "f3"] {
            _ = try await database.importFolderTree(FolderScanNode(url: URL(fileURLWithPath: "/tmp/sidebar-test/\(name)"), imageFiles: [], children: []))
        }
        // And two smart collections.
        for name in ["smart1", "smart2"] { _ = try await database.createSmartCollection(name: name, criteria: SmartCollectionCriteria()) }
        let catalog = CatalogModel(database: database, defaults: defaults)
        await catalog.refresh()
        XCTAssertEqual(catalog.collections.filter { !$0.isFolder }.count, 3)
        XCTAssertEqual(catalog.collections.filter(\.isFolder).count, 4, "three folder roots + one child")
        XCTAssertEqual(catalog.smartCollections.count, 2)
        let tall = CGSize(width: 220, height: 460)
        let rep = render(CollectionSidebarView(catalog: catalog), size: tall)
        XCTAssertEqual(try separatorLineCount(rep, size: tall), 0, "no hairline between rows")
    }
}
