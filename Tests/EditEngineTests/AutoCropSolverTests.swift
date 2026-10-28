import CoreImage
import XCTest
@testable import PhotoApp

/// `AutoCropSolver` on hand-built masks (pure), and the whole chain on the REAL pipeline: measure the alpha of a geometry-edited
/// image, apply the solved insets through `EditPipeline.apply`, and require that no output pixel is transparent.
final class AutoCropSolverTests: XCTestCase {
    private func mask(_ rows: [String]) -> AutoCropMask {
        // '#' = valid, '.' = empty; row 0 = top.
        let w = rows[0].count
        return AutoCropMask(width: w, height: rows.count, valid: rows.flatMap { $0.map { $0 == "#" } })
    }

    private func cells(_ insets: AutoCropSolver.Insets, _ m: AutoCropMask) -> (x0: Int, y0: Int, x1: Int, y1: Int) {
        (Int((insets.left * Double(m.width)).rounded()), Int((insets.top * Double(m.height)).rounded()),
         m.width - Int((insets.right * Double(m.width)).rounded()), m.height - Int((insets.bottom * Double(m.height)).rounded()))
    }

    // MARK: Pure solver

    func testAnAllValidMaskNeedsNoCrop() {
        let m = AutoCropMask(width: 10, height: 8, valid: [Bool](repeating: true, count: 80))
        XCTAssertEqual(AutoCropSolver.solve(m), .nothingToCrop)
    }

    func testAnAllEmptyOrMismatchedMaskIsEmpty() {
        XCTAssertEqual(AutoCropSolver.solve(AutoCropMask(width: 4, height: 4, valid: [Bool](repeating: false, count: 16))), .empty)
        XCTAssertEqual(AutoCropSolver.solve(AutoCropMask(width: 4, height: 4, valid: [true, true])), .empty)
        XCTAssertEqual(AutoCropSolver.solve(AutoCropMask(width: 0, height: 0, valid: [])), .empty)
    }

    func testAnEmptyCornerIsCroppedAwayWithAOneCellMarginAndNoneAtTheFrameEdge() throws {
        // Empty top-left 4x4 corner in a 20x20 frame.
        var valid = [Bool](repeating: true, count: 400)
        for y in 0..<4 { for x in 0..<4 { valid[y * 20 + x] = false } }
        let m = AutoCropMask(width: 20, height: 20, valid: valid)
        guard case .cropped(let insets) = AutoCropSolver.solve(m) else { return XCTFail("expected a crop") }
        let r = cells(insets, m)
        // Either the top 4 rows or the left 4 columns go; the touched side is 4 + 1 (erosion) + 1 (margin) = 6 cells in, the other sides stay at the frame edge.
        let trimsTop = r.y0 > 0, trimsLeft = r.x0 > 0
        XCTAssertTrue(trimsTop != trimsLeft, "one side only: \(r)")
        XCTAssertEqual(trimsTop ? r.y0 : r.x0, 6)
        XCTAssertEqual(r.x1, 20)
        XCTAssertEqual(r.y1, 20)
    }

    func testTheFrameEdgeSidesCarryNoMargin() throws {
        // Valid block in the middle columns of every row: the empty bands touch left and right.
        let rows = [String](repeating: "...######...", count: 6)
        let m = mask(rows)
        guard case .cropped(let insets) = AutoCropSolver.solve(m) else { return XCTFail("expected a crop") }
        XCTAssertEqual(insets.top, 0)
        XCTAssertEqual(insets.bottom, 0)
        let r = cells(insets, m)
        XCTAssertEqual(r.x0, 5, "valid 3...8, eroded 4...7, margin 5...7")
        XCTAssertEqual(r.x1, 7)
    }

