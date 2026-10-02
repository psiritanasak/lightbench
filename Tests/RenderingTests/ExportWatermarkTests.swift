import XCTest
import CoreImage
@testable import PhotoApp

/// Export text watermark: composited after sharpening, never part of an edit.
final class ExportWatermarkTests: XCTestCase {
    private let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private let width = 600, height = 400

    /// A flat mid-grey (0.3 linear) opaque image.
    private func flat() -> CIImage {
        let color = CIColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 1, colorSpace: linear)!
        return CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    private func mark(_ position: WatermarkPosition = .bottomRight, text: String = "© Test", size: Double = 0.08, opacity: Double = 1,
                      enabled: Bool = true) -> ExportWatermark {
        var watermark = ExportWatermark()
        watermark.isEnabled = enabled
        watermark.text = text
        watermark.position = position
        watermark.sizeFraction = size
        watermark.opacity = opacity
        return watermark
    }

    /// RGBA floats of the whole image. `render(toBitmap:)` writes row 0 = the TOP of the image.
    private func pixels(_ image: CIImage) -> [Float] {
        let context = CIContext(options: [.workingColorSpace: linear, .workingFormat: CIFormat.RGBAf])
        var data = [Float](repeating: 0, count: 4 * width * height)
        context.render(image, toBitmap: &data, rowBytes: 16 * width, bounds: CGRect(x: 0, y: 0, width: width, height: height),
                       format: .RGBAf, colorSpace: linear)
        return data
    }

    /// Bounding box (x0, y0, x1, y1) of pixels that differ from `base`, in Core Image's y-UP coordinates (y = 0 is
    /// the bottom row), or nil when identical.
    private func changedBox(_ image: CIImage, from base: [Float], threshold: Float = 0.002) -> (Int, Int, Int, Int)? {
        let data = pixels(image)
        var box: (Int, Int, Int, Int)?
        for y in 0..<height {
            for x in 0..<width {
                let i = 4 * (y * width + x)
                if abs(data[i] - base[i]) > threshold || abs(data[i + 1] - base[i + 1]) > threshold || abs(data[i + 2] - base[i + 2]) > threshold {
                    let up = height - 1 - y
                    box = box.map { (min($0.0, x), min($0.1, up), max($0.2, x), max($0.3, up)) } ?? (x, up, x, up)
                }
            }
        }
        return box
    }

    private lazy var basePixels = pixels(flat())

    // MARK: - No-ops

    func testDisabledOrEmptyOrBlankTextChangesNothing() {
        for watermark in [mark(enabled: false), mark(text: ""), mark(text: "  \n\t ")] {
            XCTAssertNil(changedBox(WatermarkRenderer.apply(watermark, to: flat()), from: basePixels), "\(watermark)")
        }
    }

    func testExtentIsNeverChanged() {
        for position in WatermarkPosition.allCases {
            let out = WatermarkRenderer.apply(mark(position), to: flat())
            XCTAssertEqual(out.extent, flat().extent, "\(position)")
        }
    }

    // MARK: - Placement

    func testEachPositionPutsTheMarkInThatPartOfTheImage() throws {
        for position in WatermarkPosition.allCases {
            let box = try XCTUnwrap(changedBox(WatermarkRenderer.apply(mark(position), to: flat()), from: basePixels), "\(position)")
            let centerX = Double(box.0 + box.2) / 2, centerY = Double(box.1 + box.3) / 2
            let grid = position.grid
            switch grid.x {
            case -1: XCTAssertLessThan(centerX, Double(width) / 3, "\(position) x")
            case 1: XCTAssertGreaterThan(centerX, Double(width) * 2 / 3, "\(position) x")
            default: XCTAssertEqual(centerX, Double(width) / 2, accuracy: 6, "\(position) x")
            }
            switch grid.y {
            case -1: XCTAssertLessThan(centerY, Double(height) / 3, "\(position) y")      // y up: small y = bottom
            case 1: XCTAssertGreaterThan(centerY, Double(height) * 2 / 3, "\(position) y")
            default: XCTAssertEqual(centerY, Double(height) / 2, accuracy: 6, "\(position) y")
            }
        }
    }

