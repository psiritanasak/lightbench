import XCTest
import CoreImage
@testable import PhotoApp

/// `PhotoExporter` reads real files (the source photo, its sidecar JSON)
/// and writes real files (the export output), so — like
/// `ThumbnailGeneratorTests` — these tests work against a real temp
/// directory rather than pure in-memory fixtures.
final class PhotoExporterTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoExporterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func solidColorImage(size: Int) -> CIImage {
        CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
    }

    /// Writes a solid-color square JPEG of `size`x`size` pixels and
    /// returns its URL, mirroring `ThumbnailGeneratorTests`' PNG-writing
    /// helper but as a JPEG (a more realistic "source photo" format).
    private func writeSolidColorJPEG(size: Int, named name: String = "source.jpg") throws -> URL {
        let context = CIContext()
        let url = tempDir.appendingPathComponent(name)
        try context.writeJPEGRepresentation(
            of: solidColorImage(size: size),
            to: url,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return url
    }

    private func readPixelSize(of url: URL) throws -> (width: Int, height: Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth as String] as? Int)
        let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight as String] as? Int)
        return (width, height)
    }

    // MARK: - resized

    func testResizedScalesDownToFitMaxLongEdge() {
        let image = solidColorImage(size: 800)

        let resized = PhotoExporter.resized(image, option: .maxLongEdge(200))

        XCTAssertEqual(max(resized.extent.width, resized.extent.height), 200, accuracy: 0.5)
    }

    func testResizedDoesNotUpscaleBeyondSourceSize() {
        let image = solidColorImage(size: 50)

        let resized = PhotoExporter.resized(image, option: .maxLongEdge(200))

        XCTAssertEqual(resized.extent.size, image.extent.size)
    }

    func testResizedOriginalLeavesImageUnchanged() {
        let image = solidColorImage(size: 800)

        let resized = PhotoExporter.resized(image, option: .original)

        XCTAssertEqual(resized.extent.size, image.extent.size)
    }

    func testResizedTreatsZeroMaxLongEdgeAsNoOp() {
        let image = solidColorImage(size: 800)

        let resized = PhotoExporter.resized(image, option: .maxLongEdge(0))

        XCTAssertEqual(resized.extent.size, image.extent.size)
    }

    func testResizedTreatsNegativeMaxLongEdgeAsNoOp() {
        let image = solidColorImage(size: 800)

        let resized = PhotoExporter.resized(image, option: .maxLongEdge(-100))

        XCTAssertEqual(resized.extent.size, image.extent.size)
    }

    // MARK: - uniqueDestinationURL

    private func makePhoto(filename: String) -> Photo {
        Photo(id: 1, path: "/tmp/\(filename)", filename: filename, fileSize: nil, importedAt: Date())
    }

    func testUniqueDestinationURLUsesPlainNameWhenNoCollision() {
        let url = PhotoExporter.uniqueDestinationURL(for: makePhoto(filename: "IMG_0001.jpg"), in: tempDir, format: .jpeg)
        XCTAssertEqual(url.lastPathComponent, "IMG_0001.jpg")
    }

    func testUniqueDestinationURLAddsSuffixOnCollision() throws {
        let existing = tempDir.appendingPathComponent("IMG_0001.jpg")
        FileManager.default.createFile(atPath: existing.path, contents: Data())

        let url = PhotoExporter.uniqueDestinationURL(for: makePhoto(filename: "IMG_0001.jpg"), in: tempDir, format: .jpeg)

        XCTAssertEqual(url.lastPathComponent, "IMG_0001 (2).jpg")
    }

    func testUniqueDestinationURLIncrementsSuffixPastMultipleCollisions() throws {
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("IMG_0001.jpg").path, contents: Data())
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("IMG_0001 (2).jpg").path, contents: Data())

        let url = PhotoExporter.uniqueDestinationURL(for: makePhoto(filename: "IMG_0001.jpg"), in: tempDir, format: .jpeg)

        XCTAssertEqual(url.lastPathComponent, "IMG_0001 (3).jpg")
    }

    func testUniqueDestinationURLUsesTheRequestedFormatExtension() {
        let url = PhotoExporter.uniqueDestinationURL(for: makePhoto(filename: "IMG_0001.jpg"), in: tempDir, format: .png)
        XCTAssertEqual(url.lastPathComponent, "IMG_0001.png")
    }

    /// Added alongside `uniqueFileURL`'s own extraction (shared with
    /// `PhotoEnhancer`): a candidate whose FILE doesn't exist, but whose
    /// SIDECAR does (an orphan left behind by an earlier, since-deleted
    /// export/enhance at that name), must still be treated as taken —
    /// otherwise the next write at that name would silently inherit the
    /// orphan's stale edits.
    func testUniqueDestinationURLSkipsACandidateWithOnlyAnOrphanedSidecar() throws {
        let candidate = tempDir.appendingPathComponent("IMG_0001.jpg")
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.path))
        let orphanSidecar = SidecarStore.sidecarURL(for: candidate)
        try JSONEncoder().encode(EditState()).write(to: orphanSidecar)

        let url = PhotoExporter.uniqueDestinationURL(for: makePhoto(filename: "IMG_0001.jpg"), in: tempDir, format: .jpeg)

        XCTAssertEqual(url.lastPathComponent, "IMG_0001 (2).jpg")
    }

    /// An orphan `<base>.xmp` (no photo with that base name next to it) would be inherited by the new file, so the name counts as taken;
    /// but an `.xmp` that a RAW sibling legitimately owns does not make the name taken.
    func testUniqueFileURLSkipsAnOrphanXMPButNotOneASiblingPhotoOwns() throws {
        try Data("<x/>".utf8).write(to: tempDir.appendingPathComponent("orphan.xmp"))
        XCTAssertEqual(PhotoExporter.uniqueFileURL(baseName: "orphan", fileExtension: "jpg", in: tempDir).lastPathComponent, "orphan (2).jpg")

        try Data("<x/>".utf8).write(to: tempDir.appendingPathComponent("pair.xmp"))
        try Data("raw".utf8).write(to: tempDir.appendingPathComponent("pair.cr2"))
        XCTAssertEqual(PhotoExporter.uniqueFileURL(baseName: "pair", fileExtension: "jpg", in: tempDir).lastPathComponent, "pair.jpg")
    }

    // MARK: - loadEditState

    func testLoadEditStateReturnsIdentityWhenNoSidecarExists() {
        let photo = makePhoto(filename: "no-sidecar.jpg")
        XCTAssertEqual(PhotoExporter.loadEditState(for: photo), .identity)
    }

    func testLoadEditStateDecodesARealSidecarFile() throws {
        let photoURL = tempDir.appendingPathComponent("edited.jpg")
        var state = EditState()
        state.exposureEV = 1.5
        let sidecarURL = ImageDocumentModel.sidecarURL(for: photoURL)
        try JSONEncoder().encode(state).write(to: sidecarURL)

        let photo = Photo(id: 1, path: photoURL.path, filename: "edited.jpg", fileSize: nil, importedAt: Date())
        let loaded = PhotoExporter.loadEditState(for: photo)

        XCTAssertEqual(loaded.exposureEV, 1.5)
    }

    // MARK: - export (end-to-end)

    func testExportWritesAReadableJPEGWithIdentityEditState() async throws {
        let sourceURL = try writeSolidColorJPEG(size: 400)
        let photo = Photo(id: 1, path: sourceURL.path, filename: sourceURL.lastPathComponent, fileSize: nil, importedAt: Date())
        let outputDir = tempDir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let outputURL = try await PhotoExporter.export(photo, editState: .identity, to: outputDir, settings: ExportSettings(format: .jpeg))

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertNotNil(CIImage(contentsOf: outputURL))
    }

    func testExportWritesPNGTIFFAndHEIC() async throws {
        let sourceURL = try writeSolidColorJPEG(size: 200)
        let photo = Photo(id: 1, path: sourceURL.path, filename: sourceURL.lastPathComponent, fileSize: nil, importedAt: Date())
        let outputDir = tempDir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        for format in [ExportFormat.png, .tiff, .heic] {
            let outputURL = try await PhotoExporter.export(photo, editState: .identity, to: outputDir, settings: ExportSettings(format: format))
            XCTAssertEqual(outputURL.pathExtension, format.fileExtension)
            XCTAssertNotNil(CIImage(contentsOf: outputURL))
        }
    }

    func testExportRespectsResizeSetting() async throws {
        let sourceURL = try writeSolidColorJPEG(size: 800)
        let photo = Photo(id: 1, path: sourceURL.path, filename: sourceURL.lastPathComponent, fileSize: nil, importedAt: Date())
        let outputDir = tempDir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let outputURL = try await PhotoExporter.export(
            photo,
            editState: .identity,
            to: outputDir,
            settings: ExportSettings(format: .png, resize: .maxLongEdge(200))
        )

        let size = try readPixelSize(of: outputURL)
        XCTAssertLessThanOrEqual(max(size.width, size.height), 200)
    }

    func testExportThrowsForUnreadableSource() async throws {
        let photo = Photo(id: 1, path: "/tmp/does-not-exist-\(UUID().uuidString).jpg", filename: "missing.jpg", fileSize: nil, importedAt: Date())
        let outputDir = tempDir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        do {
            _ = try await PhotoExporter.export(photo, editState: .identity, to: outputDir, settings: ExportSettings())
            XCTFail("expected export to throw for an unreadable source")
        } catch {
            // expected
        }
    }

    // MARK: - Naming templates (batch rename, commit 2)

    private func photo(named filename: String, path: String? = nil, rating: Int = 0,
                       label: ColorLabel = .none, flag: FlagStatus = .none) -> Photo {
        Photo(id: 1, path: path ?? tempDir.appendingPathComponent(filename).path, filename: filename, fileSize: nil,
              importedAt: Date(timeIntervalSince1970: 1_772_719_629), rating: rating, flagStatus: flag, colorLabel: label)
    }

    /// A JPEG carrying an EXIF capture date, so `{date}` has something real to read.
    private func writeJPEGWithEXIFDate(_ exifDate: String, named name: String) throws -> URL {
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let url = tempDir.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        let props: [CFString: Any] = [kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: exifDate]]
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    func testDefaultTemplateGivesTheSourcesOwnBaseNameEvenForAwkwardNames() throws {
        // Byte-identical to the pre-template behavior, incl. names the sanitizer would change.
        for filename in ["IMG_0001.JPG", "My Trip (2).jpeg", "a:b.png", ".hidden.jpg", "IMG..7.tif", "日本語.NEF"] {
            let base = try PhotoExporter.destinationBaseName(
                for: photo(named: filename), sourceURL: tempDir.appendingPathComponent(filename),
                format: .jpeg, template: NamingTemplate.defaultTemplate, sequenceIndex: 0
            )
            XCTAssertEqual(base, (filename as NSString).deletingPathExtension, filename)
        }
    }

    func testExportSettingsDefaultsToTheIdentityTemplate() {
        XCTAssertEqual(ExportSettings().namingTemplate, "{name}")
    }

    func testSequenceUsesTheBatchIndexAndCountsFromOne() throws {
        let p = photo(named: "IMG_1.jpg")
        let names = try (0..<3).map {
            try PhotoExporter.destinationBaseName(
                for: p, sourceURL: p.path.isEmpty ? tempDir : URL(fileURLWithPath: p.path),
                format: .jpeg, template: "Trip_{seq:2}", sequenceIndex: $0
            )
        }
        XCTAssertEqual(names, ["Trip_01", "Trip_02", "Trip_03"])
    }

    func testRatingLabelAndFlagComeFromThePhoto() throws {
        let p = photo(named: "IMG_1.jpg", rating: 4, label: .green, flag: .picked)
        let base = try PhotoExporter.destinationBaseName(
            for: p, sourceURL: URL(fileURLWithPath: p.path), format: .jpeg,
            template: "{name}-{rating}-{label}-{flag}", sequenceIndex: 0
        )
        XCTAssertEqual(base, "IMG_1-4-green-picked")
    }

    func testDateTokenReadsTheSourcesEXIFCaptureDate() throws {
        let url = try writeJPEGWithEXIFDate("2024:12:25 08:30:00", named: "dated.jpg")
        let p = photo(named: "dated.jpg", path: url.path)
        let base = try PhotoExporter.destinationBaseName(
            for: p, sourceURL: url, format: .jpeg, template: "{datetime}_{name}", sequenceIndex: 0
        )
        XCTAssertEqual(base, "20241225-083000_dated")
    }

    /// What gates the capture-date file read: only `{date}`/`{datetime}` need it. (This does NOT
    /// prove the source is unread — `CaptureDate.read` never throws — only that the gate is right.)
    func testOnlyDateTokensAskForTheCaptureDate() throws {
        XCTAssertFalse(try NamingTemplate.compile("{seq}_{name}_{rating}{label}{flag}").get().usesCaptureDate)
        XCTAssertTrue(try NamingTemplate.compile("x{date}").get().usesCaptureDate)
        XCTAssertTrue(try NamingTemplate.compile("{datetime}").get().usesCaptureDate)
        XCTAssertTrue(try NamingTemplate.compile("{{}}{name}{seq}{date}").get().usesCaptureDate)
    }

    func testInvalidTemplateThrowsInvalidNamingWithTheSpecificReason() {
        let p = photo(named: "IMG_1.jpg")
        XCTAssertThrowsError(try PhotoExporter.destinationBaseName(
            for: p, sourceURL: URL(fileURLWithPath: p.path), format: .jpeg, template: "{bogus}", sequenceIndex: 0
        )) { error in
            guard case PhotoExportError.invalidNaming(.unknownToken("bogus")) = error else {
                return XCTFail("expected invalidNaming(unknownToken), got \(error)")
            }
        }
    }

    func testExportWritesTheTemplatedNameWithTheExportFormatsExtension() async throws {
        let sourceURL = try writeSolidColorJPEG(size: 64, named: "IMG_9.jpg")
        let p = Photo(id: 1, path: sourceURL.path, filename: "IMG_9.jpg", fileSize: nil, importedAt: Date(), rating: 3)
        let out = tempDir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var settings = ExportSettings(format: .png)
        settings.namingTemplate = "Trip_{seq:3}_{rating}star"

        let url = try await PhotoExporter.export(p, editState: .identity, to: out, settings: settings, sequenceIndex: 6)

        XCTAssertEqual(url.lastPathComponent, "Trip_007_3star.png") // export ext (png), not the source's (jpg)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testTemplatedExportNeverOverwritesAndKeepsTheCollisionSuffix() async throws {
        let sourceURL = try writeSolidColorJPEG(size: 32, named: "IMG_1.jpg")
        let p = Photo(id: 1, path: sourceURL.path, filename: "IMG_1.jpg", fileSize: nil, importedAt: Date())
        let out = tempDir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var settings = ExportSettings()
        settings.namingTemplate = "same"

        let first = try await PhotoExporter.export(p, editState: .identity, to: out, settings: settings)
        let second = try await PhotoExporter.export(p, editState: .identity, to: out, settings: settings)

        XCTAssertEqual(first.lastPathComponent, "same.jpg")
        XCTAssertEqual(second.lastPathComponent, "same (2).jpg")
    }

    func testExportWithAnInvalidTemplateFailsBeforeWritingAnything() async throws {
        let sourceURL = try writeSolidColorJPEG(size: 32, named: "IMG_1.jpg")
        let p = Photo(id: 1, path: sourceURL.path, filename: "IMG_1.jpg", fileSize: nil, importedAt: Date())
        let out = tempDir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var settings = ExportSettings()
        settings.namingTemplate = "{oops"

        do {
            _ = try await PhotoExporter.export(p, editState: .identity, to: out, settings: settings)
            XCTFail("expected an invalid template to fail the export")
        } catch let error as PhotoExportError {
            guard case .invalidNaming(.unterminatedBrace) = error else { return XCTFail("got \(error)") }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), [])
    }

    // MARK: - Collision suffix vs the 255-byte limit (D39)

    func testACollisionSuffixNeverPushesTheNamePast255Bytes() throws {
        // 250 + ".jpg" = 254 bytes fits; adding " (2)" would make 258.
        let base = String(repeating: "a", count: 250)
        try Data().write(to: tempDir.appendingPathComponent(base + ".jpg"))
        let url = PhotoExporter.uniqueFileURL(baseName: base, fileExtension: "jpg", in: tempDir)
        XCTAssertLessThanOrEqual(url.lastPathComponent.utf8.count, 255)
        XCTAssertTrue(url.lastPathComponent.hasSuffix(" (2).jpg"), url.lastPathComponent)
        XCTAssertNotEqual(url.lastPathComponent, base + ".jpg")
    }

    func testTrimmingNeverSplitsAMultiByteCharacterAndKeepsTheSuffixWhole() {
        let base = String(repeating: "日", count: 84) // 252 bytes
        let fitted = PhotoExporter.baseNameFitting(base, suffix: " (12)", fileExtension: "jpg")
        XCTAssertTrue(fitted.hasSuffix(" (12)"))
        XCTAssertLessThanOrEqual((fitted + ".jpg").utf8.count, 255)
        XCTAssertTrue(fitted.dropLast(5).allSatisfy { $0 == "日" }) // only whole characters remain
    }

    func testShortNamesAreNotTouchedByTheFitting() {
        XCTAssertEqual(PhotoExporter.baseNameFitting("IMG_0001", suffix: " (2)", fileExtension: "jpg"), "IMG_0001 (2)")
    }
}