    func testResultNeverContainsAnEmptyCellAndIsMaximalAgainstBruteForce() {
        var rng = SystemRandomNumberGenerator()
        var checked = 0
        for _ in 0..<400 {
            let w = Int.random(in: 6...10, using: &rng), h = Int.random(in: 6...10, using: &rng)
            var valid = [Bool](repeating: true, count: w * h)
            for _ in 0..<Int.random(in: 1...2, using: &rng) { valid[Int.random(in: 0..<(w * h), using: &rng)] = false }
            let m = AutoCropMask(width: w, height: h, valid: valid)
            guard case .cropped(let insets) = AutoCropSolver.solve(m) else { continue }
            let r = cells(insets, m)
            for y in r.y0..<r.y1 { for x in r.x0..<r.x1 { XCTAssertTrue(valid[y * w + x], "empty cell inside the crop") } }
            // Brute force: the largest all-valid rectangle of ERODED cells (the solver then shrinks it by the margin, so compare the
            // rectangle with the margin added back: a side that is not at the frame edge was shrunk by one cell).
            func ok(_ x: Int, _ y: Int) -> Bool {
                guard valid[y * w + x] else { return false }
                return (x == 0 || valid[y * w + x - 1]) && (x == w - 1 || valid[y * w + x + 1])
                    && (y == 0 || valid[(y - 1) * w + x]) && (y == h - 1 || valid[(y + 1) * w + x])
            }
            var best = 0
            for y0 in 0..<h { for y1 in (y0 + 1)...h { for x0 in 0..<w { for x1 in (x0 + 1)...w {
                var all = true
                outer: for y in y0..<y1 { for x in x0..<x1 where !ok(x, y) { all = false; break outer } }
                if all { best = max(best, (x1 - x0) * (y1 - y0)) }
            } } } }
            let ex0 = r.x0 > 0 ? r.x0 - 1 : 0, ey0 = r.y0 > 0 ? r.y0 - 1 : 0, ex1 = r.x1 < w ? r.x1 + 1 : w, ey1 = r.y1 < h ? r.y1 + 1 : h
            XCTAssertEqual((ex1 - ex0) * (ey1 - ey0), best, "not maximal on \(w)x\(h)")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 25, "the random masks must mostly produce a crop")
    }

    func testAnInsetAboveTheCropLimitIsRefused() {
        // Valid core is only the middle 2 of 10 columns.
        let m = mask([String](repeating: "....##....", count: 10))
        XCTAssertEqual(AutoCropSolver.solve(m), .empty, "the 1-cell erosion and margin leave nothing of a 2-cell core")
        // Valid columns 12...19 of 20, flush right: erosion + margin start the crop at column 14 (inset 0.7).
        let flushRight = mask([String](repeating: "............########", count: 20))
        XCTAssertEqual(AutoCropSolver.solve(flushRight), .tooLarge)
        // Just inside the limit: valid from column 8 (crop starts at 10: inset 0.5 is still above 0.45) vs column 5 (starts at 7: 0.35).
        let ok = mask([String](repeating: ".....###############", count: 20))
        guard case .cropped(let insets) = AutoCropSolver.solve(ok) else { return XCTFail("a 0.35 inset is allowed") }
        XCTAssertEqual(insets.left, 0.35, accuracy: 1e-12)
    }

