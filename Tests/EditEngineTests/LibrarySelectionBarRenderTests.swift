import AppKit
import SwiftUI
import XCTest
@testable import PhotoApp

/// Renders the REAL `LibrarySelectionBar` offscreen and measures its two rows. Clicks and menus are not driven.
@MainActor
final class LibrarySelectionBarRenderTests: XCTestCase {
    private let suiteName = "LibrarySelectionBarRenderTests-\(UUID().uuidString)"

    override func tearDown() async throws {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    private func makeCatalog() async throws -> CatalogModel {
        let db = try CatalogDatabase(inMemory: true)
        _ = try await db.importPhotos(at: (1...3).map { URL(fileURLWithPath: "/tmp/lsb/b\($0).jpg") })
        let model = CatalogModel(database: db, defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        await model.refresh()
        model.setSelection(Set(model.photos.compactMap(\.id)))
        return model
    }

    private func fittingWidth(_ layout: LibrarySelectionBar.Layout, catalog: CatalogModel) -> CGFloat {
        var context = PhotoActionContext()
        context.hasCollections = true
        let cells = catalog.gridPhotos
        let ids = PhotoActionTarget.ghostFreeSelection(catalog: catalog, cells: cells)
        let target = PhotoActionTarget.selection(catalog: catalog, cells: cells, selectedIDs: ids, openEditKey: nil)
        let bar = LibrarySelectionBar(collections: catalog.collections, context: context, target: target, perform: { _ in }, layout: layout)
        // `.fixedSize()` so `fittingSize` is each row's IDEAL width (the Spacer would otherwise take what it is offered).
        let hosting = NSHostingView(rootView: bar.fixedSize().environment(\.colorScheme, .dark))
        hosting.frame = NSRect(x: 0, y: 0, width: 1400, height: Theme.Metrics.barHeight)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let width = hosting.fittingSize.width
        window.orderOut(nil)
        return width
    }

    /// The grid pane at the 837 pt window minimum with the sidebar at its maximum is about 576 pt (arithmetic), so the compact row must
    /// fit 560 pt with the bar's own padding. Measured when written (offscreen NSHostingView, 3 photos selected, collections present):
    /// compact fittingSize.width 381 pt, full 809 pt.
    func testTheCompactRowFitsTheNarrowestGridPane() async throws {
        let catalog = try await makeCatalog()
        let compact = fittingWidth(.compact, catalog: catalog)
        let full = fittingWidth(.full, catalog: catalog)
        print("SELECTION BAR fittingSize.width compact=\(compact) full=\(full)")
        XCTAssertGreaterThan(compact, 100)
        XCTAssertLessThanOrEqual(compact, 560, "compact \(compact) pt, full \(full) pt")
        XCTAssertLessThan(compact, full, "the compact row is the narrower one (compact \(compact), full \(full))")
    }
}