// MARK: - Output color space

final class ExportColorSpaceTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ExportColorSpaceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// A patch whose colour is defined IN Display P3 — saturated enough to lie outside sRGB.
    private func p3Patch() throws -> CIImage {
        let p3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let color = try XCTUnwrap(CIColor(red: 0.1, green: 0.95, blue: 0.2, colorSpace: p3))
        return CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
    }

    private func profileName(of url: URL) throws -> String {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        return try XCTUnwrap(props[kCGImagePropertyProfileName as String] as? String)
    }

    /// The file's first pixel as extended-linear-sRGB floats (no clamping), i.e. its true colour.
    private func linearColor(of url: URL) throws -> [Float] {
        let working = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let context = CIContext(options: [.workingColorSpace: working, .workingFormat: CIFormat.RGBAf])
        let image = try XCTUnwrap(CIImage(contentsOf: url))
        var pixel = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBAf, colorSpace: working)
        return pixel
    }

    func testEachProfileIsEmbeddedForEveryFormat() throws {
        let expected: [(ExportColorSpace, String)] = [(.sRGB, "sRGB"), (.displayP3, "Display P3"), (.adobeRGB, "Adobe RGB")]
        for format in ExportFormat.allCases {
            for (space, fragment) in expected {
                let url = dir.appendingPathComponent("\(space.rawValue).\(format.fileExtension)")
                try PhotoExporter.write(try p3Patch(), format: format, quality: 0.9, colorSpace: space, to: url)
                XCTAssertTrue(try profileName(of: url).contains(fragment), "\(format) \(space)")
            }
        }
    }

    func testDefaultWriteStaysSRGBSoEnhanceIsUnchanged() throws {
        let url = dir.appendingPathComponent("default.jpg")
        try PhotoExporter.write(try p3Patch(), format: .jpeg, quality: 0.9, to: url)
        XCTAssertTrue(try profileName(of: url).contains("sRGB"))
    }

    /// The behavioural difference, not just the tag: a P3-only colour keeps its out-of-sRGB value (a negative
    /// extended-linear component) in P3 output, but is clamped into the sRGB gamut in sRGB output.
    func testWideGamutColorSurvivesInP3ButClipsInSRGB() throws {
        let p3URL = dir.appendingPathComponent("p3.png"), srgbURL = dir.appendingPathComponent("srgb.png")
        try PhotoExporter.write(try p3Patch(), format: .png, quality: 1, colorSpace: .displayP3, to: p3URL)
        try PhotoExporter.write(try p3Patch(), format: .png, quality: 1, colorSpace: .sRGB, to: srgbURL)
        let wide = try linearColor(of: p3URL), clipped = try linearColor(of: srgbURL)
        XCTAssertLessThan(wide.min() ?? 0, -0.02, "P3 output must keep the out-of-sRGB colour")
        XCTAssertGreaterThanOrEqual(clipped.prefix(3).min() ?? -1, -0.002, "sRGB output is gamut-clamped")
    }

    func testExportUsesTheSettingsColorSpace() async throws {
        let src = dir.appendingPathComponent("src.jpg")
        try PhotoExporter.write(try p3Patch(), format: .jpeg, quality: 0.9, to: src)
        let photo = Photo(id: 1, path: src.path, filename: "src.jpg", fileSize: nil, importedAt: Date())
        let out = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let url = try await PhotoExporter.export(photo, editState: .identity, to: out,
                                                 settings: ExportSettings(format: .jpeg, colorSpace: .displayP3))
        XCTAssertTrue(try profileName(of: url).contains("Display P3"))
    }

    func testColorSpaceIsRememberedAndTolerant() throws {
        let suite = "ExportColorSpaceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ExportSettingsStore(defaults: defaults)
        store.save(ExportSettings(colorSpace: .adobeRGB))
        XCTAssertEqual(store.load().colorSpace, .adobeRGB)
        defaults.set(Data(#"{"colorSpace":"rec2020","format":"png"}"#.utf8), forKey: ExportSettingsStore.key)
        XCTAssertEqual(store.load().colorSpace, .sRGB, "unknown profile falls back")
        XCTAssertEqual(store.load().format, .png)
    }
}

// MARK: - Remembered settings

final class ExportSettingsStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        suiteName = "ExportSettingsStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testNothingStoredLoadsDefaults() {
        XCTAssertEqual(ExportSettingsStore(defaults: defaults).load(), ExportSettings())
    }

    func testRoundTripKeepsEveryField() {
        let store = ExportSettingsStore(defaults: defaults)
        let settings = ExportSettings(format: .tiff, quality: 0.5, resize: .maxLongEdge(1600), namingTemplate: "{name}-{seq}")
        store.save(settings)
        XCTAssertEqual(store.load(), settings)
    }

    func testMissingKeysFallBackToPerFieldDefaults() throws {
        defaults.set(Data(#"{"format":"png"}"#.utf8), forKey: ExportSettingsStore.key)
        let loaded = ExportSettingsStore(defaults: defaults).load()
        XCTAssertEqual(loaded.format, .png)
        XCTAssertEqual(loaded.quality, ExportSettings().quality)
        XCTAssertEqual(loaded.resize, .original)
        XCTAssertEqual(loaded.namingTemplate, "{name}")
    }

    func testUnknownEnumValueResetsOnlyThatField() {
        defaults.set(Data(#"{"format":"avif","quality":0.5,"namingTemplate":"{seq}"}"#.utf8), forKey: ExportSettingsStore.key)
        let loaded = ExportSettingsStore(defaults: defaults).load()
        XCTAssertEqual(loaded.format, .jpeg)
        XCTAssertEqual(loaded.quality, 0.5, accuracy: 0.0001)
        XCTAssertEqual(loaded.namingTemplate, "{seq}")
    }

    func testMalformedResizeResetsOnlyThatField() {
        defaults.set(Data(#"{"format":"png","resize":{"bogus":1}}"#.utf8), forKey: ExportSettingsStore.key)
        let loaded = ExportSettingsStore(defaults: defaults).load()
        XCTAssertEqual(loaded.format, .png)
        XCTAssertEqual(loaded.resize, .original)
    }

    func testNonFiniteResizeStillSavesTheOtherFields() {
        let store = ExportSettingsStore(defaults: defaults)
        store.save(ExportSettings(format: .tiff, resize: .maxLongEdge(.infinity)))
        let loaded = store.load()
        XCTAssertEqual(loaded.format, .tiff, "a non-finite long edge must not stop the save")
        XCTAssertEqual(loaded.resize, .original)
    }

    func testOversizedStoredLongEdgeDecodesToADisplayableValue() {
        defaults.set(Data(#"{"resize":{"maxLongEdge":{"_0":1e20}}}"#.utf8), forKey: ExportSettingsStore.key)
        guard case .maxLongEdge(let edge) = ExportSettingsStore(defaults: defaults).load().resize else { return XCTFail("expected a long edge") }
        XCTAssertEqual(edge, ExportResize.maximumLongEdge)
        XCTAssertNotNil(Int(exactly: edge.rounded()), "the options sheet converts this to Int")
    }

    func testSanitizedBoundsAndDropsNonFinite() {
        XCTAssertEqual(ExportResize.maxLongEdge(0).sanitized, .original)
        XCTAssertEqual(ExportResize.maxLongEdge(-5).sanitized, .original)
        XCTAssertEqual(ExportResize.maxLongEdge(0.5).sanitized, .maxLongEdge(0.5))
        XCTAssertEqual(ExportResize.maxLongEdge(.nan).sanitized, .original)
        XCTAssertEqual(ExportResize.maxLongEdge(2048).sanitized, .maxLongEdge(2048))
        XCTAssertEqual(ExportResize.original.sanitized, .original)
    }

    func testCorruptDataLoadsDefaults() {
        defaults.set(Data("not json".utf8), forKey: ExportSettingsStore.key)
        XCTAssertEqual(ExportSettingsStore(defaults: defaults).load(), ExportSettings())
    }

    func testOutOfRangeQualityIsClamped() {
        defaults.set(Data(#"{"quality":7}"#.utf8), forKey: ExportSettingsStore.key)
        XCTAssertEqual(ExportSettingsStore(defaults: defaults).load().quality, 1)
        defaults.set(Data(#"{"quality":-3}"#.utf8), forKey: ExportSettingsStore.key)
        XCTAssertEqual(ExportSettingsStore(defaults: defaults).load().quality, 0.1, accuracy: 0.0001)
    }

    @MainActor
    func testModelLoadsStoredSettingsAndSavesChanges() {
        let store = ExportSettingsStore(defaults: defaults)
        store.save(ExportSettings(format: .png))
        let model = ExportModel(store: store)
        XCTAssertEqual(model.settings.format, .png)
        model.settings.namingTemplate = "{date}"
        XCTAssertEqual(store.load().namingTemplate, "{date}")
    }
}
