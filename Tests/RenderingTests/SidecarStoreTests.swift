import XCTest
@testable import PhotoApp

/// `SidecarStore` does real file I/O (like `PhotoExporterTests`/
/// `ThumbnailGeneratorTests`), so these tests work against a real temp
/// directory rather than pure in-memory fixtures. No security-scoped
/// bookmark or `NSOpenPanel` handling is exercised here — that's
/// `SidecarFolderAccess`'s own job, untested by this codebase's own
/// established precedent for `NSOpenPanel`-driven code (see
/// `ImageDocumentModel`'s own untested status).
final class SidecarStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidecarStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private var photoURL: URL {
        tempDir.appendingPathComponent("IMG_0001.jpg")
    }

    // MARK: - sidecarURL

    func testSidecarURLAppendsThePhotoAppJSONSuffix() {
        let url = SidecarStore.sidecarURL(for: photoURL)
        XCTAssertEqual(url.lastPathComponent, "IMG_0001.jpg.photoapp.json")
        XCTAssertEqual(url.deletingLastPathComponent(), tempDir)
    }

    /// `ImageDocumentModel.sidecarURL(for:)` is now a one-line forwarder —
    /// this pins that the forward is actually correct, not just present.
    func testImageDocumentModelSidecarURLForwardsToSidecarStore() {
        // Against the literal, not just against `SidecarStore` itself —
        // comparing only the two forwarder-vs-source values would still
        // pass if BOTH were wrong the same way.
        XCTAssertEqual(ImageDocumentModel.sidecarURL(for: photoURL).lastPathComponent, "IMG_0001.jpg.photoapp.json")
        XCTAssertEqual(ImageDocumentModel.sidecarURL(for: photoURL), SidecarStore.sidecarURL(for: photoURL))
    }

    // MARK: - read

    func testReadReturnsMissingForAnAbsentFile() {
        XCTAssertEqual(SidecarStore.read(forPhotoAt: photoURL), .missing)
    }

    func testReadReturnsUndecodableForGarbageBytes() throws {
        try Data("not valid json".utf8).write(to: SidecarStore.sidecarURL(for: photoURL))
        XCTAssertEqual(SidecarStore.read(forPhotoAt: photoURL), .undecodable)
    }

    /// Reviewer-caught: an EXISTING-but-unreadable sidecar (permissions, a
    /// sandbox hiccup, a not-yet-downloaded iCloud file) must map to
    /// `.undecodable`, NOT `.missing` — the latter would tell a
    /// read-modify-write caller it's safe to write a fresh merge over a
    /// file it only failed to READ, not one that was actually absent. A
    /// directory at the sidecar path forces `Data(contentsOf:)` to throw
    /// while `fileExists` still reports true, reproducing exactly that
    /// case without needing real filesystem permissions.
    func testReadReturnsUndecodableNotMissingForAnExistingButUnreadableFile() throws {
        try FileManager.default.createDirectory(
            at: SidecarStore.sidecarURL(for: photoURL), withIntermediateDirectories: true
        )
        XCTAssertEqual(SidecarStore.read(forPhotoAt: photoURL), .undecodable)
    }

    func testReadDecodesAPreviouslyWrittenSidecar() throws {
        var state = EditState.identity
        state.exposureEV = 1.5
        try SidecarStore.write(state, forPhotoAt: photoURL)

        XCTAssertEqual(SidecarStore.read(forPhotoAt: photoURL), .decoded(state))
    }

    // MARK: - write

    func testWriteThenReadRoundTrips() throws {
        var state = EditState.identity
        state.contrast = 0.4
        state.blackAndWhite = true

        try SidecarStore.write(state, forPhotoAt: photoURL)

        guard case .decoded(let decoded) = SidecarStore.read(forPhotoAt: photoURL) else {
            return XCTFail("expected .decoded")
        }
        XCTAssertEqual(decoded, state)
    }

    func testWriteOverwritesAnExistingSidecar() throws {
        var first = EditState.identity
        first.exposureEV = 1.0
        try SidecarStore.write(first, forPhotoAt: photoURL)

        var second = EditState.identity
        second.exposureEV = 2.0
        try SidecarStore.write(second, forPhotoAt: photoURL)

        XCTAssertEqual(SidecarStore.read(forPhotoAt: photoURL), .decoded(second))
    }

    /// `PhotoExporter.loadEditState(for:)` is the existing reader that
    /// folds `.missing`/`.undecodable` both into `.identity` — this pins
    /// that it still agrees with `SidecarStore.read` on the DECODED case,
    /// so the two readers can't silently drift apart now that both exist.
    func testPhotoExporterLoadEditStateAgreesWithSidecarStoreOnADecodedSidecar() throws {
        var state = EditState.identity
        state.vibrance = 0.3
        try SidecarStore.write(state, forPhotoAt: photoURL)

        let photo = Photo(
            id: 1, path: photoURL.path, filename: photoURL.lastPathComponent,
            fileSize: 0, importedAt: Date(), rating: 0, flagStatus: .none
        )
        XCTAssertEqual(PhotoExporter.loadEditState(for: photo), state)
        if case .decoded(let decoded) = SidecarStore.read(forPhotoAt: photoURL) {
            XCTAssertEqual(decoded, PhotoExporter.loadEditState(for: photo))
        } else {
            XCTFail("expected .decoded")
        }
    }
}
