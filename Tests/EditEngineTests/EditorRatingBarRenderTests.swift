import AppKit
import SwiftUI
import XCTest
@testable import PhotoApp

/// Renders the REAL `EditorRatingBar` offscreen: the bar shows the open photo's rating / flag / label and is inert without a catalog
/// row. Clicks and keys are not driven (synthetic events do not reach this app) — see the manual checklist in PROGRESS.md.
@MainActor
final class EditorRatingBarRenderTests: XCTestCase {
    private let size = CGSize(width: 600, height: 36)

    private func render(_ meta: EditorPhotoMeta, info: EditorInfoModel? = nil, size: CGSize? = nil,
                        saveStatus: SidecarSaveStatusPresentation? = nil) -> NSBitmapImageRep {
        let size = size ?? self.size
        let view = EditorRatingBar(meta: meta, canCopy: true, onCopy: {}, info: info, saveStatus: saveStatus)
            .frame(width: size.width, height: size.height)
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

    private func isYellow(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Bool { r > 0.7 && g > 0.6 && b < 0.35 && r - b > 0.4 }
    private func isRed(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Bool { r > 0.9 && g < 0.5 && b < 0.45 && r - g > 0.4 }
    private func isWhite(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Bool { r > 0.8 && g > 0.8 && b > 0.8 }
    /// The plain light grey of a filled star / Picked flag (`Theme.markOn`, 0.85) — neutral and bright.
    private func isMarkGrey(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Bool {
        r > 0.7 && abs(r - g) < 0.04 && abs(r - b) < 0.04
    }

    func testMoreStarsFillMoreLightGreyAndNeverYellow() async {
        let none = count(render(await meta(rating: 0)), isMarkGrey)
        let three = count(render(await meta(rating: 3)), isMarkGrey)
        let five = count(render(await meta(rating: 5)), isMarkGrey)
        XCTAssertGreaterThan(three, none)
        XCTAssertGreaterThan(five, three)
        // The yellow LABEL dot is always in the bar (meaning keeps its colour), so "not yellow" = filling stars adds no yellow.
        let yellowFive = count(render(await meta(rating: 5)), isYellow), yellowNone = count(render(await meta(rating: 0)), isYellow)
        XCTAssertEqual(yellowFive, yellowNone, "filled stars are not yellow")
    }

    func testPickedFlagIsYellow() async {
        let plainYellow = count(render(await meta()), isYellow)
        let pickedYellow = count(render(await meta(flag: .picked)), isYellow)
        XCTAssertGreaterThan(pickedYellow, plainYellow, "the Pick flag lights up yellow")
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

    // MARK: Info button

    func testTheInfoButtonIsDrawnOnlyWhenAnInfoModelIsGiven() async {
        let m = await meta()
        let without = count(render(m), isWhite)
        let with = count(render(m, info: EditorInfoModel()), isWhite)
        XCTAssertGreaterThan(with, without, "the Info label and icon add white pixels")
    }

    func testTheInfoButtonIsDimWithoutACatalogRow() async {
        // Isolate the button: its own white pixels = (with an info model) - (without), per state.
        let resolvedMeta = await meta(), unresolvedMeta = await meta(resolved: false)
        let resolvedDelta = count(render(resolvedMeta, info: EditorInfoModel()), isWhite) - count(render(resolvedMeta), isWhite)
        let unresolvedDelta = count(render(unresolvedMeta, info: EditorInfoModel()), isWhite) - count(render(unresolvedMeta), isWhite)
        XCTAssertGreaterThan(resolvedDelta, 20, "an enabled Info button draws white label and icon pixels")
        XCTAssertLessThan(unresolvedDelta, resolvedDelta / 4, "no row: the button is dim grey and adds almost no white")
    }

    func testCopySettingsKeepsItsFullLabelAtTheNarrowDefaultWidth() async {
        // At a narrow width the "Not in your Library" hint must give way, not Copy Settings: the trailing (right-aligned) strip
        // holding Copy Settings renders identically whether or not the hint is present.
        let narrow = CGSize(width: 440, height: 36)
        let strip = 90
        func rightStrip(_ m: EditorPhotoMeta) -> [UInt8] {
            let rep = render(m, size: narrow)
            var out: [UInt8] = []
            for y in 0..<rep.pixelsHigh { for x in (rep.pixelsWide - strip)..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                out.append(UInt8(c.redComponent * 255)); out.append(UInt8(c.greenComponent * 255)); out.append(UInt8(c.blueComponent * 255))
            } }
            return out
        }
        let inLibrary = rightStrip(await meta()), notInLibrary = rightStrip(await meta(resolved: false))
        XCTAssertTrue(inLibrary == notInLibrary, "Copy Settings is not truncated by the hint")
    }

    /// The lookup finding nothing leaves no row (the bar then draws its empty, disabled state — the render of that state is
    /// `testMoreStarsFillMoreLightGreyAndNeverYellow`'s zero-rating case plus the hint text).
    func testNoCatalogRowLeavesNoPhoto() async {
        let m = await meta(rating: 4, resolved: false)
        XCTAssertNil(m.photo)
    }

    // MARK: "Edits not saved" chip

    private func isAmber(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Bool { r > 0.8 && g > 0.5 && g < 0.75 && b < 0.4 && r - b > 0.45 }

    func testTheSaveStatusChipDrawsAmberOnlyWhenThereIsAProblem() async {
        let m = await meta()
        let none = count(render(m), isAmber)
        let problem = SidecarSaveStatusPresentation.make(for: .folderDeclined, sidecarFileName: "a.jpg.photoapp.json")
        let shown = count(render(m, saveStatus: problem), isAmber)
        let ok = count(render(m, saveStatus: SidecarSaveStatusPresentation.make(for: .ok, sidecarFileName: "x")), isAmber)
        // Measured 854 amber pixels (icon + caption); the icon alone is a fraction of that, so this needs the caption to be amber too.
        XCTAssertGreaterThan(shown, none + 400, "the warning triangle and caption are amber")
        XCTAssertEqual(ok, none, "status ok draws nothing")
    }

    func testTheChipDoesNotChangeTheBarBackground() async {
        let m = await meta()
        let problem = SidecarSaveStatusPresentation.make(for: .refusedUnreadable, sidecarFileName: "a.jpg.photoapp.json")
        let plain = render(m), withChip = render(m, saveStatus: problem)
        // The far-left padding strip and the top divider row are not touched by the chip.
        for (x, y) in [(2, 18), (2, 30), (300, 2)] {
            XCTAssertEqual(plain.colorAt(x: x, y: y), withChip.colorAt(x: x, y: y), "pixel (\(x), \(y))")
        }
    }

    func testTheChipDoesNotTruncateCopySettingsAtTheNarrowWidth() async {
        // ContentView always passes the Info model, so the bar is rendered as the app builds it; both the in-Library and the
        // no-catalog-row ("Not in your Library" hint) states are checked.
        let narrow = CGSize(width: 480, height: 36) // the Editor pane's minimum width (ContentView minWidth: 480)
        let problem = SidecarSaveStatusPresentation.make(for: .refusedNotLoaded, sidecarFileName: "a.jpg.photoapp.json")
        func rightStrip(resolved: Bool, _ status: SidecarSaveStatusPresentation?) async -> [UInt8] {
            let rep = render(await meta(resolved: resolved), info: EditorInfoModel(), size: narrow, saveStatus: status)
            var out: [UInt8] = []
            for y in 0..<rep.pixelsHigh { for x in (rep.pixelsWide - 90)..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                out.append(UInt8(c.redComponent * 255)); out.append(UInt8(c.greenComponent * 255)); out.append(UInt8(c.blueComponent * 255))
            } }
            return out
        }
        for resolved in [true, false] {
            let without = await rightStrip(resolved: resolved, nil), with = await rightStrip(resolved: resolved, problem)
            XCTAssertTrue(without == with, "Copy Settings and Info keep their place with the chip showing (catalog row: \(resolved))")
        }
    }
}
