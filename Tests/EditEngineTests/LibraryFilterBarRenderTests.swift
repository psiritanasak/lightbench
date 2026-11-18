import AppKit
import SwiftUI
import XCTest
@testable import PhotoApp

/// Renders the REAL `LibraryFilterBar` offscreen: ties `LibraryFilterBarLayout` to the view, and checks the two rows.
@MainActor
final class LibraryFilterBarRenderTests: XCTestCase {
    private typealias L = LibraryFilterBarLayout
    private let suiteName = "LibraryFilterBarRenderTests-\(UUID().uuidString)"

    override func tearDown() async throws {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    private func makeCatalog() async throws -> CatalogModel {
        let db = try CatalogDatabase(inMemory: true)
        _ = try await db.importPhotos(at: (1...3).map { URL(fileURLWithPath: "/tmp/lfb/b\($0).jpg") })
        let model = CatalogModel(database: db, defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        await model.refresh()
        return model
    }

    private func host<V: View>(_ view: V, width: CGFloat, height: CGFloat = 80) -> (NSHostingView<AnyView>, NSWindow) {
        let hosting = NSHostingView(rootView: AnyView(view.environment(\.colorScheme, .dark).environment(\.controlActiveState, .key)))
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.appearance = NSAppearance(named: .darkAqua)
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        return (hosting, window)
    }

    /// The row's IDEAL size (`.fixedSize()`, so a Spacer takes nothing extra).
    private func fitting(_ layout: LibraryFilterBar.Layout, catalog: CatalogModel) -> CGSize {
        let (hosting, window) = host(LibraryFilterBar(catalog: catalog, layout: layout).fixedSize(), width: 1400)
        let size = hosting.fittingSize
        window.orderOut(nil)
        return size
    }

    private func render(_ layout: LibraryFilterBar.Layout, catalog: CatalogModel, width: CGFloat) -> NSBitmapImageRep {
        let view = LibraryFilterBar(catalog: catalog, layout: layout)
            .frame(width: width, height: Theme.Metrics.barHeight, alignment: .top).background(Theme.panel)
        let (hosting, window) = host(view, width: width, height: Theme.Metrics.barHeight)
        defer { window.orderOut(nil) }
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return NSBitmapImageRep() }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep
    }

    private func differing(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return Int.max }
        var n = 0
        for y in 0..<a.pixelsHigh {
            for x in 0..<a.pixelsWide {
                guard let p = a.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), let q = b.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(p.redComponent - q.redComponent) + abs(p.greenComponent - q.greenComponent) + abs(p.blueComponent - q.blueComponent) > 0.1 { n += 1 }
            }
        }
        return n
    }

    // MARK: Tests

    func testTheFullRowsIdealWidthIsTheLayoutFunction() async throws {
        let catalog = try await makeCatalog()
        let width = fitting(.full, catalog: catalog).width
        print("FILTER BAR full fittingSize.width=\(width) expected=\(L.fullRowWidth(showsPeople: false))")
        XCTAssertEqual(width, L.fullRowWidth(showsPeople: false), accuracy: 0.5)
    }

    func testTheFullRowWithPeopleMatchesTheLayoutFunction() async throws {
        let catalog = try await makeCatalog()
        _ = try await catalog.database?.createPerson(name: "Ann")
        await catalog.refresh()
        XCTAssertFalse(catalog.people.isEmpty, "a created person shows in the bar's list")
        let width = fitting(.full, catalog: catalog).width
        print("FILTER BAR full+people fittingSize.width=\(width) expected=\(L.fullRowWidth(showsPeople: true))")
        XCTAssertEqual(width, L.fullRowWidth(showsPeople: true), accuracy: 0.5)
    }

    func testTheCollapsedRowFitsTheNarrowestGridPaneWithFiveFiltersActive() async throws {
        let catalog = try await makeCatalog()
        catalog.minimumRating = 3; catalog.flagFilter = .picked; catalog.labelFilter = .red
        catalog.keywordFilterID = 1; catalog.personFilterID = 1
        XCTAssertEqual(catalog.libraryFilterState.menuFilterCount, 5)
        let collapsed = fitting(.collapsed, catalog: catalog).width
        let full = fitting(.full, catalog: catalog).width
        print("FILTER BAR fittingSize.width collapsed=\(collapsed) full=\(full)")
        XCTAssertGreaterThan(collapsed, 100)
        XCTAssertLessThanOrEqual(collapsed, 560, "collapsed \(collapsed) pt, full \(full) pt")
        XCTAssertLessThan(collapsed, full)
    }

    func testAdaptiveIsTheFullRowAboveTheThresholdAndTheCollapsedRowBelowIt() async throws {
        let catalog = try await makeCatalog()
        let threshold = L.fullRowWidth(showsPeople: false)
        for rating in [0, 3] {
            catalog.minimumRating = rating
            let above = threshold + 8, below = threshold - 8
            XCTAssertEqual(differing(render(.adaptive, catalog: catalog, width: above), render(.full, catalog: catalog, width: above)), 0,
                           "above the threshold (rating \(rating))")
            XCTAssertEqual(differing(render(.adaptive, catalog: catalog, width: below), render(.collapsed, catalog: catalog, width: below)), 0,
                           "below the threshold (rating \(rating))")
        }
        XCTAssertGreaterThan(differing(render(.full, catalog: catalog, width: threshold + 8), render(.collapsed, catalog: catalog, width: threshold + 8)), 100,
                             "the two rows really look different")
    }

    func testTheBarHeightNeverChanges() async throws {
        let idle = try await makeCatalog()
        let warning = try await makeCatalog()
        warning.searchText = "iso:abc"
        let active = try await makeCatalog()
        active.minimumRating = 3; active.labelFilter = .red
        for catalog in [idle, warning, active] {
            for layout in [LibraryFilterBar.Layout.adaptive, .full, .collapsed] {
                XCTAssertEqual(fitting(layout, catalog: catalog).height, Theme.Metrics.barHeight, "\(layout)")
            }
        }
    }

    func testTheFiltersChipChangesWithAFilterAndReturnsAfterClear() async throws {
        let catalog = try await makeCatalog()
        let width: CGFloat = 520
        let idle = render(.collapsed, catalog: catalog, width: width)
        catalog.minimumRating = 3
        XCTAssertGreaterThan(differing(idle, render(.collapsed, catalog: catalog, width: width)), 100)
        catalog.clearFiltersKeepingSort()
        XCTAssertEqual(differing(idle, render(.collapsed, catalog: catalog, width: width)), 0)
    }

    func testNeitherRowHasBlue() async throws {
        let catalog = try await makeCatalog()
        catalog.minimumRating = 2; catalog.labelFilter = .red
        for layout in [LibraryFilterBar.Layout.full, .collapsed] {
            let rep = render(layout, catalog: catalog, width: 1100)
            var blue = 0
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    if let p = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), p.blueComponent - p.redComponent > 0.25 { blue += 1 }
                }
            }
            XCTAssertEqual(blue, 0, "\(layout)")
        }
    }
}
