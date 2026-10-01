import XCTest
@testable import PhotoApp

final class CubeLUTTests: XCTestCase {
    private let accuracy: Float = 1e-5

    // MARK: Cube basics

    func testIdentityCubeSamplesToItsInput() throws {
        let cube = try XCTUnwrap(CubeLUT.identity(size: 9))
        for rgb in [SIMD3<Float>(0, 0, 0), SIMD3(1, 1, 1), SIMD3(0.5, 0.25, 0.75), SIMD3(0.123, 0.456, 0.789)] {
            let out = cube.sample(rgb)
            XCTAssertEqual(out.x, rgb.x, accuracy: accuracy)
            XCTAssertEqual(out.y, rgb.y, accuracy: accuracy)
            XCTAssertEqual(out.z, rgb.z, accuracy: accuracy)
        }
    }

    func testCubeRejectsBadSizesAndTableLengths() {
        XCTAssertNil(CubeLUT.identity(size: 1))
        XCTAssertNil(CubeLUT.identity(size: 66))
        XCTAssertNil(CubeLUT(size: 2, table: [Float](repeating: 0, count: 31)))
        XCTAssertNotNil(CubeLUT(size: 2, table: [Float](repeating: 0, count: 32)))
    }

    func testDataIsFloat32RGBAInLatticeOrder() throws {
        let cube = try XCTUnwrap(CubeLUT.identity(size: 2))
        XCTAssertEqual(cube.data.count, 2 * 2 * 2 * 4 * MemoryLayout<Float>.size)
        // Red varies fastest: entry 1 is (1, 0, 0), entry 2 is (0, 1, 0), entry 4 is (0, 0, 1).
        XCTAssertEqual(Array(cube.table[4..<8]), [1, 0, 0, 1])
        XCTAssertEqual(Array(cube.table[8..<12]), [0, 1, 0, 1])
        XCTAssertEqual(Array(cube.table[16..<20]), [0, 0, 1, 1])
    }

