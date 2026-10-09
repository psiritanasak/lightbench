import AppKit
import CoreImage
import SwiftUI
import XCTest
@testable import PhotoApp

/// The real `CullView` rendered offscreen: the photo is drawn, a Picked photo shows its yellow flag badge, and the bars are the solid
/// panel with no blue. Keys and clicks cannot be driven here (manual checklist in PROGRESS.md).
@MainActor
final class CullViewRenderTests: XCTestCase {
    private var tempDir: URL!
    private var rows: [Int64: Photo] = [:]
    private let size = CGSize(width: 1000, height: 640)

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("CullViewRenderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tempDir) }

    private func makeModel(flag: FlagStatus) throws -> CullModel {
        let image = CIImage(color: CIColor(red: 0.1, green: 0.7, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: 1200, height: 800))
        let url = tempDir.appendingPathComponent("p1.png")
        try CIContext().writePNGRepresentation(of: image, to: url, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        rows = [1: Photo(id: 1, path: url.path, filename: "p1.png", fileSize: nil, importedAt: Date(timeIntervalSince1970: 0),
                         rating: 0, flagStatus: flag, colorLabel: .none)]
        let model = CullModel()
        model.configure(CullEnvironment(photos: { Array(self.rows.values) }, rows: { self.rows }))
        model.setViewSize(longEdge: 800, scale: 1)
        // Flagged photos are not in an Unflagged-only list, so start the pass with everything.
        XCTAssertTrue(model.begin(startingAtPath: nil))
        model.setOnlyUnflagged(false)
        return model
    }

    private func render(_ model: CullModel) async -> NSBitmapImageRep {
        for _ in 0..<600 where !model.showsCurrentPhoto || model.isPlaceholder { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(model.showsCurrentPhoto && !model.isPlaceholder, "the preview never loaded")
        return renderNow(model)
    }

    /// Synchronous on purpose: `RunLoop.run(until:)` is unavailable in async contexts.
    private func renderNow(_ model: CullModel) -> NSBitmapImageRep {
        let defaults = UserDefaults(suiteName: "CullViewRenderTests-\(UUID().uuidString)")!
        let catalog = CatalogModel(database: try! CatalogDatabase(inMemory: true), defaults: defaults)
        let view = CullView(model: model, catalog: catalog, onExit: {}, onOpenInEditor: { _ in })
            .environment(\.colorScheme, .dark).tint(Theme.controlTint).frame(width: size.width, height: size.height)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
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

    /// The colour at a point given as a fraction of the view (origin top-left).
    private func pixel(_ rep: NSBitmapImageRep, _ fx: Double, _ fy: Double) -> NSColor {
        let c = rep.colorAt(x: Int(Double(rep.pixelsWide) * fx), y: Int(Double(rep.pixelsHigh) * fy))
        return c?.usingColorSpace(.sRGB) ?? .black
    }

    func testThePhotoIsDrawnInTheMiddleAndTheTopBarHasNoBlue() async throws {
        let model = try makeModel(flag: .none)
        let rep = await render(model)
        let centre = pixel(rep, 0.5, 0.5)
        XCTAssertGreaterThan(centre.greenComponent, 0.55, "the photo fills the middle")
        XCTAssertLessThan(centre.redComponent, 0.5)
        // The top bar's toggles must follow the grey control tint (the Blue LABEL dot in the bottom bar is blue by design).
        var blue = 0
        for y in 0..<(rep.pixelsHigh * 9 / 100) {
            for x in 0..<rep.pixelsWide {
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.blueComponent - c.redComponent > 0.35 { blue += 1 }
            }
        }
        XCTAssertEqual(blue, 0, "no blue in the top bar")
        model.end()
    }

    func testAPickedPhotoShowsTheYellowFlagBadgeAndAnUnflaggedOneDoesNot() async throws {
        let picked = try makeModel(flag: .picked)
        let pickedRep = await render(picked)
        let plain = try makeModel(flag: .none)
        let plainRep = await render(plain)
        func yellow(_ c: NSColor) -> Bool { c.redComponent > 0.85 && c.greenComponent > 0.7 && c.blueComponent < 0.35 }
        XCTAssertGreaterThan(count(pickedRep, yellow), count(plainRep, yellow) + 20, "the Picked badge (and bar flag) is yellow")
        picked.end(); plain.end()
    }

    func testARejectedPhotoIsDimmed() async throws {
        let rejected = try makeModel(flag: .rejected)
        let dim = pixel(await render(rejected), 0.5, 0.5)
        let normal = try makeModel(flag: .none)
        let bright = pixel(await render(normal), 0.5, 0.5)
        XCTAssertLessThan(dim.greenComponent, bright.greenComponent - 0.2, "a rejected photo is drawn at reduced opacity")
        rejected.end(); normal.end()
    }
}
