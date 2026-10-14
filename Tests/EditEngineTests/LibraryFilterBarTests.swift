import AppKit
import SwiftUI
import XCTest
@testable import PhotoApp

/// The Library filter bar: label swatches are real coloured, non-template images; the clear button shows only while a filter is active;
/// no blue anywhere. Menus themselves are AppKit-drawn (manual check), so the bar is rendered with its pop-ups closed.
@MainActor
final class LibraryFilterBarTests: XCTestCase {
    private let size = CGSize(width: 900, height: 44)

    private func render(_ catalog: CatalogModel, height: CGFloat? = nil) -> NSBitmapImageRep {
        let size = CGSize(width: self.size.width, height: height ?? self.size.height)
        let view = LibraryFilterBar(catalog: catalog).environment(\.colorScheme, .dark).environment(\.controlActiveState, .key)
            .frame(width: size.width, height: size.height, alignment: .top).background(Theme.panel)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.appearance = NSAppearance(named: .darkAqua)
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)!
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.orderOut(nil)
        return rep
    }

    private func makeCatalog() throws -> CatalogModel {
        let defaults = UserDefaults(suiteName: "LibraryFilterBarTests-\(UUID().uuidString)")!
        return CatalogModel(database: try CatalogDatabase(inMemory: true), defaults: defaults)
    }

    private func differing(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
        var n = 0
        for y in 0..<min(a.pixelsHigh, b.pixelsHigh) {
            for x in 0..<min(a.pixelsWide, b.pixelsWide) {
                guard let p = a.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), let q = b.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(p.redComponent - q.redComponent) + abs(p.greenComponent - q.greenComponent) + abs(p.blueComponent - q.blueComponent) > 0.1 { n += 1 }
            }
        }
        return n
    }

    // MARK: Swatches

    func testSwatchesAreColouredNonTemplateImagesForEveryRealLabel() throws {
        XCTAssertNil(LabelSwatch.image(for: .none))
        for label in ColorLabel.menuOrder where label != .none {
            let image = try XCTUnwrap(LabelSwatch.image(for: label), label.menuTitle)
            XCTAssertFalse(image.isTemplate, "a template image would be drawn monochrome in a menu")
            XCTAssertEqual(image.size.width, LabelSwatch.diameter)
            let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            let centre = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB))
            let want = try XCTUnwrap(NSColor(label.color).usingColorSpace(.sRGB))
            // System colours resolve a little differently per appearance, so compare the HUE (and that it is clearly saturated).
            XCTAssertGreaterThan(centre.saturationComponent, 0.4, label.menuTitle)
            var hueGap = abs(centre.hueComponent - want.hueComponent)
            hueGap = min(hueGap, 1 - hueGap)
            XCTAssertLessThan(hueGap, 0.05, label.menuTitle)
        }
    }

    func testEachColourFilterOptionMapsToItsLabelAndTheOthersHaveNone() {
        XCTAssertNil(LibraryLabelFilter.all.colorLabel)
        XCTAssertNil(LibraryLabelFilter.unlabeled.colorLabel)
        XCTAssertEqual(LibraryLabelFilter.red.colorLabel, .red)
        XCTAssertEqual(LibraryLabelFilter.yellow.colorLabel, .yellow)
        XCTAssertEqual(LibraryLabelFilter.green.colorLabel, .green)
        XCTAssertEqual(LibraryLabelFilter.blue.colorLabel, .blue)
        XCTAssertEqual(LibraryLabelFilter.purple.colorLabel, .purple)
    }

    // MARK: Search hint

    func testAnUnreadableSearchTermShowsAWarningHintAndTheIdleBarDoesNot() throws {
        let idle = try makeCatalog()
        let bad = try makeCatalog()
        bad.searchText = "iso:abc"
        // The hint has its own line UNDER the bar: render taller and compare only that strip (the search field's own text
        // differs between the two catalogs, so comparing the whole picture would pass even with no hint at all).
        let idleRep = render(idle, height: 70)
        let badRep = render(bad, height: 70)
        let scale = idleRep.pixelsWide / Int(size.width)
        func stripDifference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
            var n = 0
            for y in (50 * scale)..<a.pixelsHigh {
                for x in 0..<a.pixelsWide {
                    guard let p = a.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), let q = b.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    if abs(p.redComponent - q.redComponent) + abs(p.greenComponent - q.greenComponent) > 0.1 { n += 1 }
                }
            }
            return n
        }
        XCTAssertGreaterThan(stripDifference(idleRep, badRep), 40, "the warning text appears under the bar")
        XCTAssertEqual(stripDifference(idleRep, render(try makeCatalog(), height: 70)), 0, "an idle bar has nothing under it")
    }

    func testTheSavedQueryOfASelectedSmartCollectionAlsoShowsTheScanProgress() {
        let scanning = "Reading camera data… 5/10"
        XCTAssertNil(LibraryFilterBar.hint(forSearch: "", scanStatus: scanning, hasAnyMetadata: true), "no saved query")
        XCTAssertEqual(LibraryFilterBar.hint(forSearch: "", scanStatus: scanning, hasAnyMetadata: true, savedQuery: "iso:>800")?.text, scanning)
        XCTAssertNil(LibraryFilterBar.hint(forSearch: "", scanStatus: scanning, hasAnyMetadata: true, savedQuery: "sunset"),
                     "a saved query without camera terms is not nagged about the scan")
        XCTAssertEqual(LibraryFilterBar.hint(forSearch: "iso:abc", scanStatus: scanning, hasAnyMetadata: true, savedQuery: "iso:>800")?.isWarning, true)
    }

    func testHintRules() {
        let scanning = "Reading camera data… 5/10"
        let warn = LibraryFilterBar.hint(forSearch: "iso:abc", scanStatus: scanning, hasAnyMetadata: true)
        XCTAssertEqual(warn?.text, "Can't read \"iso:abc\"")
        XCTAssertEqual(warn?.isWarning, true, "an unreadable term wins over the scan status")
        XCTAssertNil(LibraryFilterBar.hint(forSearch: "iso:>800", scanStatus: nil, hasAnyMetadata: true), "readable and idle: no hint")
        XCTAssertEqual(LibraryFilterBar.hint(forSearch: "iso:>800", scanStatus: scanning, hasAnyMetadata: true)?.text, scanning,
                       "a camera-data query shows the scan progress")
        XCTAssertEqual(LibraryFilterBar.hint(forSearch: "iso:>800", scanStatus: scanning, hasAnyMetadata: true)?.isWarning, false)
        XCTAssertNil(LibraryFilterBar.hint(forSearch: "sunset rating:>3", scanStatus: scanning, hasAnyMetadata: true),
                     "a query that needs no camera data is not nagged about the scan")
        XCTAssertEqual(LibraryFilterBar.hint(forSearch: "", scanStatus: scanning, hasAnyMetadata: false)?.text, scanning,
                       "before any data exists the progress shows even with no query")
        XCTAssertNil(LibraryFilterBar.hint(forSearch: "", scanStatus: scanning, hasAnyMetadata: true))
    }

    // MARK: Active cue + clear button

    func testActiveFiltersChangeTheBarAndIdleDoesNotMatchIt() throws {
        let idle = try makeCatalog()
        let active = try makeCatalog()
        active.minimumRating = 3
        let idleRep = render(idle), activeRep = render(active)
        XCTAssertGreaterThan(differing(idleRep, activeRep), 150, "a chip and the clear button appear when a filter is on")
        // …and the cue is reversible: clearing returns to the idle picture.
        active.clearFiltersKeepingSort()
        XCTAssertEqual(differing(render(active), idleRep), 0, "cleared bar equals the idle bar")
    }

    func testSortAloneNeverShowsTheActiveCue() throws {
        let idle = try makeCatalog()
        let sorted = try makeCatalog()
        sorted.sortOption = .nameAZ
        // The Sort pop-up's own text changes, but no chip / clear button: compare only the area right of the sort pop-up.
        let a = render(idle), b = render(sorted)
        var n = 0
        let scale = a.pixelsWide / Int(size.width)
        for y in 0..<a.pixelsHigh {
            for x in (170 * scale)..<(700 * scale) {
                guard let p = a.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), let q = b.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(p.redComponent - q.redComponent) > 0.05 { n += 1 }
            }
        }
        XCTAssertEqual(n, 0, "no chip or clear button for a sort change")
    }

    func testTheBarHasNoBlue() throws {
        let c = try makeCatalog()
        c.minimumRating = 2; c.labelFilter = .red   // (a Blue label's swatch is meant to be blue)
        let rep = render(c)
        var blue = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                if let p = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), p.blueComponent - p.redComponent > 0.25 { blue += 1 }
            }
        }
        XCTAssertEqual(blue, 0)
    }

    // MARK: Search help popover

    func testTheSearchHelpHasASolidBackgroundNotATranslucentOne() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/UI/LibraryFilterBar.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "struct SearchHelpView: View {"))
        let body = String(source[start.upperBound...])
        XCTAssertTrue(body.contains(".background(Theme.panel)"), "the popover content must sit on a solid panel (readability over a busy grid)")
    }
}
