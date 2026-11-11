import XCTest
import CoreImage
import ImageIO
@testable import PhotoApp

/// Export extras v1 (D57-9): original-file export, the JPEG/HEIC maximum file size, and the exclusive commit of
/// a rendered export. Real files in a temp folder.
final class ExportExtrasTests: XCTestCase {
    private var dir: URL!
    private var out: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ExportExtrasTests-\(UUID().uuidString)")
        out = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Fixtures

    private func noise(width: Int = 1200, height: Int = 900) throws -> CIImage {
        let generator = try XCTUnwrap(CIFilter(name: "CIRandomGenerator")?.outputImage)
        return generator.cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    private func writeNoiseJPEG(named name: String = "noisy.jpg", width: Int = 1200, height: Int = 900) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try CIContext().writeJPEGRepresentation(of: try noise(width: width, height: height), to: url,
                                                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return url
    }

    private func photo(_ url: URL, id: Int64 = 1, versionKey: String? = nil) -> Photo {
        Photo(id: id, path: url.path, filename: url.lastPathComponent, fileSize: nil, importedAt: Date(),
              masterId: versionKey == nil ? nil : 1, versionKey: versionKey)
    }

    private func bytes(_ url: URL) throws -> Data { try Data(contentsOf: url) }

    private func files(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    // MARK: - Original export

    func testOriginalExportIsByteIdenticalWithTheSourceExtension() throws {
        let src = try writeNoiseJPEG(named: "IMG_1.JPG", width: 64, height: 48)
        let result = try PhotoExporter.exportOriginal(photo(src), to: out, settings: ExportSettings(kind: .original), sequenceIndex: 0)
        XCTAssertEqual(result.url.lastPathComponent, "IMG_1.JPG", "the SOURCE extension, with its own case, not the settings format's")
        XCTAssertEqual(try bytes(result.url), try bytes(src))
        XCTAssertFalse(result.sourceWasTruncated)
    }

    func testOriginalExportUsesTheSourceExtensionNotTheSettingsFormat() throws {
        let src = try writeNoiseJPEG(named: "pic.jpeg", width: 32, height: 32)
        let result = try PhotoExporter.exportOriginal(photo(src), to: out, settings: ExportSettings(format: .png, kind: .original), sequenceIndex: 0)
        XCTAssertEqual(result.url.pathExtension, "jpeg")
    }

    func testOriginalExportIgnoresEveryRenderSetting() throws {
        let src = try writeNoiseJPEG(named: "a.jpg", width: 200, height: 100)
        var settings = ExportSettings(format: .png, quality: 0.1, resize: .maxLongEdge(10), colorSpace: .adobeRGB,
                                      metadata: .none, sharpening: .print, kind: .original)
        settings.watermark = ExportWatermark(isEnabled: true, text: "X")
        settings.maxFileSizeKB = 50
        let result = try PhotoExporter.exportOriginal(photo(src), to: out, settings: settings, sequenceIndex: 0)
        XCTAssertEqual(try bytes(result.url), try bytes(src))
    }

    func testOriginalExportKeepsTheGPSAndEveryTagOfTheSource() throws {
        let src = dir.appendingPathComponent("gps.jpg")
        let image = try XCTUnwrap(CIContext().createCGImage(try noise(width: 40, height: 40), from: CGRect(x: 0, y: 0, width: 40, height: 40)))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(src as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 12.5, kCGImagePropertyGPSLatitudeRef: "N"]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let result = try PhotoExporter.exportOriginal(photo(src), to: out, settings: ExportSettings(kind: .original), sequenceIndex: 0)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(result.url as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        XCTAssertNotNil(props[kCGImagePropertyGPSDictionary as String], "an original copy keeps the location")
    }

    func testOriginalExportNeverOverwritesAnExistingFile() throws {
        let src = try writeNoiseJPEG(named: "same.jpg", width: 32, height: 32)
        let existing = out.appendingPathComponent("same.jpg")
        try Data("precious".utf8).write(to: existing)
        let result = try PhotoExporter.exportOriginal(photo(src), to: out, settings: ExportSettings(kind: .original), sequenceIndex: 0)
        XCTAssertEqual(try bytes(existing), Data("precious".utf8))
        XCTAssertEqual(result.url.lastPathComponent, "same (2).jpg")
        XCTAssertEqual(try bytes(result.url), try bytes(src))
    }

    /// The name was free when picked but taken by the time of the commit (the race): the copy must move on, not overwrite.
    func testOriginalExportSurvivesANameTakenAtCommitTime() throws {
        let src = try writeNoiseJPEG(named: "race.jpg", width: 32, height: 32)
        let taken = out.appendingPathComponent("race.jpg")
        try Data("other".utf8).write(to: taken)
        let result = try PhotoExporter.exportOriginal(photo(src), to: out, settings: ExportSettings(kind: .original), sequenceIndex: 0, firstCandidate: taken)
        XCTAssertEqual(try bytes(taken), Data("other".utf8))
        XCTAssertNotEqual(result.url, taken)
        XCTAssertEqual(try bytes(result.url), try bytes(src))
    }

    func testOriginalExportCopiesOnlyThePhotoFileNotItsEditsOrXMP() throws {
        let src = try writeNoiseJPEG(named: "e.jpg", width: 32, height: 32)
        try Data("{}".utf8).write(to: SidecarStore.sidecarURL(for: src))
        try Data("<x/>".utf8).write(to: XMPSidecarStore.sidecarURL(for: src))
        _ = try PhotoExporter.exportOriginal(photo(src), to: out, settings: ExportSettings(kind: .original), sequenceIndex: 0)
        XCTAssertEqual(try files(in: out), ["e.jpg"], "no .photoapp.json, no .xmp, and no leftover temp file")
    }

    func testOriginalExportOfATruncatedSourceCopiesItByteForByteAndReportsIt() throws {
        let good = try writeNoiseJPEG(named: "full.jpg", width: 400, height: 300)
        let data = try bytes(good)
        let cut = dir.appendingPathComponent("cut.jpg")
        try data.prefix(data.count / 2).write(to: cut)
        XCTAssertEqual(SourceIntegrity.verdict(forFileAt: cut), .truncated)
        let result = try PhotoExporter.exportOriginal(photo(cut), to: out, settings: ExportSettings(kind: .original), sequenceIndex: 0)
        XCTAssertEqual(try bytes(result.url), try bytes(cut))
        XCTAssertTrue(result.sourceWasTruncated)
    }

    func testOriginalExportOfAMissingSourceThrows() {
        let missing = photo(dir.appendingPathComponent("nope.jpg"))
        XCTAssertThrowsError(try PhotoExporter.exportOriginal(missing, to: out, settings: ExportSettings(kind: .original), sequenceIndex: 0))
        XCTAssertEqual((try? files(in: out)) ?? ["x"], [])
    }

    func testOriginalExportUsesTheNamingTemplateWithTheSourceExtension() throws {
        let src = try writeNoiseJPEG(named: "n.JPG", width: 32, height: 32)
        let settings = ExportSettings(namingTemplate: "Trip_{seq}", kind: .original)
        let result = try PhotoExporter.exportOriginal(photo(src), to: out, settings: settings, sequenceIndex: 4)
        XCTAssertEqual(result.url.lastPathComponent, "Trip_005.JPG")
    }

    func testRenderExportOfOriginalKindStillCopiesTheOriginal() async throws {
        let src = try writeNoiseJPEG(named: "d.jpg", width: 32, height: 32)
        let url = try await PhotoExporter.export(photo(src), editState: .identity, to: out, settings: ExportSettings(format: .png, kind: .original))
        XCTAssertEqual(try bytes(url), try bytes(src))
    }

    func testVirtualCopiesOfOneFileAreExportedOnce() {
        let a = photo(URL(fileURLWithPath: "/x/a.jpg"), id: 1)
        let copy = photo(URL(fileURLWithPath: "/x/a.jpg"), id: 2, versionKey: "k")
        let b = photo(URL(fileURLWithPath: "/x/b.jpg"), id: 3)
        let unique = PhotoExporter.photosForOriginalExport([a, copy, b])
        XCTAssertEqual(unique.map(\.id), [1, 3])
        XCTAssertEqual(PhotoExporter.photosForOriginalExport([copy, a]).map(\.id), [2], "the first row of a path wins")
    }

    func testOriginalExportRefusesASymlinkAndLeavesNothing() throws {
        let real = try writeNoiseJPEG(named: "real.jpg", width: 32, height: 32)
        let link = dir.appendingPathComponent("link.jpg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertThrowsError(try PhotoExporter.exportOriginal(photo(link), to: out, settings: ExportSettings(kind: .original), sequenceIndex: 0))
        XCTAssertEqual(try files(in: out), [])
    }

    func testOriginalExportRefusesAFolderNamedLikeAPhoto() throws {
        let folder = dir.appendingPathComponent("Edits.jpg")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appendingPathComponent("inner.txt"))
        XCTAssertThrowsError(try PhotoExporter.exportOriginal(photo(folder), to: out, settings: ExportSettings(kind: .original), sequenceIndex: 0))
        XCTAssertEqual(try files(in: out), [])
    }

    /// A copier that writes the SAME SIZE of different bytes (a corrupt copy): the check must catch it and leave no file.
    func testACorruptSameSizeCopyIsRefusedAndLeavesNoFile() throws {
        let src = try writeNoiseJPEG(named: "c.jpg", width: 32, height: 32)
        let size = try bytes(src).count
        XCTAssertThrowsError(try PhotoExporter.exportOriginal(photo(src), to: out, settings: ExportSettings(kind: .original), sequenceIndex: 0, copy: { _, to in
            try Data(repeating: 7, count: size).write(to: to)
        }))
        XCTAssertEqual(try files(in: out), [], "neither a staged nor a final file remains")
    }

    @MainActor
    func testTheSheetAlwaysOpensAsRenderedInTheSameSession() throws {
        let suite = "ExportExtrasTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = ExportModel(store: ExportSettingsStore(defaults: defaults))
        model.settings.kind = .original
        model.settings.maxFileSizeKB = 200
        model.beginExport()
        XCTAssertEqual(model.settings.kind, .rendered, "Original is never armed by an earlier sheet")
        XCTAssertEqual(model.settings.maxFileSizeKB, 200, "other settings stay remembered")
        XCTAssertTrue(model.isPresentingOptions)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let content = (try? String(contentsOf: root.appendingPathComponent("Sources/UI/ContentView.swift"), encoding: .utf8)) ?? ""
        XCTAssertEqual(content.components(separatedBy: "isPresentingOptions = true").count, 1, "only beginExport presents the sheet")
    }

    func testACopyThatTurnsIntoASymlinkIsRefusedAndLeavesNothing() throws {
        let src = try writeNoiseJPEG(named: "t.jpg", width: 32, height: 32)
        XCTAssertThrowsError(try PhotoExporter.exportOriginal(photo(src), to: out, settings: ExportSettings(kind: .original), sequenceIndex: 0, copy: { from, to in
            try FileManager.default.createSymbolicLink(at: to, withDestinationURL: from)
        }))
        XCTAssertEqual(try files(in: out), [])
    }

    func testSizeLimitTextIsNormalisedOnExport() {
        XCTAssertEqual(ExportSheetRules.effectiveSizeLimitText(typed: "", current: 300), "300")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let view = (try? String(contentsOf: root.appendingPathComponent("Sources/UI/ExportOptionsView.swift"), encoding: .utf8)) ?? ""
        XCTAssertGreaterThanOrEqual(view.components(separatedBy: "ExportSheetRules.effectiveSizeLimitText").count - 1, 2, "on focus loss AND on Export")
    }

    func testFolderPanelWording() {
        XCTAssertEqual(ExportSheetRules.folderPanel(count: 2, kind: .original).prompt, "Copy")
        XCTAssertEqual(ExportSheetRules.folderPanel(count: 2, kind: .original).message, "Choose a folder to copy 2 originals into.")
        XCTAssertEqual(ExportSheetRules.folderPanel(count: 1, kind: .original).message, "Choose a folder to copy 1 original into.")
        XCTAssertEqual(ExportSheetRules.folderPanel(count: 1, kind: .rendered).message, "Choose a folder to export 1 photo into.")
        XCTAssertEqual(ExportSheetRules.folderPanel(count: 1, kind: .rendered).prompt, "Export")
    }

    func testSizeLimitTextShowsTheEffectiveValue() {
        XCTAssertEqual(ExportSheetRules.effectiveSizeLimitText(typed: "10", current: 50), "50")
        XCTAssertEqual(ExportSheetRules.effectiveSizeLimitText(typed: "0", current: 300), "300")
        XCTAssertEqual(ExportSheetRules.effectiveSizeLimitText(typed: "-4", current: nil), "500")
        XCTAssertEqual(ExportSheetRules.effectiveSizeLimitText(typed: "abc", current: 120), "120")
        XCTAssertEqual(ExportSheetRules.effectiveSizeLimitText(typed: "700", current: 700), "700")
    }

    func testOriginalModeShowsAnHonestMetadataLabel() {
        XCTAssertEqual(ExportSheetRules.originalMetadataLabel, "Metadata: all (original file)")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let view = (try? String(contentsOf: root.appendingPathComponent("Sources/UI/ExportOptionsView.swift"), encoding: .utf8)) ?? ""
        XCTAssertTrue(view.contains("ExportSheetRules.originalMetadataLabel"))
        let model = (try? String(contentsOf: root.appendingPathComponent("Sources/UI/ExportModel.swift"), encoding: .utf8)) ?? ""
        XCTAssertTrue(model.contains("ExportSheetRules.folderPanel"))
        XCTAssertLessThan(model.range(of: "photosForOriginalExport")?.lowerBound ?? model.endIndex, model.range(of: "NSOpenPanel()")?.lowerBound ?? model.startIndex, "dedupe BEFORE the panel counts")
    }

    // MARK: - Settings

    func testKindAndLimitRoundTripAndDefaultOff() throws {
        XCTAssertEqual(ExportSettings().kind, .rendered)
        XCTAssertNil(ExportSettings().maxFileSizeKB)
        var s = ExportSettings(kind: .original)
        s.maxFileSizeKB = 300
        let back = try JSONDecoder().decode(ExportSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.kind, .rendered, "Original is never remembered (the sheet always opens as Rendered)")
        XCTAssertEqual(back.maxFileSizeKB, 300)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(s), as: UTF8.self).contains("\"kind\":\"original\""))
    }

    func testStoreToleratesTheNewFields() throws {
        let suite = "ExportExtrasTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ExportSettingsStore(defaults: defaults)

        defaults.set(Data(#"{"format":"png"}"#.utf8), forKey: ExportSettingsStore.key)
        XCTAssertEqual(store.load().kind, .rendered)
        XCTAssertNil(store.load().maxFileSizeKB)

        defaults.set(Data(#"{"kind":"zip","maxFileSizeKB":"big","quality":0.5,"format":"tiff"}"#.utf8), forKey: ExportSettingsStore.key)
        var loaded = store.load()
        XCTAssertEqual(loaded.kind, .rendered, "an unknown kind resets that field only")
        XCTAssertNil(loaded.maxFileSizeKB)
        XCTAssertEqual(loaded.format, .tiff)
        XCTAssertEqual(loaded.quality, 0.5, accuracy: 0.0001)

        defaults.set(Data(#"{"kind":"original","maxFileSizeKB":7}"#.utf8), forKey: ExportSettingsStore.key)
        loaded = store.load()
        XCTAssertEqual(loaded.kind, .rendered, "an old stored Original is ignored")
        XCTAssertEqual(loaded.maxFileSizeKB, ExportSettings.minimumFileSizeKB, "below the floor is raised to it")

        for junk in ["0", "-5"] {
            defaults.set(Data(#"{"maxFileSizeKB":\#(junk)}"#.utf8), forKey: ExportSettingsStore.key)
            XCTAssertNil(store.load().maxFileSizeKB, "\(junk) is not a limit: off")
        }
        defaults.set(Data(#"{"maxFileSizeKB":99999999999}"#.utf8), forKey: ExportSettingsStore.key)
        XCTAssertEqual(store.load().maxFileSizeKB, ExportSettings.maximumFileSizeKB)
    }

    func testTheLimitAppliesToLossyRenderedFormatsOnly() {
        for format in ExportFormat.allCases {
            var s = ExportSettings(format: format)
            s.maxFileSizeKB = 200
            XCTAssertEqual(s.sizeLimitBytes, format.isLossy ? 200 * 1024 : nil, "\(format)")
        }
        var original = ExportSettings(kind: .original)
        original.maxFileSizeKB = 200
        XCTAssertNil(original.sizeLimitBytes)
        XCTAssertNil(ExportSettings().sizeLimitBytes)
    }

    // MARK: - Limit search (pure)

    private func search(limit: Int, maxQuality: CGFloat = 1, sizeAt: @escaping (CGFloat) -> Int, calls: UnsafeMutablePointer<[CGFloat]>? = nil) -> FileSizeLimiter.Result? {
        FileSizeLimiter.search(limitBytes: limit, maxQuality: maxQuality) { quality in
            calls?.pointee.append(quality)
            return Data(count: sizeAt(quality))
        }
    }

    func testSearchReturnsTheTopQualityWhenItAlreadyFits() throws {
        var calls: [CGFloat] = []
        let r = try XCTUnwrap(search(limit: 1000, sizeAt: { Int($0 * 500) }, calls: &calls))
        XCTAssertTrue(r.metLimit)
        XCTAssertEqual(r.quality, 1, accuracy: 0.0001)
        XCTAssertEqual(calls.count, 1)
    }

    func testSearchFindsTheHighestQualityThatFits() throws {
        // size = 10_000 * q: a limit of 6_000 allows up to q = 0.6.
        let r = try XCTUnwrap(search(limit: 6000, sizeAt: { Int($0 * 10_000) }))
        XCTAssertTrue(r.metLimit)
        XCTAssertLessThanOrEqual(r.data.count, 6000)
        XCTAssertGreaterThan(r.quality, 0.55, "close to the best possible, not just any fit")
        XCTAssertLessThanOrEqual(r.quality, 0.6 + 0.0001)
    }

    func testSearchKeepsTheBestFitEvenWhenALaterProbeIsWorse() throws {
        // Non-monotonic: sizes are only small at 0.1, ~0.55 and exactly the probes' own values elsewhere.
        let r = try XCTUnwrap(search(limit: 100) { q in
            if abs(q - 0.55) < 0.0001 { return 90 }
            if q < 0.2 { return 10 }
            return 5000
        })
        XCTAssertTrue(r.metLimit)
        XCTAssertGreaterThanOrEqual(r.quality, 0.2, "must not fall back to a worse fit when a better one was seen")
    }

    func testSearchWithAnImpossibleLimitReturnsTheSmallestAndSaysSo() throws {
        let r = try XCTUnwrap(search(limit: 10, sizeAt: { 1000 + Int($0 * 1000) }))
        XCTAssertFalse(r.metLimit)
        XCTAssertEqual(r.quality, 0.1, accuracy: 0.0001)
        XCTAssertEqual(r.data.count, 1100)
    }

    func testSearchNeverExceedsTheChosenMaximumQuality() throws {
        var calls: [CGFloat] = []
        _ = search(limit: 6000, maxQuality: 0.5, sizeAt: { Int($0 * 10_000) }, calls: &calls)
        XCTAssertLessThanOrEqual(calls.max() ?? 0, 0.5 + 0.0001)
    }

    func testSearchUsesAFewEncodes() {
        var calls: [CGFloat] = []
        _ = search(limit: 6000, sizeAt: { Int($0 * 10_000) }, calls: &calls)
        XCTAssertLessThanOrEqual(calls.count, 10)
    }

    func testSearchFailedFirstEncodeGivesNil() {
        XCTAssertNil(FileSizeLimiter.search(limitBytes: 100, maxQuality: 1) { _ in nil })
    }

    // MARK: - Limited export (real encoders)

    func testLimitedJPEGExportLandsUnderTheLimit() async throws {
        let src = try writeNoiseJPEG(named: "big.jpg")
        var settings = ExportSettings(format: .jpeg, quality: 1.0, namingTemplate: "limited")
        let unlimited = try await PhotoExporter.exportReporting(photo(src), editState: .identity, to: out, settings: ExportSettings(format: .jpeg, quality: 1.0, namingTemplate: "free"))
        let freeSize = try bytes(unlimited.url).count
        let floorURL = out.appendingPathComponent("floorq.jpg")
        try PhotoExporter.write(try noise(), format: .jpeg, quality: 0.1, to: floorURL)
        let floorSize = try bytes(floorURL).count
        // A limit between what the lowest quality gives and what full quality gives.
        let limitKB = (floorSize + freeSize) / 2 / 1024
        XCTAssertGreaterThan(freeSize, floorSize * 2, "fixture must compress very differently for this test to mean anything")
        settings.maxFileSizeKB = limitKB
        let outcome = try await PhotoExporter.exportReporting(photo(src), editState: .identity, to: out, settings: settings)
        let size = try bytes(outcome.url).count
        XCTAssertLessThanOrEqual(size, limitKB * 1024)
        XCTAssertGreaterThan(size, limitKB * 1024 * 6 / 10, "uses the budget: not a needlessly tiny file")
        XCTAssertFalse(outcome.overLimit)
        XCTAssertEqual(outcome.url.pathExtension, "jpg")
    }

    func testLimitedHEICExportLandsUnderTheLimit() async throws {
        let src = try writeNoiseJPEG(named: "bigh.jpg")
        let freeURL = try await PhotoExporter.export(photo(src), editState: .identity, to: out, settings: ExportSettings(format: .heic, quality: 1.0, namingTemplate: "freeh"))
        let free = try bytes(freeURL).count
        let limitKB = max(ExportSettings.minimumFileSizeKB, free / 1024 / 2)
        var settings = ExportSettings(format: .heic, quality: 1.0, namingTemplate: "limh")
        settings.maxFileSizeKB = limitKB
        let outcome = try await PhotoExporter.exportReporting(photo(src), editState: .identity, to: out, settings: settings)
        XCTAssertLessThanOrEqual(try bytes(outcome.url).count, limitKB * 1024)
        XCTAssertFalse(outcome.overLimit)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(outcome.url as CFURL, nil))
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source, 0, nil), "a readable HEIC")
    }

    func testAnImpossibleLimitWritesTheSmallestFileAndIsCounted() async throws {
        let src = try writeNoiseJPEG(named: "imp.jpg", width: 1600, height: 1200)
        var settings = ExportSettings(format: .jpeg, quality: 0.9, namingTemplate: "imp")
        settings.maxFileSizeKB = ExportSettings.minimumFileSizeKB
        let outcome = try await PhotoExporter.exportReporting(photo(src), editState: .identity, to: out, settings: settings)
        XCTAssertTrue(outcome.overLimit)
        let size = try bytes(outcome.url).count
        XCTAssertGreaterThan(size, ExportSettings.minimumFileSizeKB * 1024, "noise cannot reach 50 KB at this size")
        // The smallest: the same image at the floor quality, encoded the unlimited way, is about the same size.
        let floorURL = out.appendingPathComponent("floor.jpg")
        try PhotoExporter.write(try noise(width: 1600, height: 1200), format: .jpeg, quality: 0.1, to: floorURL)
        XCTAssertLessThanOrEqual(size, try bytes(floorURL).count * 11 / 10)
    }

    func testPNGAndTIFFIgnoreTheLimit() async throws {
        let src = try writeNoiseJPEG(named: "p.jpg", width: 300, height: 200)
        for format in [ExportFormat.png, .tiff] {
            var limited = ExportSettings(format: format, namingTemplate: "lim-\(format.rawValue)")
            limited.maxFileSizeKB = ExportSettings.minimumFileSizeKB
            let a = try await PhotoExporter.exportReporting(photo(src), editState: .identity, to: out, settings: limited)
            let b = try await PhotoExporter.export(photo(src), editState: .identity, to: out, settings: ExportSettings(format: format, namingTemplate: "free-\(format.rawValue)"))
            XCTAssertFalse(a.overLimit)
            XCTAssertEqual(try bytes(a.url).count, try bytes(b).count, "\(format): limit must not change a lossless export")
            XCTAssertGreaterThan(try bytes(a.url).count, ExportSettings.minimumFileSizeKB * 1024)
        }
    }

    func testNoLimitKeepsTheExistingWriterBytes() async throws {
        let src = try writeNoiseJPEG(named: "same.jpg", width: 200, height: 150)
        let url = try await PhotoExporter.export(photo(src), editState: .identity, to: out, settings: ExportSettings(format: .jpeg, quality: 0.8, namingTemplate: "viaexport", metadata: .all))
        // The same pipeline output through the writer directly.
        let decoded = await RawDecoder.decode(contentsOf: src, editState: .identity)
        let oriented = try XCTUnwrap(decoded)
        let direct = dir.appendingPathComponent("direct.jpg")
        let image = EditPipeline.apply(.identity, to: oriented)
        let props = ExportMetadata.properties(from: oriented.properties, policy: .all)
        let withProps = WatermarkRenderer.apply(ExportWatermark(), to: OutputSharpen.apply(.none, to: image), logoStore: .shared)
            .settingProperties(InfoEmbedding.properties(KeywordEmbedding.properties(props, addingKeywords: [], policy: .all, include: true), adding: PhotoInfo(), policy: .all, include: false))
        try PhotoExporter.write(withProps, format: .jpeg, quality: 0.8, to: direct)
        XCTAssertEqual(try bytes(url), try bytes(direct))
    }

    func testLimitedExportKeepsFlatteningColourSpaceAndKeywords() async throws {
        // Half-transparent red over nothing: JPEG/HEIC flatten over black; the limited path must match the writer.
        let half = CIImage(color: CIColor(red: 1, green: 0, blue: 0, alpha: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        for format in [ExportFormat.jpeg, .heic] {
            let free = dir.appendingPathComponent("free.\(format.fileExtension)")
            try PhotoExporter.write(half, format: format, quality: 1, to: free)
            let limited = try PhotoExporter.writeLimited(half, format: format, maxQuality: 1, colorSpace: .sRGB, limitBytes: 1_000_000)
            let limitedURL = dir.appendingPathComponent("lim.\(format.fileExtension)")
            try limited.data.write(to: limitedURL)
            let a = try pixel(free), b = try pixel(limitedURL)
            for i in 0..<3 { XCTAssertEqual(Int(a[i]), Int(b[i]), accuracy: 3, "\(format) channel \(i): \(a) vs \(b)") }
            XCTAssertLessThan(Int(b[0]), 140, "\(format): flattened over black, not left bright")
            XCTAssertEqual(b[3], 255, "\(format): fully opaque, no alpha plane written")
            let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(try XCTUnwrap(CGImageSourceCreateWithURL(limitedURL as CFURL, nil)), 0, nil))
            XCTAssertTrue([.none, .noneSkipFirst, .noneSkipLast].contains(decoded.alphaInfo), "\(format): \(decoded.alphaInfo.rawValue)")
        }
    }

    func testLimitedExportEmbedsKeywordsAndTagsTheColourSpace() async throws {
        let src = try writeNoiseJPEG(named: "kw.jpg", width: 400, height: 300)
        var settings = ExportSettings(format: .jpeg, quality: 1, namingTemplate: "kw", colorSpace: .displayP3, metadata: .all)
        settings.maxFileSizeKB = 60
        let outcome = try await PhotoExporter.exportReporting(photo(src), editState: .identity, to: out, settings: settings, keywords: ["alpha", "beta"])
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(outcome.url as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        let iptc = props[kCGImagePropertyIPTCDictionary as String] as? [String: Any]
        XCTAssertEqual((iptc?[kCGImagePropertyIPTCKeywords as String] as? [String])?.sorted(), ["alpha", "beta"])
        let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(cg.colorSpace?.name as String?, CGColorSpace.displayP3 as String)
    }

    private func pixel(_ url: URL) throws -> [UInt8] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = try XCTUnwrap(CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(cg, in: CGRect(x: -32, y: -32, width: 64, height: 64))
        return px
    }

    // MARK: - Exclusive commit of a rendered export

    func testRenderedExportNeverOverwritesAFileThatAppearsAtCommitTime() async throws {
        let src = try writeNoiseJPEG(named: "r.jpg", width: 64, height: 48)
        let taken = out.appendingPathComponent("r.jpg")
        try Data("not yours".utf8).write(to: taken)
        let outcome = try await PhotoExporter.exportReporting(photo(src), editState: .identity, to: out,
                                                              settings: ExportSettings(), firstCandidate: taken)
        XCTAssertEqual(try bytes(taken), Data("not yours".utf8))
        XCTAssertNotEqual(outcome.url, taken)
        XCTAssertGreaterThan(try bytes(outcome.url).count, 100)
        XCTAssertEqual(try files(in: out).filter { $0.hasPrefix(".") }, [], "no leftover hidden temp file")
    }

    func testTwoRenderedExportsOfOnePhotoGetDistinctNames() async throws {
        let src = try writeNoiseJPEG(named: "twice.jpg", width: 64, height: 48)
        let a = try await PhotoExporter.export(photo(src), editState: .identity, to: out, settings: ExportSettings())
        let b = try await PhotoExporter.export(photo(src), editState: .identity, to: out, settings: ExportSettings())
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(b.lastPathComponent, "twice (2).jpg")
    }

    // MARK: - Summary + sheet rules

    func testSummaryWording() {
        XCTAssertEqual(ExportSummary.text(succeeded: 2, failed: 0, firstFailureMessage: nil), "Exported 2 photos.")
        XCTAssertEqual(ExportSummary.text(succeeded: 1, failed: 0, firstFailureMessage: nil, overLimit: 1),
                       "Exported 1 photo. 1 photo is over the size limit (smallest quality used).")
        XCTAssertTrue(ExportSummary.text(succeeded: 3, failed: 0, firstFailureMessage: nil, overLimit: 3).contains("3 photos are over the size limit"))
        XCTAssertEqual(ExportSummary.text(succeeded: 2, failed: 0, firstFailureMessage: nil, original: true), "Copied 2 original files.")
        XCTAssertTrue(ExportSummary.text(succeeded: 2, failed: 0, firstFailureMessage: nil, original: true, truncated: 1, duplicatesSkipped: 2)
            .contains("1 looked cut off"))
        XCTAssertTrue(ExportSummary.text(succeeded: 2, failed: 0, firstFailureMessage: nil, original: true, truncated: 0, duplicatesSkipped: 2)
            .contains("2 virtual copies shared a file"))
        XCTAssertTrue(ExportSummary.text(succeeded: 1, failed: 1, firstFailureMessage: "boom").contains("First error: boom"))
    }

    func testSheetRules() {
        XCTAssertTrue(ExportSheetRules.renderControlsEnabled(kind: .rendered))
        XCTAssertFalse(ExportSheetRules.renderControlsEnabled(kind: .original))
        XCTAssertTrue(ExportSheetRules.originalNotice.contains("including location (GPS) and all metadata"))
        XCTAssertTrue(ExportSheetRules.sizeLimitAvailable(ExportSettings(format: .jpeg)))
        XCTAssertTrue(ExportSheetRules.sizeLimitAvailable(ExportSettings(format: .heic)))
        XCTAssertFalse(ExportSheetRules.sizeLimitAvailable(ExportSettings(format: .png)))
        XCTAssertFalse(ExportSheetRules.sizeLimitAvailable(ExportSettings(format: .jpeg, kind: .original)))
        XCTAssertEqual(ExportSheetRules.title(count: 1, kind: .original), "Copy 1 Original")
        XCTAssertEqual(ExportSheetRules.title(count: 3, kind: .original), "Copy 3 Originals")
        XCTAssertEqual(ExportSheetRules.title(count: 3, kind: .rendered), "Export 3 Photos")
    }

    func testTheSheetUsesTheRules() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/UI/ExportOptionsView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("ExportSheetRules.originalNotice"))
        XCTAssertTrue(source.contains("ExportSheetRules.renderControlsEnabled"))
    }

    func testNamePreviewUsesTheSourceExtensionForOriginals() {
        let p = Photo(id: 1, path: "/tmp/IMG_0001.NEF", filename: "IMG_0001.NEF", fileSize: nil, importedAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(ExportNamePreview.evaluate(template: "{name}", photo: p, format: .jpeg, captureDate: nil, kind: .original), .example("IMG_0001.NEF"))
        XCTAssertEqual(ExportNamePreview.evaluate(template: "{name}", photo: p, format: .jpeg, captureDate: nil), .example("IMG_0001.jpg"))
    }

    // MARK: - Feedback

    private let written = [URL(fileURLWithPath: "/tmp/a.jpg"), URL(fileURLWithPath: "/tmp/b.jpg")]

    func testFeedbackCleanRunIsDoneWithShowInFinder() {
        let feedback = ExportSummary.feedback(succeeded: 2, failed: 0, firstFailureMessage: nil, written: written)
        XCTAssertEqual(feedback.kind, .done)
        XCTAssertEqual(feedback.title, "Export")
        XCTAssertEqual(feedback.action, .revealInFinder(written))
        XCTAssertEqual(feedback.message, ExportSummary.text(succeeded: 2, failed: 0, firstFailureMessage: nil))
    }

    func testFeedbackCaveatsAreWarningToasts() {
        XCTAssertEqual(ExportSummary.feedback(succeeded: 2, failed: 0, firstFailureMessage: nil, overLimit: 1, written: written).kind, .warning)
        XCTAssertEqual(
            ExportSummary.feedback(succeeded: 2, failed: 0, firstFailureMessage: nil, original: true, truncated: 1, written: written).kind,
            .warning
        )
        let dup = ExportSummary.feedback(
            succeeded: 2, failed: 0, firstFailureMessage: nil, original: true, duplicatesSkipped: 1, written: written
        )
        XCTAssertEqual(dup.kind, .warning)
        XCTAssertEqual(dup.presentation, .toast)
    }

    func testFeedbackAFailureIsAnAlertEvenWithCaveats() {
        let some = ExportSummary.feedback(succeeded: 1, failed: 2, firstFailureMessage: "disk full", written: [written[0]])
        XCTAssertEqual(some.kind, .incomplete)
        XCTAssertEqual(some.action, .revealInFinder([written[0]]))
        XCTAssertEqual(some.message, ExportSummary.text(succeeded: 1, failed: 2, firstFailureMessage: "disk full"))
        let all = ExportSummary.feedback(succeeded: 0, failed: 3, firstFailureMessage: "disk full", written: [])
        XCTAssertEqual(all.kind, .incomplete)
        XCTAssertNil(all.action)
        let mixed = ExportSummary.feedback(succeeded: 1, failed: 1, firstFailureMessage: nil, overLimit: 1, written: [written[0]])
        XCTAssertEqual(mixed.presentation, .alert)
    }

    func testFeedbackOriginalCopyIsDone() {
        let feedback = ExportSummary.feedback(succeeded: 2, failed: 0, firstFailureMessage: nil, original: true, written: written)
        XCTAssertEqual(feedback.kind, .done)
        XCTAssertEqual(
            feedback.message,
            ExportSummary.text(succeeded: 2, failed: 0, firstFailureMessage: nil, original: true)
        )
    }

    // MARK: Cancelled

    func testCancelledOnlyIsAWarningToastWithTheCountAndTheWrittenFiles() {
        let feedback = ExportSummary.feedback(succeeded: 1, failed: 0, firstFailureMessage: nil, cancelled: 9, written: [written[0]])
        XCTAssertEqual(feedback.kind, .warning)
        XCTAssertEqual(feedback.presentation, .toast)
        XCTAssertEqual(feedback.message, "Exported 1 photo. Stopped: 9 photos not exported.")
        XCTAssertEqual(feedback.action, .revealInFinder([written[0]]))
    }

    func testOriginalModeSaysFilesNotCopied() {
        XCTAssertEqual(
            ExportSummary.text(succeeded: 2, failed: 0, firstFailureMessage: nil, original: true, cancelled: 3),
            "Copied 2 original files. Stopped: 3 files not copied."
        )
        XCTAssertEqual(
            ExportSummary.text(succeeded: 2, failed: 0, firstFailureMessage: nil, original: true, cancelled: 1),
            "Copied 2 original files. Stopped: 1 file not copied."
        )
    }

    func testClauseOrderIsCaveatsThenFailedThenStoppedThenFirstError() {
        XCTAssertEqual(
            ExportSummary.text(succeeded: 1, failed: 2, firstFailureMessage: "disk full", overLimit: 1, cancelled: 4),
            "Exported 1 photo. 1 photo is over the size limit (smallest quality used). 2 failed. Stopped: 4 photos not exported. First error: disk full"
        )
    }

    func testCancelledSingularWording() {
        let text = ExportSummary.text(succeeded: 2, failed: 0, firstFailureMessage: nil, cancelled: 1)
        XCTAssertEqual(text, "Exported 2 photos. Stopped: 1 photo not exported.")
    }

    func testCancelledPlusFailedIsAnAlert() {
        let feedback = ExportSummary.feedback(succeeded: 1, failed: 1, firstFailureMessage: "disk full", cancelled: 3, written: [written[0]])
        XCTAssertEqual(feedback.kind, .incomplete)
        XCTAssertEqual(feedback.presentation, .alert)
        XCTAssertTrue(feedback.message.contains("Stopped: 3 photos not exported."))
        XCTAssertTrue(feedback.message.contains("1 failed."))
        XCTAssertTrue(feedback.message.hasSuffix("First error: disk full"))
    }

    func testZeroWrittenPlusCancelledIsAWarning() {
        let feedback = ExportSummary.feedback(succeeded: 0, failed: 0, firstFailureMessage: nil, cancelled: 5, written: [])
        XCTAssertEqual(feedback.kind, .warning)
        XCTAssertNil(feedback.action)
        XCTAssertEqual(feedback.message, "Exported 0 photos. Stopped: 5 photos not exported.")
    }

    func testCancelledZeroLeavesTheTextUnchanged() {
        XCTAssertEqual(
            ExportSummary.text(succeeded: 2, failed: 1, firstFailureMessage: "x", cancelled: 0),
            ExportSummary.text(succeeded: 2, failed: 1, firstFailureMessage: "x")
        )
        XCTAssertEqual(ExportSummary.feedback(succeeded: 2, failed: 0, firstFailureMessage: nil, cancelled: 0, written: written).kind, .done)
    }
}