    func testTheMarkStaysInsideTheFrameWithAMargin() throws {
        let box = try XCTUnwrap(changedBox(WatermarkRenderer.apply(mark(.topLeft), to: flat()), from: basePixels))
        XCTAssertGreaterThan(box.0, 2)
        XCTAssertLessThan(box.3, height - 2)
    }

    // MARK: - Size and opacity

    func testSizeScalesWithTheShortEdge() throws {
        let small = try XCTUnwrap(changedBox(WatermarkRenderer.apply(mark(size: 0.04), to: flat()), from: basePixels))
        let large = try XCTUnwrap(changedBox(WatermarkRenderer.apply(mark(size: 0.08), to: flat()), from: basePixels))
        let ratio = Double(large.3 - large.1) / Double(small.3 - small.1)
        XCTAssertEqual(ratio, 2, accuracy: 0.35, "doubling the size fraction doubles the text height (got \(ratio))")
    }

    func testAMarkWiderThanTheImageShrinksToFit() throws {
        let long = String(repeating: "W", count: 80)
        let box = try XCTUnwrap(changedBox(WatermarkRenderer.apply(mark(.center, text: long, size: 0.15), to: flat()), from: basePixels))
        XCTAssertLessThanOrEqual(Double(box.2 - box.0 + 1), WatermarkRenderer.maximumWidthFraction * Double(width) + 6)
    }

    func testOpacityScalesTheMarksStrength() throws {
        func peak(_ opacity: Double) -> Float {
            let data = pixels(WatermarkRenderer.apply(mark(.center, opacity: opacity), to: flat()))
            return zip(data, basePixels).map { abs($0 - $1) }.max() ?? 0
        }
        let strong = peak(1), faint = peak(0.3)
        XCTAssertGreaterThan(strong, faint * 1.8, "full opacity \(strong) vs 0.3 opacity \(faint)")
        XCTAssertGreaterThan(faint, 0.01)
    }

