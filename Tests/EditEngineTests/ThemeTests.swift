import AppKit
import SwiftUI
import XCTest
@testable import PhotoApp

/// The flat look: neutral surfaces, one accent, SOLID floating panels (no `.regularMaterial` / `.bar` translucency). Offscreen renders
/// compare against plain colour rectangles through the SAME pipeline (it shifts dark greys, so raw token values are not comparable).
@MainActor
final class ThemeTests: XCTestCase {
    private func render<V: View>(_ content: V, size: CGSize) -> NSBitmapImageRep {
        let view = content.environment(\.colorScheme, .dark).frame(width: size.width, height: size.height)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)!
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.orderOut(nil)
        return rep
    }

    private func pixel(_ rep: NSBitmapImageRep, _ point: CGPoint, width: CGFloat) throws -> NSColor {
        let scale = CGFloat(rep.pixelsWide) / width
        return try XCTUnwrap(rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(.sRGB))
    }

    private func assertSame(_ got: NSColor, _ want: NSColor, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(got.alphaComponent, 1, accuracy: 0.001, "\(message): opaque", file: file, line: line)
        XCTAssertEqual(got.redComponent, want.redComponent, accuracy: 0.012, "\(message): red", file: file, line: line)
        XCTAssertEqual(got.greenComponent, want.greenComponent, accuracy: 0.012, "\(message): green", file: file, line: line)
        XCTAssertEqual(got.blueComponent, want.blueComponent, accuracy: 0.012, "\(message): blue", file: file, line: line)
    }

    // MARK: Tokens

    func testRaisedIsOneStepLighterThanThePanel() throws {
        let panel = try XCTUnwrap(NSColor(Theme.panel).usingColorSpace(.deviceGray)).whiteComponent
        let raised = try XCTUnwrap(NSColor(Theme.raised).usingColorSpace(.deviceGray)).whiteComponent
        XCTAssertEqual(panel, 0.11, accuracy: 0.001, "the Adjust panel's grey")
        XCTAssertGreaterThan(raised - panel, 0.04)
        XCTAssertLessThan(raised - panel, 0.15)
    }

    func testTheAccentIsABlue() throws {
        let c = try XCTUnwrap(NSColor(Theme.accent).usingColorSpace(.sRGB))
        XCTAssertGreaterThan(c.blueComponent, c.redComponent + 0.5)
        XCTAssertGreaterThan(c.blueComponent, c.greenComponent + 0.3)
    }

    // MARK: Solid panels

    func testSolidPanelIsOpaqueEvenOverABrightBackground() throws {
        let size = CGSize(width: 160, height: 90)
        let panel = ZStack {
            Color(red: 1, green: 0, blue: 1)
            Color.clear.frame(width: 120, height: 50).solidPanel(cornerRadius: 8)
        }
        let got = try pixel(render(panel, size: size), CGPoint(x: 80, y: 45), width: size.width)
        let want = try pixel(render(Theme.raised, size: size), CGPoint(x: 80, y: 45), width: size.width)
        assertSame(got, want, "a translucent material would let the magenta through")
    }

    func testTheRatingBarBackgroundIsTheSolidPanel() async throws {
        let row = Photo(id: 1, path: "/a.jpg", filename: "a", fileSize: nil, importedAt: Date(timeIntervalSince1970: 0))
        let meta = EditorPhotoMeta(resolve: { _ in row })
        await meta.sync(path: "/a.jpg", isLoading: false)?.value
        let size = CGSize(width: 600, height: 36)
        let bar = EditorRatingBar(meta: meta, canCopy: true, onCopy: {})
        // Mid-bar, near the bottom: no stars / buttons there.
        let point = CGPoint(x: 330, y: 28)
        assertSame(try pixel(render(bar, size: size), point, width: size.width),
                   try pixel(render(Theme.panel, size: size), point, width: size.width), "rating bar")
    }

    func testTheToolRailBackgroundIsTheSolidPanel() throws {
        let size = CGSize(width: EditorToolRailMetrics.width, height: 400)
        let rail = EditorToolRail(selectedTab: .constant(.adjust))
        let point = CGPoint(x: 28, y: 380)
        assertSame(try pixel(render(rail, size: size), point, width: size.width),
                   try pixel(render(Theme.panel, size: size), point, width: size.width), "tool rail")
    }

    // MARK: Text / icon colours that must not be the accent blue

    /// Pixels in a rectangle (view points) that look accent-blue: clearly more blue than red.
    private func bluePixels(_ rep: NSBitmapImageRep, in rect: CGRect, width: CGFloat) -> Int {
        let scale = CGFloat(rep.pixelsWide) / width
        var n = 0
        for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
            for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.5 else { continue }
                if c.blueComponent > 0.45 && c.blueComponent > c.redComponent + 0.25 { n += 1 }
            }
        }
        return n
    }

    func testCopySettingsLabelIsWhiteNotAccentBlue() async throws {
        let row = Photo(id: 1, path: "/a.jpg", filename: "a", fileSize: nil, importedAt: Date(timeIntervalSince1970: 0))
        let meta = EditorPhotoMeta(resolve: { _ in row })
        await meta.sync(path: "/a.jpg", isLoading: false)?.value
        let size = CGSize(width: 600, height: 36)
        // `.tint` at the app root (as in PhotoAppApp) is what turns borderless button text blue.
        let bar = EditorRatingBar(meta: meta, canCopy: true, onCopy: {}).tint(Theme.accent)
        let rep = render(bar, size: size)
        XCTAssertEqual(bluePixels(rep, in: CGRect(x: 440, y: 0, width: 160, height: 36), width: size.width), 0, "Copy Settings text/icon")
    }

    func testNeitherIdleNorActiveCompareEntryIsBlueButActiveIsWhite() throws {
        let size = CGSize(width: EditorToolRailMetrics.width, height: 7 * 42)
        func entry(compare: CompareViewMode) -> NSBitmapImageRep {
            render(EditorRailActions(document: ImageDocumentModel(), compareMode: .constant(compare), splitOrientation: .constant(.vertical),
                                     isHistoryPresented: .constant(false), isFilmstripVisible: .constant(false),
                                     canCompare: true, canEnhance: true, onEnhance: {}).tint(Theme.accent), size: size)
        }
        let band = CGRect(x: 0, y: 4 * 42, width: size.width, height: 36)
        XCTAssertEqual(bluePixels(entry(compare: .off), in: band, width: size.width), 0, "idle Compare icon is not blue")
        XCTAssertEqual(bluePixels(entry(compare: .split), in: band, width: size.width), 0, "active Compare icon is not blue either")
        // …and it is a CHIP: a point inside the cell but outside the glyph is `Theme.selectedFill` when active, not when idle.
        let on = entry(compare: .split), off = entry(compare: .off)
        let spot = CGPoint(x: 8, y: band.minY + 18)
        func at(_ rep: NSBitmapImageRep) throws -> NSColor {
            let scale = CGFloat(rep.pixelsWide) / size.width
            return try XCTUnwrap(rep.colorAt(x: Int(spot.x * scale), y: Int(spot.y * scale))?.usingColorSpace(.sRGB))
        }
        let onColour = try at(on), offColour = try at(off)
        // The pipeline shifts dark greys, so the expectation is a plain `selectedFill` rectangle rendered the same way.
        let want = try at(render(Theme.selectedFill, size: size))
        XCTAssertGreaterThan(onColour.alphaComponent, 0.9, "the chip is drawn")
        XCTAssertGreaterThan(onColour.redComponent, offColour.redComponent * offColour.alphaComponent + 0.05, "brighter than idle")
        XCTAssertEqual(onColour.redComponent, want.redComponent, accuracy: 0.05, "the chip colour is selectedFill")
    }

    // MARK: No translucent materials left

    /// A blunt guard for the HUDs, bars and selection marks that a render test cannot reach one by one: no UI source may use a translucent
    /// material or the system accent colour.
    func testNoTranslucentMaterialsOrSystemAccentAreUsedInTheUISources() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/UI")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 50, "found the UI sources")
        // `.accentColor` too: `Color.accentColor` is the SYSTEM accent (measured: `.tint` does not change it), so the app's one accent must be
        // `Theme.accent`.
        let banned = [".regularMaterial", ".ultraThinMaterial", ".thinMaterial", ".thickMaterial", ".ultraThickMaterial", ".background(.bar",
                      ".accentColor"]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = line.components(separatedBy: "//").first ?? ""
                for word in banned where code.contains(word) {
                    XCTFail("\(file.lastPathComponent):\(number + 1) uses \(word) — use Theme.panel / solidPanel / Theme.accent instead")
                }
            }
        }
    }

    /// Selected / current marks are never blue: the accent is for the primary action of a bar or sheet only (`FlatButtonStyle(prominent:)`),
    /// so it may be named only in the token file and the button style (plus `PhotoAppApp`, which is outside `Sources/UI` and sets the root `.tint`).
    func testTheAccentIsOnlyUsedByTheTokenFileAndTheButtonStyle() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/UI")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        let allowed: Set<String> = ["Theme.swift", "FlatButtonStyle.swift"]
        for file in files where !allowed.contains(file.lastPathComponent) {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = line.components(separatedBy: "//").first ?? ""
                if code.contains("Theme.accent") {
                    XCTFail("\(file.lastPathComponent):\(number + 1) uses Theme.accent — a selected/current mark is Theme.selectedFill / selectedOutline")
                }
            }
        }
    }
}
