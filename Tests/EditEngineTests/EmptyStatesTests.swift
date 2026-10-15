import AppKit
import SwiftUI
import XCTest
@testable import PhotoApp

final class LibraryEmptyKindTests: XCTestCase {
    func testPhotosShownMeansNoEmptyStateWhateverElseIsTrue() {
        for loaded in [false, true] {
            for collection in [false, true] {
                XCTAssertEqual(LibraryEmptyKind.of(isLoaded: loaded, photoCount: 5, shownCount: 3, isCollectionSelected: collection), .hasPhotos)
            }
        }
    }

    func testBeforeTheFirstReadNothingIsClaimed() {
        XCTAssertEqual(LibraryEmptyKind.of(isLoaded: false, photoCount: 0, shownCount: 0, isCollectionSelected: false), .loading)
        XCTAssertEqual(LibraryEmptyKind.of(isLoaded: false, photoCount: 0, shownCount: 0, isCollectionSelected: true), .loading)
    }

    func testALoadedCatalogWithNoPhotosIsAnEmptyLibraryWhichEverFolderIsSelected() {
        XCTAssertEqual(LibraryEmptyKind.of(isLoaded: true, photoCount: 0, shownCount: 0, isCollectionSelected: false), .emptyLibrary)
        XCTAssertEqual(LibraryEmptyKind.of(isLoaded: true, photoCount: 0, shownCount: 0, isCollectionSelected: true), .emptyLibrary)
    }

    func testAnEmptyCollectionInALibraryWithPhotosIsNotAnEmptyLibrary() {
        XCTAssertEqual(LibraryEmptyKind.of(isLoaded: true, photoCount: 40, shownCount: 0, isCollectionSelected: true), .emptyCollection)
    }

    func testAllPhotosWithACountButNoListYetIsDataInTransitNotAnEmptyCollection() {
        // refresh() publishes photoCount before photos: right after an import this state exists for a moment.
        XCTAssertEqual(LibraryEmptyKind.of(isLoaded: true, photoCount: 40, shownCount: 0, isCollectionSelected: false), .loading)
    }
}

@MainActor
final class EmptyStatesTests: XCTestCase {
    private var suiteName = ""

