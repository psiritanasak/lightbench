import CoreImage
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PhotoApp

/// The 90-degree rotation edit: the pure helpers (`QuarterTurn`, `EditState.rotated(byQuarterTurns:)`), the pipeline's first
/// geometry stage on a real render, and the `EditState` plumbing (Codable, identity lists, Preset, Compare, diff label).
final class QuarterTurnTests: XCTestCase {
    private let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options: [.workingColorSpace: linearSpace, .workingFormat: CIFormat.RGBAf])

    // MARK: - Helpers

    /// Top-left red, top-right green, bottom-left blue, bottom-right yellow ("top" as a viewer sees it).
    private func quadrantImage(width: Int = 80, height: Int = 40) -> CIImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let top = y < height / 2, left = x < width / 2
                switch (top, left) {
                case (true, true): pixels[i] = 255; pixels[i + 1] = 0; pixels[i + 2] = 0
                case (true, false): pixels[i] = 0; pixels[i + 1] = 255; pixels[i + 2] = 0
                case (false, true): pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 255
                case (false, false): pixels[i] = 255; pixels[i + 1] = 255; pixels[i + 2] = 0
                }
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                         space: CGColorSpaceCreateDeviceRGB(),
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return CIImage(cgImage: cg)
    }

    private func color(of image: CIImage, at point: CGPoint) -> String {
        guard let cg = context.createCGImage(image, from: CGRect(x: point.x, y: point.y, width: 1, height: 1),
                                             format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()),
              let data = cg.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return "?" }
        switch (ptr[0], ptr[1], ptr[2]) {
        case (255, 0, 0): return "red"
        case (0, 255, 0): return "green"
        case (0, 0, 255): return "blue"
        case (255, 255, 0): return "yellow"
        default: return "other(\(ptr[0]),\(ptr[1]),\(ptr[2]),\(ptr[3]))"
        }
    }

    /// The colours at the centres of the four quadrants of `image`'s own extent: [TL, TR, BL, BR].
    private func quadrants(_ image: CIImage) -> [String] {
        let e = image.extent
        return [(0.25, 0.75), (0.75, 0.75), (0.25, 0.25), (0.75, 0.25)].map { fx, fy in
            color(of: image, at: CGPoint(x: e.minX + e.width * fx, y: e.minY + e.height * fy))
        }
    }

    private func pixels(_ image: CIImage) -> [Float] {
        let e = image.extent
        var buffer = [Float](repeating: 0, count: Int(e.width * e.height) * 4)
        context.render(image, toBitmap: &buffer, rowBytes: Int(e.width) * 16, bounds: e, format: .RGBAf, colorSpace: linearSpace)
        return buffer
    }

    private func assertSamePixels(_ a: CIImage, _ b: CIImage, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.extent.size, b.extent.size, message, file: file, line: line)
        let pa = pixels(a), pb = pixels(b)
        guard pa.count == pb.count else { return XCTFail("\(message): sizes differ", file: file, line: line) }
        let worst = zip(pa, pb).map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThan(worst, 0.002, message, file: file, line: line)
    }

    // MARK: - Normalisation and orientation

    func testNormalizationWrapsIntoZeroToThree() {
        XCTAssertEqual([-5, -4, -1, 0, 1, 3, 4, 7].map(QuarterTurn.normalized), [3, 0, 3, 0, 1, 3, 0, 3])
    }

    func testOrientationForTurnsUsesTheExifClockwiseValues() {
        XCTAssertEqual(QuarterTurn.orientation(forTurns: 0), .up)
        XCTAssertEqual(QuarterTurn.orientation(forTurns: 1).rawValue, 6)
        XCTAssertEqual(QuarterTurn.orientation(forTurns: 2).rawValue, 3)
        XCTAssertEqual(QuarterTurn.orientation(forTurns: 3).rawValue, 8)
        XCTAssertEqual(QuarterTurn.orientation(forTurns: -1).rawValue, 8)
    }

    /// Derived by hand from "clockwise": the top-left quadrant goes to the top-right, and so on. A real render, not the helper's own value.
    func testApplyTurnsTheQuadrantsClockwiseOnARealRender() {
        let input = quadrantImage()   // 80 x 40
        XCTAssertEqual(quadrants(input), ["red", "green", "blue", "yellow"])
        let one = QuarterTurn.apply(1, to: input)
        XCTAssertEqual(one.extent, CGRect(x: 0, y: 0, width: 40, height: 80), "extent swaps, origin back at (0, 0)")
        XCTAssertEqual(quadrants(one), ["blue", "red", "yellow", "green"])
        let two = QuarterTurn.apply(2, to: input)
        XCTAssertEqual(two.extent, CGRect(x: 0, y: 0, width: 80, height: 40))
        XCTAssertEqual(quadrants(two), ["yellow", "blue", "green", "red"])
        let three = QuarterTurn.apply(3, to: input)
        XCTAssertEqual(three.extent, CGRect(x: 0, y: 0, width: 40, height: 80))
        XCTAssertEqual(quadrants(three), ["green", "yellow", "red", "blue"])
    }

    func testApplyMatchesCoreImageOrientedByTheExpectedExifValue() {
        let input = quadrantImage()
        for (turns, exif) in [(1, CGImagePropertyOrientation.right), (2, .down), (3, .left)] {
            assertSamePixels(QuarterTurn.apply(turns, to: input), input.oriented(exif), "turns \(turns) == oriented(\(exif.rawValue))")
        }
    }

    func testApplyKeepsAnExactPixelPermutationAndOriginAtZero() {
        let shifted = quadrantImage().transformed(by: CGAffineTransform(translationX: 37, y: -11))
        let out = QuarterTurn.apply(3, to: shifted)
        XCTAssertEqual(out.extent.origin, .zero)
        XCTAssertEqual(out.extent.size, CGSize(width: 40, height: 80))
        XCTAssertEqual(quadrants(out), ["green", "yellow", "red", "blue"])
    }

    func testApplyZeroTurnsReturnsTheSameImage() {
        let input = quadrantImage()
        XCTAssertEqual(QuarterTurn.apply(0, to: input), input)
        XCTAssertEqual(QuarterTurn.apply(4, to: input), input)
    }

    func testFourTurnsAreAnExactRoundTrip() {
        let input = quadrantImage()
        var image = input
        for _ in 0..<4 { image = QuarterTurn.apply(1, to: image) }
        assertSamePixels(image, input, "four quarter turns")
    }

    // MARK: - Rotate buttons on EditState

    private func withInsets(top: Double = 0.1, right: Double = 0.2, bottom: Double = 0.3, left: Double = 0.4) -> EditState {
        EditState(cropInsetTop: top, cropInsetBottom: bottom, cropInsetLeft: left, cropInsetRight: right)
    }

    func testRotateRightPermutesTheInsetsClockwise() {
        let r = withInsets().rotated(byQuarterTurns: 1)
        XCTAssertEqual(r.rotationQuarterTurns, 1)
        XCTAssertEqual(r.cropInsetRight, 0.1, "top -> right")
        XCTAssertEqual(r.cropInsetBottom, 0.2, "right -> bottom")
        XCTAssertEqual(r.cropInsetLeft, 0.3, "bottom -> left")
        XCTAssertEqual(r.cropInsetTop, 0.4, "left -> top")
    }

    func testRotateLeftIsTheInversePermutation() {
        let r = withInsets().rotated(byQuarterTurns: -1)
        XCTAssertEqual(r.rotationQuarterTurns, 3)
        XCTAssertEqual(r.cropInsetLeft, 0.1, "top -> left")
        XCTAssertEqual(r.cropInsetTop, 0.2, "right -> top")
        XCTAssertEqual(r.cropInsetRight, 0.3, "bottom -> right")
        XCTAssertEqual(r.cropInsetBottom, 0.4, "left -> bottom")
    }

    func testFourPressesReturnTheIdenticalStateIncludingTheCrop() {
        for direction in [1, -1] {
            var s = withInsets()
            s.straightenAngle = 3
            s.exposureEV = 0.4
            let start = s
            for _ in 0..<4 { s = s.rotated(byQuarterTurns: direction) }
            XCTAssertEqual(s, start)
        }
    }

    func testRightThenLeftIsIdentity() {
        let s = withInsets()
        XCTAssertEqual(s.rotated(byQuarterTurns: 1).rotated(byQuarterTurns: -1), s)
    }

    func testMultipleOfFourTurnsReturnsSelf() {
        let s = withInsets()
        XCTAssertEqual(s.rotated(byQuarterTurns: 0), s)
        XCTAssertEqual(s.rotated(byQuarterTurns: 4), s)
    }

    func testOneFlipInvertsTheStoredDirectionButNotTheCropPermutation() {
        for flip in [(true, false), (false, true)] {
            var s = withInsets()
            s.flipHorizontal = flip.0
            s.flipVertical = flip.1
            let r = s.rotated(byQuarterTurns: 1)
            XCTAssertEqual(r.rotationQuarterTurns, 3, "pressed Right with one flip: stored turn goes the other way")
            XCTAssertEqual(r.cropInsetRight, 0.1, "the crop still follows the SCREEN rotation")
            XCTAssertEqual(r.cropInsetTop, 0.4)
        }
    }

    func testTwoFlipsDoNotInvertTheStoredDirection() {
        var s = withInsets()
        s.flipHorizontal = true
        s.flipVertical = true
        XCTAssertEqual(s.rotated(byQuarterTurns: 1).rotationQuarterTurns, 1)
    }

    /// The point of the inversion: with ONE flip on, Rotate Right still looks clockwise on screen.
    func testRotateRightLooksClockwiseOnScreenWithAFlipOn() {
        let input = quadrantImage(width: 40, height: 40)
        for (h, v) in [(true, false), (false, true), (false, false), (true, true)] {
            var before = EditState()
            before.flipHorizontal = h
            before.flipVertical = v
            let after = before.rotated(byQuarterTurns: 1)
            let shownBefore = EditPipeline.apply(before, to: input)
            let shownAfter = EditPipeline.apply(after, to: input)
            // The picture shown after must be the picture shown before, turned clockwise on screen.
            assertSamePixels(shownAfter, QuarterTurn.apply(1, to: shownBefore), "flip \(h),\(v)")
        }
    }

    func testSettingStoredTurnsSetsTheCountAndMovesTheCropWithTheContent() {
        let s = withInsets().settingStoredQuarterTurns(1)
        XCTAssertEqual(s.rotationQuarterTurns, 1)
        XCTAssertEqual(s.cropInsetRight, 0.1)
        var flipped = withInsets()
        flipped.flipHorizontal = true
        let f = flipped.settingStoredQuarterTurns(1)
        XCTAssertEqual(f.rotationQuarterTurns, 1, "the stored count is what the caller asked for, with a flip on too")
        XCTAssertEqual(f.cropInsetLeft, 0.1, "stored +1 with one flip = screen -1: top -> left")
        XCTAssertEqual(withInsets().settingStoredQuarterTurns(0), withInsets())
    }

    // MARK: - Lightroom orientation algebra

    func testDisplayTurnsForRotationOnlyValuesAndNilForMirrored() {
        XCTAssertEqual([1, 6, 3, 8].map { QuarterTurn.displayTurns(forOrientation: $0) }, [0, 1, 2, 3])
        for mirrored in [2, 4, 5, 7, 0, 9] { XCTAssertNil(QuarterTurn.displayTurns(forOrientation: mirrored)) }
    }

    func testRelativeTurnsAgainstEveryPhotoOrientation() {
        // Relative = packet - photo (mod 4), for all 16 rotation-only pairs.
        let values = [1, 6, 3, 8]
        for (pi, packet) in values.enumerated() {
            for (qi, photo) in values.enumerated() {
                XCTAssertEqual(QuarterTurn.relativeTurns(packetOrientation: packet, photoOrientation: photo),
                               ((pi - qi) % 4 + 4) % 4, "packet \(packet) photo \(photo)")
            }
        }
        XCTAssertEqual(QuarterTurn.relativeTurns(packetOrientation: 8, photoOrientation: 1), 3, "the Desktop NEF case: rotate left")
        XCTAssertEqual(QuarterTurn.relativeTurns(packetOrientation: 8, photoOrientation: 8), 0)
        XCTAssertEqual(QuarterTurn.relativeTurns(packetOrientation: 6, photoOrientation: 8), 2)
        XCTAssertNil(QuarterTurn.relativeTurns(packetOrientation: 2, photoOrientation: 1))
        XCTAssertNil(QuarterTurn.relativeTurns(packetOrientation: 1, photoOrientation: 5))
    }

    /// The relative turn, applied on top of the photo's own EXIF turn, shows what the packet's own orientation shows.
    func testRelativeTurnsComposeWithThePhotosOwnOrientationOnARealRender() {
        let raw = quadrantImage()
        for photo in [1, 6, 3, 8] {
            for packet in [1, 6, 3, 8] {
                let shownByApp = raw.oriented(CGImagePropertyOrientation(rawValue: UInt32(photo))!)
                let turns = QuarterTurn.relativeTurns(packetOrientation: packet, photoOrientation: photo)!
                let withEdit = QuarterTurn.apply(turns, to: shownByApp)
                assertSamePixels(withEdit, raw.oriented(CGImagePropertyOrientation(rawValue: UInt32(packet))!), "photo \(photo) packet \(packet)")
            }
        }
    }

    // MARK: - Pipeline stage

    func testPipelineRotatesEachTurnWithExactPixels() {
        let input = quadrantImage()
        let expected = [["red", "green", "blue", "yellow"], ["blue", "red", "yellow", "green"],
                        ["yellow", "blue", "green", "red"], ["green", "yellow", "red", "blue"]]
        for turns in 0..<4 {
            let out = EditPipeline.apply(EditState(rotationQuarterTurns: turns), to: input)
            XCTAssertEqual(quadrants(out), expected[turns], "turns \(turns)")
            XCTAssertEqual(out.extent.size, turns % 2 == 0 ? CGSize(width: 80, height: 40) : CGSize(width: 40, height: 80))
            XCTAssertEqual(out.extent.origin, .zero)
        }
    }

    func testPipelineNormalisesAnOutOfRangeCount() {
        let out = EditPipeline.apply(EditState(rotationQuarterTurns: 5), to: quadrantImage())
        XCTAssertEqual(quadrants(out), ["blue", "red", "yellow", "green"])
    }

    func testCropInsetsApplyInTheRotatedFrame() {
        // After one turn the left half of the rotated picture is blue (top) over yellow (bottom).
        let out = EditPipeline.apply(EditState(rotationQuarterTurns: 1, cropInsetRight: 0.45), to: quadrantImage())
        XCTAssertEqual(out.extent.size, CGSize(width: 22, height: 80), "insets are clamped to 0.45")
        XCTAssertEqual(color(of: out, at: CGPoint(x: 10, y: 60)), "blue")
        XCTAssertEqual(color(of: out, at: CGPoint(x: 10, y: 20)), "yellow")
    }

    func testRotationRunsBeforeStraighten() {
        let input = quadrantImage()
        let both = EditPipeline.apply(EditState(straightenAngle: 10, rotationQuarterTurns: 1), to: input)
        let manual = EditPipeline.apply(EditState(straightenAngle: 10), to: QuarterTurn.apply(1, to: input))
        assertSamePixels(both, manual, "straighten acts on the rotated frame")
    }

    func testRotationRunsBeforeFlip() {
        let input = quadrantImage()
        let both = EditPipeline.apply(EditState(rotationQuarterTurns: 1, flipHorizontal: true), to: input)
        let manual = EditPipeline.apply(EditState(flipHorizontal: true), to: QuarterTurn.apply(1, to: input))
        assertSamePixels(both, manual, "flip acts on the rotated frame")
        XCTAssertEqual(quadrants(both), ["red", "blue", "green", "yellow"])
    }

    func testRotationRunsBeforePerspective() {
        let input = quadrantImage()
        let both = EditPipeline.apply(EditState(verticalPerspective: 0.3, rotationQuarterTurns: 1), to: input)
        let manual = EditPipeline.apply(EditState(verticalPerspective: 0.3), to: QuarterTurn.apply(1, to: input))
        assertSamePixels(both, manual, "perspective acts on the rotated frame")
    }

    func testRotationComposesWithColorAdjustments() {
        let input = quadrantImage()
        let both = EditPipeline.apply(EditState(exposureEV: 0.5, rotationQuarterTurns: 2), to: input)
        let manual = QuarterTurn.apply(2, to: EditPipeline.apply(EditState(exposureEV: 0.5), to: input))
        assertSamePixels(both, manual, "colour stages are unaffected by where the turn sits")
    }

    func testTruncatedSamplingStillAppliesTheRotation() {
        let out = EditPipeline.apply(EditState(rotationQuarterTurns: 1), to: quadrantImage(), truncatingColorAt: .pointColor(index: 0))
        XCTAssertEqual(out.extent.size, CGSize(width: 40, height: 80))
        XCTAssertEqual(quadrants(out), ["blue", "red", "yellow", "green"])
    }

    func testRotationIsProportionalOnADownscaledProxy() {
        let full = quadrantImage(width: 80, height: 40)
        let proxy = full.transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
        let outFull = EditPipeline.apply(EditState(rotationQuarterTurns: 1), to: full)
        let outProxy = EditPipeline.apply(EditState(rotationQuarterTurns: 1), to: proxy)
        XCTAssertEqual(outProxy.extent.width * 2, outFull.extent.width, accuracy: 0.001)
        XCTAssertEqual(outProxy.extent.height * 2, outFull.extent.height, accuracy: 0.001)
        XCTAssertEqual(quadrants(outProxy), quadrants(outFull))
    }

    // MARK: - Subject raster follows

    private func topHalfPNG() throws -> Data {
        let w = 32, h = 32
        var bytes = [UInt8](repeating: 0, count: w * h)
        for y in 0..<(h / 2) { for x in 0..<w { bytes[y * w + x] = 255 } }   // y = 0 is the TOP row
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                                          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let out = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    func testSubjectRasterFollowsTheRotation() throws {
        let gray = CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1, colorSpace: linearSpace)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 400, height: 200))
        let mask = Mask(kind: .subject, exposureEV: 2, subjectMaskPNG: try topHalfPNG(), subjectMaskRevision: 1)
        let out = EditPipeline.apply(EditState(rotationQuarterTurns: 1, masks: [mask]), to: gray)   // 200 x 400; top -> right
        func red(_ fx: Double) -> Float {
            var buffer = [Float](repeating: 0, count: 4)
            context.render(out, toBitmap: &buffer, rowBytes: 16,
                           bounds: CGRect(x: out.extent.width * fx, y: out.extent.height * 0.5, width: 1, height: 1),
                           format: .RGBAf, colorSpace: linearSpace)
            return buffer[0]
        }
        XCTAssertEqual(red(0.9), 0.8, accuracy: 0.01, "the raster's top half is now the right half")
        XCTAssertEqual(red(0.1), 0.2, accuracy: 0.01)
    }

    // MARK: - EditState plumbing

    func testRotationIsAGeometryField() {
        var s = EditState.identity
        s.rotationQuarterTurns = 1
        XCTAssertFalse(s.isGeometryAtIdentity)
        XCTAssertTrue(LightroomMapping.geometryIsActive(s))
        XCTAssertEqual(s.geometryOnlySamplingState().rotationQuarterTurns, 1)
        XCTAssertNotEqual(s, EditState.identity)
    }

    func testCodableRoundTripAndKey() throws {
        var s = EditState.identity
        s.rotationQuarterTurns = 3
        let data = try JSONEncoder().encode(s)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["rotationQuarterTurns"] as? Int, 3, "the CodingKeys entry")
        XCTAssertEqual(try JSONDecoder().decode(EditState.self, from: data).rotationQuarterTurns, 3)
    }

    func testMissingKeyDecodesToZero() throws {
        XCTAssertEqual(try JSONDecoder().decode(EditState.self, from: Data("{}".utf8)).rotationQuarterTurns, 0)
    }

    func testJunkAndOutOfRangeValuesNormaliseWithoutFailingTheSidecar() throws {
        func decode(_ json: String) throws -> EditState { try JSONDecoder().decode(EditState.self, from: Data(json.utf8)) }
        XCTAssertEqual(try decode(#"{"rotationQuarterTurns": "left"}"#).rotationQuarterTurns, 0)
        XCTAssertEqual(try decode(#"{"rotationQuarterTurns": 1.5}"#).rotationQuarterTurns, 0)
        XCTAssertEqual(try decode(#"{"rotationQuarterTurns": null}"#).rotationQuarterTurns, 0)
        XCTAssertEqual(try decode(#"{"rotationQuarterTurns": 6}"#).rotationQuarterTurns, 2)
        XCTAssertEqual(try decode(#"{"rotationQuarterTurns": -1}"#).rotationQuarterTurns, 3)
        let other = try decode(#"{"rotationQuarterTurns": "x", "exposureEV": 0.7}"#)
        XCTAssertEqual(other.exposureEV, 0.7, "the rest of the sidecar survives a junk rotation")
    }

    func testPresetAndPasteDoNotCarryRotation() {
        var preset = EditState.identity
        preset.rotationQuarterTurns = 1
        preset.exposureEV = 0.5
        var target = EditState.identity
        target.rotationQuarterTurns = 2
        let result = preset.applyingPreset(onto: target)
        XCTAssertEqual(result.rotationQuarterTurns, 2, "the target keeps its own rotation")
        XCTAssertEqual(result.exposureEV, 0.5)
        XCTAssertEqual(preset.applyingPreset(onto: .identity).rotationQuarterTurns, 0, "and never receives the preset's")
    }

    func testComparisonOriginalKeepsRotationOnBothSides() {
        var s = EditState.identity
        s.rotationQuarterTurns = 3
        s.exposureEV = 1
        let original = s.comparisonOriginal()
        XCTAssertEqual(original.rotationQuarterTurns, 3)
        XCTAssertEqual(original.exposureEV, 0)
    }

    func testRevertToIdentityClearsRotation() {
        XCTAssertEqual(EditState.identity.rotationQuarterTurns, 0)
        XCTAssertTrue(EditState.identity.isEffectivelyIdentity)
        var s = EditState.identity
        s.rotationQuarterTurns = 1
        XCTAssertFalse(s.isEffectivelyIdentity)
    }

    func testDiffLabelsTheRotationField() {
        var s = EditState.identity
        s.rotationQuarterTurns = 1
        XCTAssertEqual(EditStateDiff.changedFieldNames(from: .identity, to: s), ["rotationQuarterTurns"])
        XCTAssertEqual(EditStateDiff.displayName(forField: "rotationQuarterTurns"), "Rotation Quarter Turns")
    }

    func testRotationAloneDoesNotForceARawRedecode() {
        var s = EditState.identity
        s.rotationQuarterTurns = 1
        XCTAssertFalse(EditState.identity.requiresRawRedecode(comparedTo: s))
    }
}