    func testALockedAspectRatioIsFittedCentredInsideTheFoundRectangle() throws {
        var valid = [Bool](repeating: true, count: 400)
        for y in 0..<4 { for x in 0..<4 { valid[y * 20 + x] = false } }
        let m = AutoCropMask(width: 20, height: 20, valid: valid)
        guard case .cropped(let free) = AutoCropSolver.solve(m) else { return XCTFail() }
        guard case .cropped(let locked) = AutoCropSolver.solve(m, aspectRatio: 2) else { return XCTFail() }
        let w = (1 - locked.left - locked.right) * 20, h = (1 - locked.top - locked.bottom) * 20
        XCTAssertEqual(w / h, 2, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(locked.top, free.top - 1e-12)
        XCTAssertGreaterThanOrEqual(locked.bottom, free.bottom - 1e-12)
        XCTAssertGreaterThanOrEqual(locked.left, free.left - 1e-12)
        XCTAssertGreaterThanOrEqual(locked.right, free.right - 1e-12)
    }

    func testALockedRatioThatNeedsAHugeCropIsRefused() {
        let m = mask([String](repeating: "...#########...", count: 14))
        guard case .cropped = AutoCropSolver.solve(m) else { return XCTFail("free crop exists") }
        XCTAssertEqual(AutoCropSolver.solve(m, aspectRatio: 0.1), .tooLarge)
    }

    // MARK: Real pipeline, end to end

    /// Pixels with alpha < 1, ignoring the outermost ring: a crop at a fractional position gives the border pixels partial coverage
    /// for EVERY crop (existing behaviour, not something a geometry wedge causes), while a wedge shows up as a run of pixels
    /// well inside the frame.
    private static func transparentInteriorPixels(_ bytes: [UInt8], _ w: Int, _ h: Int) -> [Int] {
        var out: [Int] = []
        for y in 1..<max(1, h - 1) { for x in 1..<max(1, w - 1) where bytes[(y * w + x) * 4 + 3] < 255 { out.append(y * w + x) } }
        return out
    }

    /// A flat opaque picture, edited by `edit`, measured and cropped; the output of the cropped pipeline must have NO transparent pixel.
    private func assertCropClearsAllEmptyPixels(
        _ name: String, width: Int = 400, height: Int = 300, minArea: Double,
        aspectRatio: Double? = nil, file: StaticString = #filePath, line: UInt = #line, edit: (inout EditState) -> Void
    ) throws {
        let image = CIImage(color: CIColor(red: 0.5, green: 0.4, blue: 0.3, alpha: 1)).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        var state = EditState()
        edit(&state)
        state.cropInsetLeft = 0.2 // an existing crop must be ignored by the measurement
        let measured = try XCTUnwrap(AutoCropMaskRenderer.mask(of: EditPipeline.apply(AutoCropMaskRenderer.measuringState(for: state), to: image)), file: file, line: line)
        XCTAssertTrue(measured.valid.contains(false), "\(name): the geometry must reveal empty pixels for this test to mean anything", file: file, line: line)
        guard case .cropped(let insets) = AutoCropSolver.solve(measured, aspectRatio: aspectRatio) else {
            return XCTFail("\(name): expected a crop", file: file, line: line)
        }
        state.cropInsetTop = insets.top; state.cropInsetBottom = insets.bottom
        state.cropInsetLeft = insets.left; state.cropInsetRight = insets.right
        let output = EditPipeline.apply(state, to: image)
        let extent = output.extent.integral
        let w = Int(extent.width), h = Int(extent.height)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        CIContext().render(output, toBitmap: &bytes, rowBytes: w * 4, bounds: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        let transparent = Self.transparentInteriorPixels(bytes, w, h).count
        XCTAssertEqual(transparent, 0, "\(name): \(transparent) transparent pixels remain", file: file, line: line)
        let keptArea = (1 - insets.left - insets.right) * (1 - insets.top - insets.bottom)
        XCTAssertGreaterThan(keptArea, minArea, "\(name): the crop is trivially small", file: file, line: line)
        XCTAssertLessThan(keptArea, 1, file: file, line: line)
    }

    func testStraightenTenDegrees() throws { try assertCropClearsAllEmptyPixels("straighten", minArea: 0.4) { $0.straightenAngle = 10 } }
    func testNegativeStraighten() throws { try assertCropClearsAllEmptyPixels("straighten-", minArea: 0.4) { $0.straightenAngle = -7 } }
    func testPerspective() throws {
        try assertCropClearsAllEmptyPixels("perspective", minArea: 0.3) { $0.verticalPerspective = 0.3; $0.horizontalPerspective = -0.2 }
    }
    func testTransformScaleBelowOne() throws { try assertCropClearsAllEmptyPixels("scale", minArea: 0.4) { $0.transformScale = 0.8 } }
    func testQuarterTurnPlusStraighten() throws {
        try assertCropClearsAllEmptyPixels("quarter+straighten", minArea: 0.4) { $0.rotationQuarterTurns = 1; $0.straightenAngle = 8 }
    }
    func testFlipPlusStraighten() throws {
        try assertCropClearsAllEmptyPixels("flip", minArea: 0.4) { $0.flipHorizontal = true; $0.straightenAngle = 6 }
    }
    func testLockedSixteenByNineOnAStraightenedPicture() throws {
        try assertCropClearsAllEmptyPixels("16:9", minArea: 0.3, aspectRatio: 16.0 / 9.0) { $0.straightenAngle = 5 }
    }

    func testPartiallyTransparentPixelsCountAsEmpty() throws {
        let opaque = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 20, height: 20))
        // A pure half-alpha picture: no pixel is opaque.
        let halfOnly = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        let hm = try XCTUnwrap(AutoCropMaskRenderer.mask(of: halfOnly))
        XCTAssertFalse(hm.valid.contains(true), "alpha 0.5 is not opaque")
        let full = try XCTUnwrap(AutoCropMaskRenderer.mask(of: opaque))
        XCTAssertFalse(full.valid.contains(false))
    }