    override func tearDown() async throws {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    private var db: CatalogDatabase!

    private func makeCatalog() throws -> CatalogModel {
        suiteName = "EmptyStatesTests-\(UUID().uuidString)"
        db = try CatalogDatabase(inMemory: true)
        return CatalogModel(database: db, defaults: UserDefaults(suiteName: suiteName)!)
    }

    // MARK: isLoaded

    func testTheCatalogIsNotLoadedUntilItsFirstRefreshFinishes() async throws {
        let catalog = try makeCatalog()
        XCTAssertFalse(catalog.isLoaded)
        await catalog.refresh()
        XCTAssertTrue(catalog.isLoaded)
        XCTAssertEqual(catalog.photoCount, 0)
    }

    // MARK: rendering

    private func render<V: View>(_ view: V, size: CGSize = CGSize(width: 760, height: 480)) -> NSBitmapImageRep {
        let hosting = NSHostingView(rootView: view.background(Theme.panel).environment(\.colorScheme, .dark).tint(Theme.controlTint).frame(width: size.width, height: size.height))
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

    private func count(_ rep: NSBitmapImageRep, _ predicate: (NSColor) -> Bool) -> Int {
        var n = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), predicate(c) { n += 1 }
            }
        }
        return n
    }

    private func isBlueAccent(_ c: NSColor) -> Bool { c.blueComponent > c.redComponent + 0.25 && c.blueComponent > 0.5 }
    private func isLight(_ c: NSColor) -> Bool { c.redComponent > 0.6 && c.greenComponent > 0.6 && c.blueComponent > 0.6 }

    func testTheEmptyLibraryScreenShowsTextAndOnePrimaryImportButton() throws {
        let rep = render(LibraryEmptyLibraryView(catalog: try makeCatalog()))
        XCTAssertGreaterThan(count(rep) { self.isLight($0) }, 200, "the headline and body text are drawn")
        let blue = count(rep) { self.isBlueAccent($0) }
        XCTAssertGreaterThan(blue, 300, "the prominent Import Folder button is drawn in the accent")
    }

    func testTheEmptyCollectionScreenHasTextAndNoButtonsOrAccent() {
        let rep = render(LibraryEmptyCollectionView())
        XCTAssertGreaterThan(count(rep) { self.isLight($0) }, 100)
        XCTAssertEqual(count(rep) { self.isBlueAccent($0) }, 0)
    }

    func testTheEditorHintStaysHiddenDuringTheGapBeforeALoadStarts() {
        let rep = render(EditorNoPhotoView(appearDelay: 60, showLibrary: {}))
        XCTAssertEqual(count(rep) { self.isLight($0) }, 0, "nothing is drawn (or clickable) until the delay has passed")
    }

    func testTheOpenFailedScreenShowsTheReasonInTheWarningColour() {
        let rep = render(CatalogOpenFailedView(message: "This catalog was made by a newer version of Lightbench."))
        XCTAssertGreaterThan(count(rep) { self.isLight($0) }, 100)
        XCTAssertGreaterThan(count(rep) { $0.redComponent > 0.7 && $0.greenComponent > 0.45 && $0.blueComponent < 0.45 }, 50, "the warning triangle")
    }

    func testRemovingTheLastPhotoLeavesAnEmptyLibraryNotABlankGrid() async throws {
        let catalog = try makeCatalog()
        _ = try await db.importPhotos(at: [URL(fileURLWithPath: "/tmp/only-photo.jpg")])
        await catalog.refresh()
        XCTAssertEqual(catalog.photoCount, 1)
        catalog.removePhoto(try XCTUnwrap(catalog.photos.first))
        XCTAssertEqual(catalog.photoCount, 0, "the count is kept in step with the list, or the grid would be classified as in transit and stay blank")
        XCTAssertEqual(LibraryEmptyKind.of(isLoaded: catalog.isLoaded, photoCount: catalog.photoCount, shownCount: catalog.photos.count, isCollectionSelected: false), .emptyLibrary)
    }

    func testAHealthyCatalogReportsNoOpenFailure() throws {
        XCTAssertNil(try makeCatalog().openFailureMessage)
    }

    func testAFailedOpenOutranksEveryOtherState() {
        for loaded in [false, true] {
            XCTAssertEqual(LibraryEmptyKind.of(isLoaded: loaded, photoCount: 0, shownCount: 0, isCollectionSelected: false, openFailed: true), .openFailed)
        }
    }

    func testAFolderCollectionGetsFolderAdviceNotAddToCollectionAdvice() throws {
        let views = try source("Sources/UI/EmptyStates.swift")
        XCTAssertTrue(views.contains("No photos directly in this folder"))
        XCTAssertTrue(try source("Sources/UI/LibraryGridView.swift").contains("LibraryEmptyCollectionView(isFolder: Self.isFolderCollection(catalog))"))
    }

    func testTheOpenFailureScreenIsWiredIntoTheGridAndTheModel() throws {
        XCTAssertTrue(try source("Sources/UI/LibraryGridView.swift").contains("CatalogOpenFailedView(message: catalog.openFailureMessage"))
        XCTAssertTrue(try source("Sources/UI/CatalogModel.swift").contains("self?.openFailureMessage = error.localizedDescription"))
    }

    func testTheEditorNoPhotoScreenHasAShowLibraryButtonAndNoAccent() {
        let rep = render(EditorNoPhotoView(appearDelay: 0, showLibrary: {}))
        XCTAssertGreaterThan(count(rep) { self.isLight($0) }, 100)
        XCTAssertEqual(count(rep) { self.isBlueAccent($0) }, 0, "Show Library is a plain flat button, not a prominent one")
    }

    // MARK: wiring pins

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testTheLibraryGridUsesTheClassifierAndNeverFlashesNoPhotosWhileLoading() throws {
        let grid = try source("Sources/UI/LibraryGridView.swift")
        XCTAssertTrue(grid.contains("LibraryEmptyKind.of(isLoaded: catalog.isLoaded"))
        XCTAssertTrue(grid.contains("emptyKind == .loading"))
        XCTAssertTrue(grid.contains("LibraryEmptyLibraryView(catalog: catalog)"))
        XCTAssertTrue(grid.contains("LibraryEmptyCollectionView(isFolder:"))
        XCTAssertFalse(grid.contains("No photos imported yet"), "the old one-line empty state is gone")
        XCTAssertTrue(try source("Sources/UI/CatalogModel.swift").contains("defer { isLoaded = true }"))
    }

    func testTheEditorShowsTheNoPhotoHintOnlyWhenNothingIsOpenOrLoading() throws {
        let content = try source("Sources/UI/ContentView.swift")
        XCTAssertTrue(content.contains("EditorNoPhotoView { showLibrary = true }"))
        XCTAssertTrue(content.contains("if document.currentImage == nil, !document.isLoadingImage, !document.isLoadInFlight"))
    }
}
