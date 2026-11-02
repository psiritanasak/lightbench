import AppKit
import CoreImage
import SwiftUI
import XCTest
@testable import PhotoApp

/// D58-2: colour-gradient slider tracks. Pure palette checks, a real-pipeline check that the Hue rainbow runs the way the
/// Hue slider really rotates colour, offscreen renders of `ThinSlider` / `EditSliderRow` with a track, and source pins for the
/// call sites.
@MainActor
final class SliderTrackPaletteTests: XCTestCase {
    // MARK: Helpers

    private func rgb(_ color: Color) throws -> (r: Double, g: Double, b: Double) {
        let ns = try XCTUnwrap(NSColor(color).usingColorSpace(.sRGB))
        return (Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent))
    }

    private func hueDegrees(_ color: Color) throws -> Double {
        let ns = try XCTUnwrap(NSColor(color).usingColorSpace(.sRGB))
        return Double(ns.hueComponent) * 360
    }

    private func luminance(_ color: Color) throws -> Double {
        let c = try rgb(color)
        return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
    }

    private func circularDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }

    // MARK: Palette

    func testTemperatureRunsBlueToNeutralToAmber() throws {
        let stops = SliderTrackPalette.temperature
        XCTAssertEqual(stops.count, 3)
        let left = try rgb(stops[0]), mid = try rgb(stops[1]), right = try rgb(stops[2])
        XCTAssertGreaterThan(left.b, left.r + 0.2, "cool end is blue-dominant")
        XCTAssertGreaterThan(right.r, right.b + 0.2, "warm end is red/amber-dominant")
        XCTAssertEqual(mid.r, mid.b, accuracy: 0.05, "the middle is neutral")
        XCTAssertEqual(mid.r, mid.g, accuracy: 0.05)
    }

    func testTintRunsGreenToNeutralToMagenta() throws {
        let stops = SliderTrackPalette.tint
        XCTAssertEqual(stops.count, 3)
        let left = try rgb(stops[0]), mid = try rgb(stops[1]), right = try rgb(stops[2])
        XCTAssertGreaterThan(left.g, left.r + 0.2)
        XCTAssertGreaterThan(left.g, left.b + 0.2, "left end is green-dominant")
        XCTAssertGreaterThan(right.r, right.g + 0.2)
        XCTAssertGreaterThan(right.b, right.g + 0.2, "right end is magenta")
        XCTAssertEqual(mid.r, mid.g, accuracy: 0.05)
    }

    func testHueIsARainbowCentredOnRed() throws {
        let stops = SliderTrackPalette.hue
        XCTAssertEqual(stops.count, 7, "-180...180 in 60 degree steps")
        let centre = try rgb(stops[3])
        XCTAssertGreaterThan(centre.r, 0.9)
        XCTAssertLessThan(centre.g, 0.1)
        XCTAssertLessThan(centre.b, 0.1)
        // Both ends are the same colour (cyan): the slider wraps.
        XCTAssertEqual(try hueDegrees(stops[0]), 180, accuracy: 1)
        XCTAssertEqual(try hueDegrees(stops[6]), 180, accuracy: 1)
    }

    /// MEASURED direction (temporary one-pixel pipeline probe, deleted): `hslHue = +60` turns pure red towards yellow/orange
    /// (r > g > b), `-60` towards magenta (b > g). The stop at +60 must therefore be yellow, the one at -60 magenta. This
    /// test keeps the real pipeline and the palette in agreement.
    func testHueStopsRunTheSameWayThePipelineRotates() throws {
        let linear = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let context = CIContext(options: [.workingColorSpace: linear, .workingFormat: CIFormat.RGBAf])
        func rotatedRed(_ degrees: Double) throws -> (r: Float, g: Float, b: Float) {
            var state = EditState()
            state.hslHue = degrees
            let color = try XCTUnwrap(CIColor(red: 0.5, green: 0.1, blue: 0.1, alpha: 1, colorSpace: linear))
            let input = CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
            let output = EditPipeline.apply(state, to: input)
            var buffer = [Float](repeating: 0, count: 4)
            context.render(output, toBitmap: &buffer, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBAf, colorSpace: linear)
            return (buffer[0], buffer[1], buffer[2])
        }
        let plus = try rotatedRed(60), minus = try rotatedRed(-60)
        XCTAssertGreaterThan(plus.g, plus.b, "+60 moves red towards yellow")
        XCTAssertGreaterThan(minus.b, minus.g, "-60 moves red towards magenta")
        let stops = SliderTrackPalette.hue
        let plusStop = try rgb(stops[4]), minusStop = try rgb(stops[2])
        XCTAssertGreaterThan(plusStop.g, plusStop.b, "palette +60 is the yellow side")
        XCTAssertGreaterThan(minusStop.b, minusStop.g, "palette -60 is the magenta side")
        XCTAssertEqual(try hueDegrees(stops[4]), 60, accuracy: 1)
        XCTAssertEqual(try hueDegrees(stops[2]), 300, accuracy: 1)
    }

    func testSaturationAndVibranceRunGreyToColour() throws {
        for stops in [SliderTrackPalette.saturation, SliderTrackPalette.vibrance] {
            XCTAssertGreaterThanOrEqual(stops.count, 2)
            let first = try rgb(stops[0]), last = try rgb(stops[stops.count - 1])
            XCTAssertEqual(first.r, first.g, accuracy: 0.03)
            XCTAssertEqual(first.g, first.b, accuracy: 0.03, "left end is grey")
            XCTAssertGreaterThan(max(last.r, last.g, last.b) - min(last.r, last.g, last.b), 0.5, "right end is vivid")
        }
    }

    func testSaturationRampRisesSteadilyFromGreyToVivid() throws {
        let stops = SliderTrackPalette.saturation
        XCTAssertEqual(stops.count, 7)
        var previous = -1.0
        for stop in stops {
            let ns = try XCTUnwrap(NSColor(stop).usingColorSpace(.sRGB))
            let value = Double(ns.saturationComponent)
            XCTAssertGreaterThan(value, previous, "saturation strictly increases left to right")
            previous = value
        }
        let first = try XCTUnwrap(NSColor(stops[0]).usingColorSpace(.sRGB))
        let middle = try XCTUnwrap(NSColor(stops[3]).usingColorSpace(.sRGB))
        let last = try XCTUnwrap(NSColor(stops[6]).usingColorSpace(.sRGB))
        XCTAssertEqual(Double(first.saturationComponent), 0, accuracy: 0.02)
        XCTAssertEqual(Double(middle.saturationComponent), 0.5, accuracy: 0.05, "identity sits at half saturation")
        XCTAssertGreaterThan(Double(last.saturationComponent), 0.95)
    }

    func testSelectiveHueSpanMatchesTheKernel() throws {
        let kernel = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/Rendering/Shaders/SelectiveColor.cikernel"),
            encoding: .utf8
        )
        XCTAssertTrue(kernel.contains("float kHue = \(Int(SliderTrackPalette.selectiveHueSpanDegrees)).0;"))
    }

    func testSelectiveBandTracks() throws {
        for (index, band) in SelectiveColorBand.allCases.enumerated() {
            let centre = SelectiveColorBandWeights.centers[index]
            let hue = SliderTrackPalette.selectiveHue(band)
            XCTAssertEqual(hue.count, 3, band.label)
            XCTAssertEqual(
                circularDistance(try hueDegrees(hue[0]), centre - SliderTrackPalette.selectiveHueSpanDegrees), 0,
                accuracy: 1, "\(band.label) left end is centre - 30 degrees"
            )
            XCTAssertEqual(circularDistance(try hueDegrees(hue[1]), centre), 0, accuracy: 1, band.label)
            XCTAssertEqual(
                circularDistance(try hueDegrees(hue[2]), centre + SliderTrackPalette.selectiveHueSpanDegrees), 0,
                accuracy: 1, "\(band.label) right end is centre + 30 degrees"
            )

            let sat = SliderTrackPalette.selectiveSaturation(band)
            XCTAssertEqual(sat.count, 2)
            let grey = try rgb(sat[0]), full = try rgb(sat[1]), swatch = try rgb(band.swatchColor)
            XCTAssertEqual(grey.r, grey.g, accuracy: 0.03, band.label)
            XCTAssertEqual(grey.g, grey.b, accuracy: 0.03, band.label)
            XCTAssertEqual(full.r, swatch.r, accuracy: 0.01, "\(band.label) saturation ends on the swatch colour")
            XCTAssertEqual(full.g, swatch.g, accuracy: 0.01)
            XCTAssertEqual(full.b, swatch.b, accuracy: 0.01)

            let lum = SliderTrackPalette.selectiveLuminance(band)
            XCTAssertEqual(lum.count, 3)
            XCTAssertLessThan(try luminance(lum[0]), try luminance(lum[1]), "\(band.label) dark to ...")
            XCTAssertLessThan(try luminance(lum[1]), try luminance(lum[2]), "... light")
            XCTAssertEqual(circularDistance(try hueDegrees(lum[2]), centre), 0, accuracy: 8, "\(band.label) keeps its hue")
        }
    }

    func testMaskTracksShareTheGlobalRamps() {
        XCTAssertEqual(SliderTrackPalette.maskTemperature, SliderTrackPalette.temperature)
        XCTAssertEqual(SliderTrackPalette.maskTint, SliderTrackPalette.tint)
        XCTAssertEqual(SliderTrackPalette.maskSaturation, SliderTrackPalette.saturation)
        XCTAssertEqual(SliderTrackPalette.vibrance, SliderTrackPalette.saturation)
    }

    // MARK: Rendering

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

    private func pixel(_ rep: NSBitmapImageRep, _ x: CGFloat, _ y: CGFloat, width: CGFloat) throws -> NSColor {
        let scale = CGFloat(rep.pixelsWide) / width
        return try XCTUnwrap(rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB))
    }

    func testATrackedSliderPaintsTheGradientAcrossTheWholeTrack() throws {
        let size = CGSize(width: 200, height: 22)
        // Thumb parked at the far right: the left end must still be the gradient's colour, not a filled white bar.
        let rep = render(
            ThinSlider(value: .constant(1), range: 0...1, track: SliderTrackPalette.temperature), size: size
        )
        let left = try pixel(rep, 6, 11, width: size.width)
        let quarter = try pixel(rep, 50, 11, width: size.width)
        XCTAssertGreaterThan(left.blueComponent, left.redComponent + 0.2, "left end is blue")
        XCTAssertGreaterThan(left.alphaComponent, 0.9)
        // ABSOLUTE checks: a 0.55 white bar drawn over the gradient would lift red to about 0.67 here (plain gradient 0.25).
        XCTAssertLessThan(left.redComponent, 0.45, "no white filled bar over the gradient (left end)")
        XCTAssertLessThan(quarter.redComponent, 0.55, "no white filled bar over the gradient (quarter)")

        let right = render(
            ThinSlider(value: .constant(0), range: 0...1, track: SliderTrackPalette.temperature), size: size
        )
        let rightEnd = try pixel(right, 194, 11, width: size.width)
        XCTAssertGreaterThan(rightEnd.redComponent, rightEnd.blueComponent + 0.2, "right end is amber")
        // Left end vs right end differ in hue.
        XCTAssertNotEqual(left.hueComponent, rightEnd.hueComponent, accuracy: 0.2)
    }

    func testTheRampRunsLeftToRight() throws {
        let size = CGSize(width: 200, height: 22)
        let rep = render(ThinSlider(value: .constant(0.5), range: 0...1, track: SliderTrackPalette.tint), size: size)
        let left = try pixel(rep, 6, 11, width: size.width)
        let right = try pixel(rep, 194, 11, width: size.width)
        XCTAssertGreaterThan(left.greenComponent, left.redComponent, "tint: green on the left")
        XCTAssertGreaterThan(right.redComponent, right.greenComponent, "tint: magenta on the right")
    }

    func testTheThumbGetsAHairlineOnlyOverATrack() throws {
        let size = CGSize(width: 200, height: 22)
        let thumbX = CGFloat(ThinSliderGeometry.thumbCenterX(fraction: 0.5, trackWidth: 200, thumbWidth: 5))
        // Thumb edge pixel (the thumb is 5 pt wide, so 1.7 pt from its centre is inside the outline band), at a row above
        // the track where only the thumb is drawn.
        let plain = render(ThinSlider(value: .constant(0.5), range: 0...1), size: size)
        let tracked = render(
            ThinSlider(value: .constant(0.5), range: 0...1, track: [.white, .white]), size: size
        )
        let plainEdge = try pixel(plain, thumbX - 2, 5, width: size.width)
        let trackedEdge = try pixel(tracked, thumbX - 2, 5, width: size.width)
        XCTAssertGreaterThan(plainEdge.redComponent, 0.95, "the default thumb stays a plain white capsule")
        XCTAssertLessThan(trackedEdge.redComponent, plainEdge.redComponent - 0.1, "a tracked thumb has a dark hairline")
        let centre = try pixel(tracked, thumbX, 5, width: size.width)
        XCTAssertGreaterThan(centre.redComponent, 0.95, "its middle is still white")
    }

    func testAnEditSliderRowForwardsItsTrack() throws {
        let size = CGSize(width: 240, height: 60)
        let rep = render(
            EditSliderRow(
                label: "Tint", value: .constant(0), range: -100...100, identity: 0,
                track: SliderTrackPalette.tint
            ) { String(format: "%+.0f", $0) }
            .padding(.horizontal, 10),
            size: size
        )
        // The slider sits in the lower part of the row; scan down the left side for a green-dominant pixel.
        var found = false
        for y in stride(from: 20, to: 58, by: 2) {
            let c = try pixel(rep, 14, CGFloat(y), width: size.width)
            if c.alphaComponent > 0.9, c.greenComponent > c.redComponent + 0.15, c.greenComponent > c.blueComponent + 0.15 {
                found = true
            }
        }
        XCTAssertTrue(found, "the row's slider shows the tint ramp")
    }

    // MARK: Wiring

    private func source(_ relative: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func slice(_ marker: String, in text: String, length: Int) throws -> String {
        let start = try XCTUnwrap(text.range(of: marker), marker)
        return String(text[start.upperBound...].prefix(length))
    }

    func testEditSliderRowPassesItsTrackToTheSlider() throws {
        let rows = try source("Sources/UI/EditControlRows.swift")
        XCTAssertTrue(rows.contains("var track: [Color]? = nil"))
        XCTAssertTrue(rows.contains("ThinSlider(value: $value, range: range, valueDescription: format, track: track)"))
    }

    func testTheColorSectionUsesTheRamps() throws {
        let view = try source("Sources/UI/AdjustTabView.swift")
        let section = try slice("private var colorSection: some View {", in: view, length: 3200)
        for name in ["temperature", "tint", "hue", "vibrance", "saturation"] {
            XCTAssertTrue(section.contains("track: SliderTrackPalette.\(name)"), name)
        }
    }

    func testSelectiveColorRowsUseTheirBandRamps() throws {
        let view = try source("Sources/UI/AdjustTabView.swift")
        let section = try slice("label: \"Range\", value: $document.editState.selectiveColorRange", in: view, length: 2200)
        XCTAssertTrue(section.contains("track: SliderTrackPalette.selectiveHue(panel.selectedSelectiveColorBand)"))
        XCTAssertTrue(section.contains("track: SliderTrackPalette.selectiveSaturation(panel.selectedSelectiveColorBand)"))
        XCTAssertTrue(section.contains("track: SliderTrackPalette.selectiveLuminance(panel.selectedSelectiveColorBand)"))
    }

    func testMaskRowsUseTheRamps() throws {
        let view = try source("Sources/UI/MaskDetailView.swift")
        for name in ["maskSaturation", "maskTemperature", "maskTint"] {
            XCTAssertTrue(view.contains("track: SliderTrackPalette.\(name)"), name)
        }
    }

    func testPointColorAndBWMixAreLeftAlone() throws {
        let view = try source("Sources/UI/AdjustTabView.swift")
        let mix = try slice("grayMixBinding(for band: SelectiveColorBand)", in: view, length: 400)
        XCTAssertFalse(mix.contains("track:"))
        let point = try source("Sources/UI/PointColorDetailView.swift")
        XCTAssertFalse(point.contains("SliderTrackPalette"))
    }
}
