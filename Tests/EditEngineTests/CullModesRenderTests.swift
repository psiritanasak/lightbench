import AppKit
import CoreImage
import SwiftUI
import XCTest
@testable import PhotoApp

/// The real `CullView` in Compare and Survey, rendered offscreen: each cell shows ITS photo, in the right place, and the focused cell has a ring.
@MainActor
final class CullModesRenderTests: XCTestCase {
    private var tempDir: URL!
    private var rows: [Int64: Photo] = [:]
    private let size = CGSize(width: 1000, height: 640)
    // Distinct, well-separated colours so a swapped or missing cell is obvious.
    private let colours: [(Double, Double, Double)] = [(0.9, 0.1, 0.1), (0.1, 0.8, 0.1), (0.9, 0.9, 0.1), (0.8, 0.1, 0.8)]

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("CullModesRenderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tempDir) }

    private func makeModel() throws -> CullModel {
        for (i, c) in colours.enumerated() {
            let image = CIImage(color: CIColor(red: c.0, green: c.1, blue: c.2)).cropped(to: CGRect(x: 0, y: 0, width: 1200, height: 800))
            let url = tempDir.appendingPathComponent("p\(i + 1).png")
            try CIContext().writePNGRepresentation(of: image, to: url, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            rows[Int64(i + 1)] = Photo(id: Int64(i + 1), path: url.path, filename: "p\(i + 1).png", fileSize: nil, importedAt: Date(timeIntervalSince1970: 0))
        }
        let model = CullModel()
        model.configure(CullEnvironment(photos: { self.rows.keys.sorted().compactMap { self.rows[$0] } }, rows: { self.rows }))
        model.setViewArea(width: 1000, height: 560, scale: 1)
        XCTAssertTrue(model.begin(startingAtPath: nil))
        return model
    }

    private func settle(_ model: CullModel) async {
        for _ in 0..<800 {
            let ids = model.session?.visibleIDs ?? []
            if !ids.isEmpty, ids.allSatisfy({ model.slots[$0]?.image != nil && model.slots[$0]?.isPlaceholder == false }) { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("previews never loaded")
    }

    private func renderNow(_ model: CullModel) -> NSBitmapImageRep {
        let catalog = CatalogModel(database: try! CatalogDatabase(inMemory: true), defaults: UserDefaults(suiteName: "CullModesRenderTests-\(UUID().uuidString)")!)
        let view = CullView(model: model, catalog: catalog, onExit: {}, onOpenInEditor: { _ in })
            .environment(\.colorScheme, .dark).tint(Theme.controlTint).frame(width: size.width, height: size.height)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)!
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.orderOut(nil)
        return rep
    }

    private func pixel(_ rep: NSBitmapImageRep, _ fx: Double, _ fy: Double) -> NSColor {
        (rep.colorAt(x: Int(Double(rep.pixelsWide) * fx), y: Int(Double(rep.pixelsHigh) * fy))?.usingColorSpace(.sRGB)) ?? .black
    }

    /// Which palette colour `c` is closest to (the render is colour-managed, so exact values drift by ~0.3).
    private func nearest(_ c: NSColor) -> Int {
        let distances = colours.map { pow(Double(c.redComponent) - $0.0, 2) + pow(Double(c.greenComponent) - $0.1, 2) + pow(Double(c.blueComponent) - $0.2, 2) }
        return distances.firstIndex(of: distances.min() ?? 0) ?? -1
    }

    func testCompareShowsTheSelectOnTheLeftAndTheCandidateOnTheRight() async throws {
        let model = try makeModel()
        model.setMode(.compare)                  // select 1 (red), candidate 2 (green)
        await settle(model)
        let rep = renderNow(model)
        XCTAssertEqual(nearest(pixel(rep, 0.25, 0.5)), 0, "left = the select")
        XCTAssertEqual(nearest(pixel(rep, 0.75, 0.5)), 1, "right = the candidate")
        model.handle(.swapCompare)               // select 2, candidate 1
        await settle(model)
        let swapped = renderNow(model)
        XCTAssertEqual(nearest(pixel(swapped, 0.25, 0.5)), 1)
        XCTAssertEqual(nearest(pixel(swapped, 0.75, 0.5)), 0)
        model.end()
    }

    func testTheFocusedCellHasABrightRingAndTheOtherDoesNot() async throws {
        let model = try makeModel()
        model.setMode(.compare)
        await settle(model)
        let rep = renderNow(model)
        // The candidate (right cell) is focused: bright pixels along ITS outer edge band, none along the select's left edge.
        func brightEdges(x0: Int, x1: Int) -> Int {
            var n = 0
            for y in stride(from: 80, to: rep.pixelsHigh - 60, by: 4) {
                for x in x0..<x1 {
                    if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.redComponent > 0.5, c.greenComponent > 0.5, c.blueComponent > 0.5 { n += 1 }
                }
            }
            return n
        }
        let right = brightEdges(x0: rep.pixelsWide - 6, x1: rep.pixelsWide)
        let left = brightEdges(x0: 0, x1: 6)
        XCTAssertGreaterThan(right, 20, "ring on the focused candidate")
        XCTAssertEqual(left, 0, "no ring on the select")
        model.end()
    }

    func testSurveyShowsEveryPhotoInItsOwnCellInListOrder() async throws {
        let model = try makeModel()
        model.setMode(.survey)
        await settle(model)
        let rep = renderNow(model)
        let grid = CullLayout.grid(count: 4, area: CGSize(width: 1000, height: 560))
        var seen: [Int] = []
        for index in 0..<4 {
            let column = index % grid.columns, row = index / grid.columns
            let fx = (Double(column) + 0.5) / Double(grid.columns)
            let fy = (Double(row) + 0.5) / Double(grid.rows) * (560.0 / 640.0) + 40.0 / 640.0
            let c = pixel(rep, fx, fy)
            seen.append(nearest(c))
        }
        XCTAssertEqual(seen, [0, 1, 2, 3], "each cell shows its own photo, left to right and top to bottom")
        model.end()
    }
}