    /// Regression for a silent drop: the UNSHRUNK line is wider than the 16384px bitmap limit, but the shrunk line fits.
    func testVeryLongTextOnAWideImageStillGetsAShrunkMark() throws {
        let long = String(repeating: "W", count: 200)
        let wide = CIImage(color: CIColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 1, colorSpace: linear)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 4000, height: 1000))
        let fontSize = 0.15 * 1000.0
        XCTAssertNil(WatermarkRenderer.render(long, fontSize: fontSize, opacity: 1),
                     "precondition: the unshrunk 150px-font, 200-character line exceeds the bitmap limit")
        var watermark = mark(.center, text: long, size: 0.15)
        watermark.sizeFraction = 0.15
        let marked = WatermarkRenderer.apply(watermark, to: wide)
        let context = CIContext(options: [.workingColorSpace: linear, .workingFormat: CIFormat.RGBAf])
        let strip = CGRect(x: 100, y: 440, width: 3800, height: 120)
        func render(_ image: CIImage) -> [Float] {
            var data = [Float](repeating: 0, count: 4 * Int(strip.width * strip.height))
            context.render(image, toBitmap: &data, rowBytes: 16 * Int(strip.width), bounds: strip, format: .RGBAf, colorSpace: linear)
            return data
        }
        let changed = zip(render(marked), render(wide)).contains { abs($0 - $1) > 0.05 }
        XCTAssertTrue(changed, "the mark must be drawn shrunk, not silently dropped")
    }

    /// Colour emoji are bitmaps that ignore a fill alpha; the opacity must still apply to them.
    func testOpacityAppliesToColourEmojiToo() throws {
        func peak(_ opacity: Double) throws -> Float {
            let data = pixels(WatermarkRenderer.apply(mark(.center, text: "😀", size: 0.2, opacity: opacity), to: flat()))
            return zip(data, basePixels).map { abs($0 - $1) }.max() ?? 0
        }
        let full = try peak(1), faint = try peak(0.2)
        XCTAssertGreaterThan(full, 0.05)
        XCTAssertLessThan(faint, full * 0.6, "emoji at 20% opacity must be much fainter (full \(full), faint \(faint))")
    }

    /// The visible glyphs (not the shadow padding or blur halo) sit `marginFraction` of the short edge from the edge.
    func testMarginIsMeasuredToTheVisibleGlyphs() throws {
        // Threshold 0.3: the white glyphs lift the 0.3 field by ~0.7 while the shadow only darkens it by < 0.2.
        let box = try XCTUnwrap(changedBox(WatermarkRenderer.apply(mark(.bottomLeft, size: 0.08), to: flat()), from: basePixels, threshold: 0.3))
        let expected = WatermarkRenderer.marginFraction * Double(min(width, height))
        XCTAssertEqual(Double(box.0), expected, accuracy: 3, "left gap \(box.0) vs margin \(expected)")
    }

    func testNonLatinTextRenders() throws {
        XCTAssertNotNil(changedBox(WatermarkRenderer.apply(mark(text: "ลิขสิทธิ์ ภาพ"), to: flat()), from: basePixels), "Thai")
        XCTAssertNotNil(changedBox(WatermarkRenderer.apply(mark(text: "版权所有"), to: flat()), from: basePixels), "CJK")
    }

    func testTextIsNormalisedToOneLineAndCapped() {
        XCTAssertEqual(WatermarkRenderer.normalizedText("  a \n b\t\tc  "), "a b c")
        XCTAssertEqual(WatermarkRenderer.normalizedText(String(repeating: "x", count: 500)).count, ExportWatermark.maximumTextLength)
    }

    // MARK: - Export wiring

    func testExportCompositesTheMarkAndLeavesTheRestAlone() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ExportWatermarkTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("flat.png")
        try PhotoExporter.context.writePNGRepresentation(of: flat(), to: source, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let photo = Photo(id: 1, path: source.path, filename: "flat.png", fileSize: nil, importedAt: Date())
        func export(_ watermark: ExportWatermark, name: String) async throws -> CIImage {
            let url = try await PhotoExporter.export(photo, editState: .identity, to: dir,
                                                     settings: ExportSettings(format: .png, namingTemplate: name, watermark: watermark))
            return try XCTUnwrap(CIImage(contentsOf: url))
        }
        let plain = try await export(mark(enabled: false), name: "plain")
        let marked = try await export(mark(.bottomRight), name: "marked")
        let plainPixels = pixels(plain)
        let box = try XCTUnwrap(changedBox(marked, from: plainPixels), "the export carries the mark")
        XCTAssertGreaterThan(box.0, width / 2)
        XCTAssertLessThan(box.3, height / 3)
    }

    // MARK: - Settings

    func testWatermarkIsRememberedTolerantlyClampedAndDefaultsOff() throws {
        XCTAssertFalse(ExportSettings().watermark.isEnabled)
        let suite = "ExportWatermarkTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ExportSettingsStore(defaults: defaults)
        store.save(ExportSettings(watermark: mark(.topLeft, text: "© Me", size: 0.06, opacity: 0.5)))
        let loaded = store.load().watermark
        XCTAssertEqual(loaded, mark(.topLeft, text: "© Me", size: 0.06, opacity: 0.5))

        defaults.set(Data(#"{"watermark":{"isEnabled":true,"text":"hi","position":"middle","sizeFraction":9,"opacity":-4}}"#.utf8),
                     forKey: ExportSettingsStore.key)
        let odd = store.load().watermark
        XCTAssertTrue(odd.isEnabled)
        XCTAssertEqual(odd.text, "hi")
        XCTAssertEqual(odd.position, .bottomRight, "unknown position falls back")
        XCTAssertEqual(odd.sizeFraction, ExportWatermark.sizeRange.upperBound)
        XCTAssertEqual(odd.opacity, ExportWatermark.opacityRange.lowerBound)
    }
}