    func testBuildClampsOutputs() throws {
        let cube = try XCTUnwrap(CubeLUT.build(size: 3) { $0 * 3 - 1 })
        XCTAssertTrue(cube.table.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    // MARK: Parser

    private func identityText(size: Int, header: String = "") -> String {
        var lines = [header, "LUT_3D_SIZE \(size)"]
        for b in 0..<size { for g in 0..<size { for r in 0..<size {
            let d = Float(size - 1)
            lines.append("\(Float(r) / d) \(Float(g) / d) \(Float(b) / d)")
        } } }
        return lines.joined(separator: "\n")
    }

    private func parse(_ text: String) throws -> CubeLUT {
        switch CubeLUTParser.parse(text) {
        case .success(let cube): return cube
        case .failure(let error): throw error
        }
    }

    private func failure(_ text: String) -> CubeLUTError? {
        if case .failure(let error) = CubeLUTParser.parse(text) { return error }
        return nil
    }

    func testParsesAnIdentityCubeWithTitleCommentsAndBlankLines() throws {
        let text = "# made by a test\n\nTITLE \"My Look\"\n" + identityText(size: 3) + "\n\n"
        let cube = try parse(text)
        XCTAssertEqual(cube.size, 3)
        XCTAssertEqual(cube.title, "My Look")
        XCTAssertEqual(cube, CubeLUT.identity(size: 3).map { var c = $0; c.title = "My Look"; return c })
    }

    func testParsesCRLFAndTabs() throws {
        let text = identityText(size: 2).replacingOccurrences(of: "\n", with: "\r\n").replacingOccurrences(of: " ", with: "\t")
        XCTAssertEqual(try parse(text).size, 2)
    }

    func testRejectsEmptyAndHeaderOnlyFiles() {
        XCTAssertEqual(failure(""), .empty)
        XCTAssertEqual(failure("# only a comment\n\n"), .empty)
        XCTAssertEqual(failure("TITLE x\n"), .missingSize)
    }

    func testRejectsOneDimensionalAndUnsupportedSizes() {
        XCTAssertEqual(failure("LUT_1D_SIZE 16\n0 0 0\n"), .oneDimensional)
        XCTAssertEqual(failure("LUT_3D_SIZE 1\n0 0 0\n"), .unsupportedSize(1))
        XCTAssertEqual(failure("LUT_3D_SIZE 66\n"), .unsupportedSize(66))
    }

    func testRejectsWrongEntryCounts() {
        let short = identityText(size: 2).split(separator: "\n").dropLast().joined(separator: "\n")
        XCTAssertEqual(failure(short), .wrongEntryCount(expected: 8, found: 7))
        XCTAssertEqual(failure(identityText(size: 2) + "\n0 0 0"), .wrongEntryCount(expected: 8, found: 9))
    }

    func testRejectsASecondSizeLineAndReportsTheRealEntryCount() {
        XCTAssertEqual(failure("LUT_3D_SIZE 2\n" + String(repeating: "0 0 0\n", count: 8) + "LUT_3D_SIZE 3\n" + String(repeating: "0 0 0\n", count: 19)), .malformedLine(10))
        XCTAssertEqual(failure(identityText(size: 2) + "\n0 0 0\n0 0 0"), .wrongEntryCount(expected: 8, found: 10))
    }

    func testStripsAByteOrderMarkAndHandlesResolveInputRange() throws {
        XCTAssertEqual(try parse("\u{FEFF}" + identityText(size: 2)).size, 2)
        XCTAssertEqual(try parse(identityText(size: 2, header: "LUT_3D_INPUT_RANGE 0 1")).size, 2)
        XCTAssertEqual(failure(identityText(size: 2, header: "LUT_3D_INPUT_RANGE 0 2")), .unsupportedDomain)
    }

    func testLibraryRefusesToRegisterUnderTheBuiltInPrefix() throws {
        let library = LookLibrary()
        library.register(.init(id: "builtin:fake", name: "Fake", cube: try XCTUnwrap(CubeLUT.identity(size: 2))))
        XCTAssertTrue(library.userLooks.isEmpty)
    }

    func testRejectsMalformedAndNonFiniteEntries() {
        XCTAssertEqual(failure("LUT_3D_SIZE 2\n0 0\n"), .malformedLine(2))
        XCTAssertEqual(failure("LUT_3D_SIZE 2\n0 0 abc\n"), .malformedLine(2))
        XCTAssertEqual(failure("LUT_3D_SIZE 2\n0 nan 0\n"), .nonFiniteValue(line: 2))
        XCTAssertEqual(failure("LUT_3D_SIZE 2\n0 inf 0\n"), .nonFiniteValue(line: 2))
        XCTAssertEqual(failure("0 0 0\nLUT_3D_SIZE 2\n"), .missingSize)
        XCTAssertEqual(failure("WHAT 1\n"), .malformedLine(1))
    }

    func testDomainOtherThanZeroToOneIsRejectedButDefaultDomainAccepted() throws {
        XCTAssertEqual(failure(identityText(size: 2, header: "DOMAIN_MIN 0 0 0\nDOMAIN_MAX 2 2 2")), .unsupportedDomain)
        XCTAssertEqual(failure(identityText(size: 2, header: "DOMAIN_MIN -1 0 0")), .unsupportedDomain)
        XCTAssertEqual(try parse(identityText(size: 2, header: "DOMAIN_MIN 0 0 0\nDOMAIN_MAX 1 1 1")).size, 2)
    }

    func testOutOfRangeValuesClampAndOversizedTextIsRejected() throws {
        let cube = try parse("LUT_3D_SIZE 2\n" + String(repeating: "1.5 -0.5 0.5\n", count: 8))
        XCTAssertEqual(Array(cube.table[0..<4]), [1, 0, 0.5, 1])
        XCTAssertEqual(failure(String(repeating: "#", count: CubeLUTParser.maximumBytes + 1)), .tooLarge)
    }

    func testParsedBuiltInRoundTripsThroughCubeText() throws {
        let original = try XCTUnwrap(BuiltInLooks.cube(id: "builtin:teal-orange"))
        var lines = ["TITLE \"Teal & Orange\"", "LUT_3D_SIZE \(original.size)"]
        for i in stride(from: 0, to: original.table.count, by: 4) {
            lines.append("\(original.table[i]) \(original.table[i + 1]) \(original.table[i + 2])")
        }
        let parsed = try parse(lines.joined(separator: "\n"))
        XCTAssertEqual(parsed.size, original.size)
        XCTAssertEqual(parsed.table, original.table)
    }

    // MARK: Built-in looks

    private func gray(_ look: String, _ v: Float) throws -> SIMD3<Float> {
        try XCTUnwrap(BuiltInLooks.cube(id: look)).sample(SIMD3(repeating: v))
    }

    func testBuiltInIDsAreUniqueStableAndPrefixed() {
        let ids = BuiltInLooks.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertTrue(ids.allSatisfy { $0.hasPrefix("builtin:") })
        XCTAssertEqual(ids.count, 10)
        XCTAssertEqual(
            Set(ids),
            ["builtin:warm-film", "builtin:cool-fade", "builtin:teal-orange", "builtin:bleach-bypass", "builtin:faded-matte",
             "builtin:noir", "builtin:sepia", "builtin:cross-process", "builtin:vivid", "builtin:soft-portrait"],
            "ids are persisted in sidecars: renaming one orphans every photo using it")
    }

    func testEveryBuiltInIsDeterministicFiniteAndInRange() throws {
        for look in BuiltInLooks.all {
            let a = try XCTUnwrap(BuiltInLooks.cube(id: look.id))
            let b = try XCTUnwrap(CubeLUT.build(size: BuiltInLooks.cubeSize, title: look.name, look.transform))
            XCTAssertEqual(a.table, b.table, look.id)
            XCTAssertEqual(a.size, 33)
            XCTAssertTrue(a.table.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }, look.id)
        }
    }

    func testEveryBuiltInChangesTheImageAndIsMonotonicAlongTheGrayRamp() throws {
        for look in BuiltInLooks.all {
            let cube = try XCTUnwrap(BuiltInLooks.cube(id: look.id))
            var previous = SIMD3<Float>(repeating: -1)
            var moved = false
            for i in 0...32 {
                let v = Float(i) / 32
                let out = cube.sample(SIMD3(repeating: v))
                for (channel, before) in [(out.x, previous.x), (out.y, previous.y), (out.z, previous.z)] {
                    XCTAssertGreaterThanOrEqual(channel, before - 1e-4, "\(look.id) is not monotonic at \(v)")
                }
                if abs(out.x - v) + abs(out.y - v) + abs(out.z - v) > 0.01 { moved = true }
                previous = out
            }
            XCTAssertTrue(moved, "\(look.id) must not be the identity")
        }
    }

    /// A per-channel gain above 1 hard-clips that channel's highlights flat; every look must still separate
    /// 0.95 from 1.0 in EVERY channel (the plain monotonic test allows equality and missed this).
    func testNoBuiltInFlattensItsHighlights() throws {
        for look in BuiltInLooks.all {
            // The look's own function, not its 33-point cube: lattice interpolation spreads a clip that
            // starts within one cell (e.g. at 0.943) and hides it (measured: the cube-based version of
            // this test passed with the Warm Film clip reinstated).
            // Clamped to 0...1 exactly as `CubeLUT.build` does, so a channel that overshoots 1 shows as flat.
            func clamped(_ v: Float) -> SIMD3<Float> {
                let c = look.transform(SIMD3(repeating: v))
                return SIMD3(min(max(c.x, 0), 1), min(max(c.y, 0), 1), min(max(c.z, 0), 1))
            }
            let a = clamped(0.95), b = clamped(1.0)
            XCTAssertGreaterThan(b.x - a.x, 0.001, "\(look.id) red clips near white")
            XCTAssertGreaterThan(b.y - a.y, 0.001, "\(look.id) green clips near white")
            XCTAssertGreaterThan(b.z - a.z, 0.001, "\(look.id) blue clips near white")
        }
    }

    /// The gray ramp can hide a clipped channel (the other two keep the luma moving); sweeping ONE channel
    /// toward its maximum with the others fixed exposes it: the output channel must keep rising.
    func testNoBuiltInClipsASingleChannelNearItsMaximum() throws {
        for look in BuiltInLooks.all {
            for axis in 0..<3 {
                func out(_ v: Float) -> Float {
                    var rgb = SIMD3<Float>(repeating: 0.5)
                    rgb[axis] = v
                    return min(max(look.transform(rgb)[axis], 0), 1)
                }
                XCTAssertGreaterThan(out(1.0) - out(0.95), 0.001, "\(look.id) channel \(axis) flattens near its maximum")
            }
        }
    }

    func testFitGamutKeepsHueAndLumaAndPullsChannelsIntoRange() {
        let over = BuiltInLooks.fitGamut(SIMD3(1.3, 0.2, 0.1))
        XCTAssertLessThanOrEqual(max(over.x, max(over.y, over.z)), 1 + 1e-5)
        XCTAssertEqual(BuiltInLooks.luma(over), BuiltInLooks.luma(SIMD3(1.3, 0.2, 0.1)), accuracy: 1e-4)
        let under = BuiltInLooks.fitGamut(SIMD3(0.9, 0.3, -0.2))
        XCTAssertGreaterThanOrEqual(min(under.x, min(under.y, under.z)), -1e-5)
        XCTAssertEqual(BuiltInLooks.fitGamut(SIMD3(0.4, 0.5, 0.6)), SIMD3(0.4, 0.5, 0.6), "in-gamut colors are untouched")
    }

    func testSaturateNeverLeavesTheGamut() {
        for amount: Float in [0.0, 0.5, 1.0, 1.5, 2.5] {
            for c in [SIMD3<Float>(1, 0, 0), SIMD3(0, 0, 1), SIMD3(0.9, 0.2, 0.1), SIMD3(0.1, 0.9, 0.5)] {
                let out = BuiltInLooks.saturate(c, amount)
                XCTAssertLessThanOrEqual(max(out.x, max(out.y, out.z)), 1 + 1e-5, "\(c) x \(amount)")
                XCTAssertGreaterThanOrEqual(min(out.x, min(out.y, out.z)), -1e-5, "\(c) x \(amount)")
            }
        }
    }

    func testSampleToleratesNonFiniteInput() throws {
        let cube = try XCTUnwrap(CubeLUT.identity(size: 4))
        XCTAssertEqual(cube.sample(SIMD3(.nan, .infinity, -.infinity)), SIMD3<Float>(0, 1, 0), "NaN -> 0, +inf clamps to 1, -inf to 0")
    }

    func testBuiltInsMoveMidGrayInTheirDefiningDirection() throws {
        let sepia = try gray("builtin:sepia", 0.5)
        XCTAssertTrue(sepia.x > sepia.y && sepia.y > sepia.z, "sepia is warm: r > g > b")
        let noir = try gray("builtin:noir", 0.5)
        XCTAssertEqual(noir.x, noir.y, accuracy: 1e-4)
        XCTAssertEqual(noir.y, noir.z, accuracy: 1e-4)
        let warm = try gray("builtin:warm-film", 0.5)
        XCTAssertGreaterThan(warm.x, warm.z)
        let cool = try gray("builtin:cool-fade", 0.5)
        XCTAssertGreaterThan(cool.z, cool.x)
        XCTAssertGreaterThan(try gray("builtin:faded-matte", 0).x, 0.05, "matte lifts the blacks")
        XCTAssertGreaterThan(try gray("builtin:cool-fade", 0).x, 0.03, "fade lifts the blacks")
        let tealShadow = try gray("builtin:teal-orange", 0.1), orangeHighlight = try gray("builtin:teal-orange", 0.9)
        XCTAssertGreaterThan(tealShadow.z, tealShadow.x, "shadows lean teal")
        XCTAssertGreaterThan(orangeHighlight.x, orangeHighlight.z, "highlights lean orange")
    }

    func testSaturationLooksChangeChromaTheRightWay() throws {
        let colorful = SIMD3<Float>(0.8, 0.3, 0.2)
        func chroma(_ c: SIMD3<Float>) -> Float { max(c.x, max(c.y, c.z)) - min(c.x, min(c.y, c.z)) }
        let vivid = try XCTUnwrap(BuiltInLooks.cube(id: "builtin:vivid")).sample(colorful)
        let bleach = try XCTUnwrap(BuiltInLooks.cube(id: "builtin:bleach-bypass")).sample(colorful)
        XCTAssertGreaterThan(chroma(vivid), chroma(colorful))
        XCTAssertLessThan(chroma(bleach), chroma(colorful))
    }

    // MARK: Library

    func testLibraryResolvesBuiltInsUserLooksAndUnknownIDs() throws {
        let library = LookLibrary()
        XCTAssertNotNil(library.cube(for: "builtin:vivid"))
        XCTAssertNil(library.cube(for: ""))
        XCTAssertNil(library.cube(for: "builtin:does-not-exist"))
        XCTAssertNil(library.cube(for: "user:abc-Mine"))
        let cube = try XCTUnwrap(CubeLUT.identity(size: 5))
        library.register(.init(id: "user:abc-Mine", name: "Mine", cube: cube))
        XCTAssertEqual(library.cube(for: "user:abc-Mine"), cube)
        XCTAssertEqual(library.displayName(for: "user:abc-Mine"), "Mine")
        XCTAssertEqual(library.displayName(for: "builtin:noir"), "Noir")
        XCTAssertEqual(library.userLooks.map(\.id), ["user:abc-Mine"])
        library.unregister(id: "user:abc-Mine")
        XCTAssertNil(library.cube(for: "user:abc-Mine"))
        XCTAssertTrue(library.userLooks.isEmpty)
    }

    func testLibraryUserLooksAreSortedByNameCaseInsensitively() throws {
        let library = LookLibrary()
        let cube = try XCTUnwrap(CubeLUT.identity(size: 2))
        for name in ["beta", "Alpha", "gamma"] { library.register(.init(id: "user:\(name)", name: name, cube: cube)) }
        XCTAssertEqual(library.userLooks.map(\.name), ["Alpha", "beta", "gamma"])
        library.removeAllUserLooks()
        XCTAssertTrue(library.userLooks.isEmpty)
    }
}
