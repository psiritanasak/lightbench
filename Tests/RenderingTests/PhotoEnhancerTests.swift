import XCTest
import CoreImage
import Metal
import MetalFX
@testable import PhotoApp

/// `PhotoEnhancer` reads a real source photo and writes a real output
/// file, so — like `PhotoExporterTests` — these tests work against a
/// real temp directory rather than pure in-memory fixtures.
final class PhotoEnhancerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoEnhancerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func solidColorImage(size: Int, color: CIColor = CIColor(red: 0.6, green: 0.3, blue: 0.2)) -> CIImage {
        CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
    }

    private func writeSolidColorJPEG(size: Int, color: CIColor = CIColor(red: 0.6, green: 0.3, blue: 0.2), named name: String = "source.jpg") throws -> URL {
        let context = CIContext()
        let url = tempDir.appendingPathComponent(name)
        try context.writeJPEGRepresentation(
            of: solidColorImage(size: size, color: color),
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

    // MARK: - destinationURL

    func testDestinationURLAppendsTheEnhancedSuffixAsJPEG() {
        let source = tempDir.appendingPathComponent("IMG_0001.jpg")
        let url = PhotoEnhancer.destinationURL(forSource: source, in: tempDir)
        XCTAssertEqual(url.lastPathComponent, "IMG_0001-Enhanced-SR.jpg")
    }

    func testDestinationURLIsAlwaysJPEGRegardlessOfSourceExtension() {
        let source = tempDir.appendingPathComponent("IMG_0001.CR2")
        let url = PhotoEnhancer.destinationURL(forSource: source, in: tempDir)
        XCTAssertEqual(url.lastPathComponent, "IMG_0001-Enhanced-SR.jpg")
    }

    func testDestinationURLAddsCollisionSuffixWhenTheEnhancedFileAlreadyExists() throws {
        let source = tempDir.appendingPathComponent("IMG_0001.jpg")
        let existing = tempDir.appendingPathComponent("IMG_0001-Enhanced-SR.jpg")
        FileManager.default.createFile(atPath: existing.path, contents: Data())

        let url = PhotoEnhancer.destinationURL(forSource: source, in: tempDir)

        XCTAssertEqual(url.lastPathComponent, "IMG_0001-Enhanced-SR (2).jpg")
    }

    func testDestinationURLSkipsACandidateWithOnlyAnOrphanedSidecar() throws {
        // Confirms PhotoEnhancer actually gets PhotoExporter.uniqueFileURL's
        // orphan-sidecar protection for free, via delegation, not by
        // re-implementing it.
        let source = tempDir.appendingPathComponent("IMG_0001.jpg")
        let candidate = tempDir.appendingPathComponent("IMG_0001-Enhanced-SR.jpg")
        try JSONEncoder().encode(EditState()).write(to: SidecarStore.sidecarURL(for: candidate))

        let url = PhotoEnhancer.destinationURL(forSource: source, in: tempDir)

        XCTAssertEqual(url.lastPathComponent, "IMG_0001-Enhanced-SR (2).jpg")
    }

    // MARK: - enhance (end-to-end)

    func testEnhanceWritesAJPEGAtExactlyDoubleTheSourceDimensions() async throws {
        let sourceURL = try writeSolidColorJPEG(size: 100)

        let outcome = try await PhotoEnhancer.enhance(sourceURL: sourceURL, editState: .identity, into: tempDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: outcome.url.path))
        XCTAssertEqual(outcome.url.pathExtension, "jpg")
        let size = try readPixelSize(of: outcome.url)
        XCTAssertEqual(size.width, 200)
        XCTAssertEqual(size.height, 200)
    }

    /// Reviewer-caught: no test actually looked at `outcome.method`/
    /// `fallbackReason` — every other test would still pass even if
    /// `enhance` silently ALWAYS fell back to Lanczos (confirmed: passing
    /// `device: nil` into `SuperResolutionUpscaler.upscale` internally
    /// left every other assertion in this file unaffected). This derives
    /// the EXPECTED method from `SuperResolutionUpscaler.plannedMethod`
    /// itself, so the assertion is correct regardless of which method
    /// this specific test machine's hardware actually supports.
    func testEnhanceReportsTheActualUpscaleMethodUsed() async throws {
        let sourceURL = try writeSolidColorJPEG(size: 100)

        let outcome = try await PhotoEnhancer.enhance(sourceURL: sourceURL, editState: .identity, into: tempDir)

        let hasDevice = PhotoExporter.renderDevice != nil
        let deviceSupportsMetalFX = PhotoExporter.renderDevice.map { MTLFXSpatialScalerDescriptor.supportsDevice($0) } ?? false
        let (expectedMethod, expectedReason) = SuperResolutionUpscaler.plannedMethod(
            outputWidth: 200, outputHeight: 200, hasDevice: hasDevice, deviceSupportsMetalFX: deviceSupportsMetalFX
        )
        XCTAssertEqual(outcome.method, expectedMethod)
        XCTAssertEqual(outcome.fallbackReason, expectedReason)
    }

    func testEnhanceLeavesTheSourceFileByteIdentical() async throws {
        let sourceURL = try writeSolidColorJPEG(size: 100)
        let originalBytes = try Data(contentsOf: sourceURL)

        _ = try await PhotoEnhancer.enhance(sourceURL: sourceURL, editState: .identity, into: tempDir)

        let bytesAfter = try Data(contentsOf: sourceURL)
        XCTAssertEqual(originalBytes, bytesAfter, "PhotoEnhancer must never modify the original file")
    }

    func testEnhanceLeavesAPreExistingSourceSidecarUnchanged() async throws {
        let sourceURL = try writeSolidColorJPEG(size: 100)
        var sourceState = EditState()
        sourceState.exposureEV = 0.75
        let sourceSidecarURL = SidecarStore.sidecarURL(for: sourceURL)
        try JSONEncoder().encode(sourceState).write(to: sourceSidecarURL)
        let sidecarBytesBefore = try Data(contentsOf: sourceSidecarURL)

        _ = try await PhotoEnhancer.enhance(sourceURL: sourceURL, editState: sourceState, into: tempDir)

        let sidecarBytesAfter = try Data(contentsOf: sourceSidecarURL)
        XCTAssertEqual(sidecarBytesBefore, sidecarBytesAfter, "PhotoEnhancer must never touch the source's own sidecar")
    }

    func testEnhanceCreatesNoSidecarForTheNewFile() async throws {
        let sourceURL = try writeSolidColorJPEG(size: 100)

        let outcome = try await PhotoEnhancer.enhance(sourceURL: sourceURL, editState: .identity, into: tempDir)

        let newSidecarURL = SidecarStore.sidecarURL(for: outcome.url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: newSidecarURL.path), "the enhanced file must be a fresh, unedited photo from this app's own point of view")
    }

    func testEnhanceBakesInANonIdentityEditState() async throws {
        // A large positive exposure boost on a mid-gray-ish source should
        // visibly brighten the output — confirms edits are actually
        // applied (EditPipeline.apply runs), not just the raw source
        // upscaled untouched.
        let sourceURL = try writeSolidColorJPEG(size: 100, color: CIColor(red: 0.2, green: 0.2, blue: 0.2))
        var brightened = EditState()
        brightened.exposureEV = 3.0

        let outcome = try await PhotoEnhancer.enhance(sourceURL: sourceURL, editState: brightened, into: tempDir)

        guard let outputImage = CIImage(contentsOf: outcome.url) else {
            return XCTFail("couldn't read back the enhanced output")
        }
        let context = CIContext()
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { buffer in
            context.render(
                outputImage, toBitmap: buffer.baseAddress!, rowBytes: 4,
                bounds: CGRect(x: 50, y: 50, width: 1, height: 1),
                format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()
            )
        }
        // Measured (this test, run): the unedited source's own R channel
        // renders around 50-55; with this +3EV boost baked in, the
        // enhanced output's R channel measured 140 — comfortably above
        // this threshold, chosen well below the measured value so the
        // assertion isn't brittle against small, expected renderer
        // variance, while still requiring a REAL, large brightening (not
        // just noise) to pass.
        XCTAssertGreaterThan(pixel[0], 100, "a +3EV exposure boost should visibly brighten the baked-in output, got R=\(pixel[0])")
    }

    func testEnhanceThrowsForAnUnreadableSource() async throws {
        // Reviewer-caught: an unconstrained `catch {}` would still pass
        // even if `enhance` surfaced the WRONG error here (e.g.
        // `.upscaleFailed` instead of `.unreadableSource`) — matching the
        // specific case closes that gap.
        let missingURL = tempDir.appendingPathComponent("does-not-exist-\(UUID().uuidString).jpg")

        do {
            _ = try await PhotoEnhancer.enhance(sourceURL: missingURL, editState: .identity, into: tempDir)
            XCTFail("expected enhance to throw for an unreadable source")
        } catch let error as PhotoEnhanceError {
            guard case .unreadableSource(let path) = error else {
                return XCTFail("expected .unreadableSource, got \(error)")
            }
            XCTAssertEqual(path, missingURL.path)
        }
    }

    // MARK: - commitExclusively

    /// Deterministic tests for the retry logic itself, added per the
    /// reviewer's own suggestion (round 2): the underlying filesystem
    /// race `commitExclusively` guards against needs no test (a wrong
    /// assumption there fails SAFE — a thrown error, never a silent
    /// clobber), but the retry loop's own logic is fully deterministic
    /// and worth verifying directly, without any real concurrency.
    private func writeTempSourceFile(named name: String = "temp-source.jpg") throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try Data("temp file contents".utf8).write(to: url)
        return url
    }

    func testCommitExclusivelyUsesTheFirstCandidateWhenNothingIsThere() throws {
        let tempURL = try writeTempSourceFile()
        let target = tempDir.appendingPathComponent("output.jpg")

        let result = try PhotoEnhancer.commitExclusively(tempURL) { target }

        XCTAssertEqual(result, target)
        XCTAssertEqual(try Data(contentsOf: target), Data("temp file contents".utf8), "the committed file's own contents must match the temp file's, not just exist")
    }

    func testCommitExclusivelyRetriesWithTheNextCandidateOnCollision() throws {
        let tempURL = try writeTempSourceFile()
        let taken = tempDir.appendingPathComponent("output.jpg")
        let free = tempDir.appendingPathComponent("output (2).jpg")
        let takenContents = Data("someone else's photo".utf8)
        try takenContents.write(to: taken)

        var candidates = [taken, free]
        let result = try PhotoEnhancer.commitExclusively(tempURL) { candidates.removeFirst() }

        XCTAssertEqual(result, free, "expected it to move on to the second candidate after the first collided")
        XCTAssertTrue(FileManager.default.fileExists(atPath: free.path))
        XCTAssertEqual(try Data(contentsOf: taken), takenContents, "the pre-existing file at the first candidate must be left completely untouched, never partially overwritten")
    }

    func testCommitExclusivelyGivesUpAfterMaxRetriesAndLeavesExistingFilesIntact() throws {
        let tempURL = try writeTempSourceFile()
        let alwaysTaken = tempDir.appendingPathComponent("output.jpg")
        let takenContents = Data("someone else's photo".utf8)
        try takenContents.write(to: alwaysTaken)
        var candidateCallCount = 0

        do {
            _ = try PhotoEnhancer.commitExclusively(tempURL, nextCandidate: { candidateCallCount += 1; return alwaysTaken }, maxRetries: 3)
            XCTFail("expected commitExclusively to give up and throw")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, NSCocoaErrorDomain)
            XCTAssertEqual(error.code, NSFileWriteFileExistsError)
        }
        // The very first attempt plus 3 retries = 4 calls to nextCandidate.
        XCTAssertEqual(candidateCallCount, 4)
        XCTAssertEqual(try Data(contentsOf: alwaysTaken), takenContents, "must never touch the file that was blocking every attempt")
    }
}