    func testACropThatOnlyTrimsTheRightKeepsTheLeftAtTheFrameEdge() {
        let m = mask([String](repeating: "#########...", count: 12))
        guard case .cropped(let insets) = AutoCropSolver.solve(m) else { return XCTFail() }
        XCTAssertEqual(insets.left, 0, "no margin on a side that already sits on the frame edge")
        XCTAssertEqual(insets.top, 0)
        XCTAssertEqual(insets.bottom, 0)
        XCTAssertGreaterThan(insets.right, 0)
    }

    func testAnUntouchedPictureNeedsNoCrop() throws {
        let image = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 120, height: 80))
        let measured = try XCTUnwrap(AutoCropMaskRenderer.mask(of: EditPipeline.apply(AutoCropMaskRenderer.measuringState(for: EditState()), to: image)))
        XCTAssertEqual(AutoCropSolver.solve(measured), .nothingToCrop)
    }

    func testMeasuringStateKeepsGeometryAndDropsTheCropAndEverythingElse() {
        var s = EditState()
        s.straightenAngle = 3; s.flipVertical = true; s.cropInsetTop = 0.2; s.exposureEV = 1
        let m = AutoCropMaskRenderer.measuringState(for: s)
        XCTAssertEqual(m.straightenAngle, 3)
        XCTAssertTrue(m.flipVertical)
        XCTAssertEqual(m.cropInsetTop, 0)
        XCTAssertEqual(m.exposureEV, 0)
    }

    func testMeasuringAProxyOfALargeSourceGivesTheSameFramingAsTheSmallOne() async throws {
        let big = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 3200, height: 2400))
        var state = EditState()
        state.straightenAngle = 9
        let measuredOptional = await AutoCropMaskRenderer.measure(image: big, state: state)
        let measured = try XCTUnwrap(measuredOptional)
        XCTAssertLessThanOrEqual(max(measured.width, measured.height), 1000, "measured on a proxy, not at 3200 px")
        guard case .cropped(let insets) = AutoCropSolver.solve(measured) else { return XCTFail() }
        // The same insets applied at full resolution leave no transparent pixel.
        state.cropInsetTop = insets.top; state.cropInsetBottom = insets.bottom; state.cropInsetLeft = insets.left; state.cropInsetRight = insets.right
        let output = EditPipeline.apply(state, to: big)
        let extent = output.extent.integral
        let w = Int(extent.width), h = Int(extent.height)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        CIContext().render(output, toBitmap: &bytes, rowBytes: w * 4, bounds: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        let bad = Self.transparentInteriorPixels(bytes, w, h)
        XCTAssertEqual(bad.count, 0)
    }
}
