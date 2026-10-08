import AppKit
import SwiftUI
import XCTest
@testable import PhotoApp

/// Renders the REAL Library sidebar offscreen: it must be the same SOLID dark panel as the Editor's Adjust panel (`Theme.panel`),
/// not the system's translucent `.sidebar` material. Clicks / selection are not driven (synthetic events do not reach this app).
@MainActor
final class CollectionSidebarRenderTests: XCTestCase {
    private let size = CGSize(width: 220, height: 320)

    private func render<V: View>(_ content: V) -> NSBitmapImageRep {
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
}
