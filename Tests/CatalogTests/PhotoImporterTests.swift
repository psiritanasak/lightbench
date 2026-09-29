import XCTest
@testable import PhotoApp

/// `PhotoImporter.imageFiles(in:)` is pure filesystem enumeration + filtering
/// — tested against a real temp directory, no DB involved.
final class PhotoImporterTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoImporterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func touch(_ name: String) throws {
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent(name).path, contents: Data())
    }

    func testReturnsOnlySupportedImageExtensions() throws {
        try touch("photo.jpg")
        try touch("photo.png")
        try touch("readme.txt")
        try touch("notes.pdf")

        let found = Set(PhotoImporter.imageFiles(in: tempDir).map(\.lastPathComponent))

        XCTAssertEqual(found, ["photo.jpg", "photo.png"])
    }

    func testMatchesExtensionsCaseInsensitively() throws {
        try touch("PHOTO.JPG")
        try touch("Photo.HEIC")

        let found = Set(PhotoImporter.imageFiles(in: tempDir).map(\.lastPathComponent))

        XCTAssertEqual(found, ["PHOTO.JPG", "Photo.HEIC"])
    }

    func testExcludesSidecarJSONFiles() throws {
        try touch("IMG_0001.jpg")
        try touch("IMG_0001.jpg.photoapp.json")

        let found = PhotoImporter.imageFiles(in: tempDir).map(\.lastPathComponent)

        XCTAssertEqual(found, ["IMG_0001.jpg"])
    }

    func testIncludesCameraRawFiles() throws {
        try touch("DSC_1017.NEF")
        try touch("photo.jpg")
        try touch("readme.txt")

        let found = Set(PhotoImporter.imageFiles(in: tempDir).map(\.lastPathComponent))

        XCTAssertEqual(found, ["DSC_1017.NEF", "photo.jpg"])
    }

    func testMatchesRawExtensionsCaseInsensitively() throws {
        try touch("IMG_0001.cr2")
        try touch("IMG_0002.CR2")
        try touch("IMG_0003.dng")

        let found = Set(PhotoImporter.imageFiles(in: tempDir).map(\.lastPathComponent))

        XCTAssertEqual(found, ["IMG_0001.cr2", "IMG_0002.CR2", "IMG_0003.dng"])
    }

    func testEmptyFolderReturnsEmptyArray() {
        XCTAssertEqual(PhotoImporter.imageFiles(in: tempDir), [])
    }

    func testNonexistentFolderReturnsEmptyArrayRatherThanThrowing() {
        let missing = tempDir.appendingPathComponent("does-not-exist", isDirectory: true)
        XCTAssertEqual(PhotoImporter.imageFiles(in: missing), [])
    }

    // MARK: - scanFolderTree (folder-mirrored nested collections)

    private func makeDir(_ relativePath: String) throws -> URL {
        let url = tempDir.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func touch(_ name: String, in folder: URL) {
        FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data())
    }

    func testScanFolderTreeBuildsNestedStructureMatchingYearTripDay() throws {
        let year = try makeDir("2024")
        let trip = try makeDir("2024/Japan-Trip")
        let day1 = try makeDir("2024/Japan-Trip/Day1")
        let day2 = try makeDir("2024/Japan-Trip/Day2")
        touch("cover.jpg", in: year)
        touch("group.jpg", in: trip)
        touch("a.jpg", in: day1)
        touch("b.jpg", in: day1)
        touch("c.jpg", in: day2)

        let node = try XCTUnwrap(PhotoImporter.scanFolderTree(at: year))

        XCTAssertEqual(node.imageFiles.map(\.lastPathComponent), ["cover.jpg"])
        let tripNode = try XCTUnwrap(node.children.first(where: { $0.url.lastPathComponent == "Japan-Trip" }))
        XCTAssertEqual(tripNode.imageFiles.map(\.lastPathComponent), ["group.jpg"])
        XCTAssertEqual(tripNode.children.count, 2)
        let day1Node = try XCTUnwrap(tripNode.children.first(where: { $0.url.lastPathComponent == "Day1" }))
        XCTAssertEqual(Set(day1Node.imageFiles.map(\.lastPathComponent)), ["a.jpg", "b.jpg"])
        let day2Node = try XCTUnwrap(tripNode.children.first(where: { $0.url.lastPathComponent == "Day2" }))
        XCTAssertEqual(day2Node.imageFiles.map(\.lastPathComponent), ["c.jpg"])
    }

    func testScanFolderTreeExcludesSubfoldersWithNoImagesAnywhere() throws {
        let root = try makeDir("root")
        let withPhoto = try makeDir("root/HasPhoto")
        _ = try makeDir("root/Empty")
        _ = try makeDir("root/OnlyNonImages")
        touch("a.jpg", in: withPhoto)
        touch("notes.txt", in: tempDir.appendingPathComponent("root/OnlyNonImages"))

        let node = try XCTUnwrap(PhotoImporter.scanFolderTree(at: root))

        XCTAssertEqual(node.children.map(\.url.lastPathComponent), ["HasPhoto"])
    }

    func testScanFolderTreeReturnsNilForEntirelyEmptyRoot() throws {
        let root = try makeDir("empty-root")
        _ = try makeDir("empty-root/AlsoEmpty")

        XCTAssertNil(PhotoImporter.scanFolderTree(at: root))
    }

    func testScanFolderTreeIncludesRawFiles() throws {
        let root = try makeDir("raw-root")
        touch("DSC_1017.NEF", in: root)

        let node = try XCTUnwrap(PhotoImporter.scanFolderTree(at: root))

        XCTAssertEqual(node.imageFiles.map(\.lastPathComponent), ["DSC_1017.NEF"])
    }

    func testScanFolderTreeReturnsNilWhenRootHasOnlyNonImageFiles() throws {
        let root = try makeDir("non-image-root")
        touch("readme.txt", in: root)

        XCTAssertNil(PhotoImporter.scanFolderTree(at: root))
    }

    /// Regression pin, not a bug fix: `root/loop` is a real on-disk symlink
    /// pointing BACK at `root` itself. `scanNode` was never actually
    /// vulnerable to recursing into this (see its own doc comment —
    /// `URL.resourceValues(forKeys: [.isDirectoryKey])` reports the LINK's
    /// own type, not the resolved target's, so a symlinked directory
    /// already reports `isDirectory == false` today, verified directly).
    /// This test exists so a future change that made `scanNode` follow
    /// symlinks (e.g. swapping in `resolvingSymlinksInPath()`) would be
    /// caught immediately, rather than only failing much later as a hang.
    func testScanFolderTreeDoesNotRecurseIntoASelfReferencingSymlinkCycle() throws {
        let root = try makeDir("cycle-root")
        touch("real.jpg", in: root)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("loop"), withDestinationURL: root
        )

        let node = try XCTUnwrap(PhotoImporter.scanFolderTree(at: root))

        XCTAssertEqual(node.imageFiles.map(\.lastPathComponent), ["real.jpg"])
        XCTAssertTrue(node.children.isEmpty, "the symlinked directory must not be recursed into at all")
    }

    /// The same regression pin as the test above, for a longer cycle
    /// through two real folders (A's own child symlinks to B, B's own
    /// child symlinks back to A) rather than a directly self-referencing
    /// one — same underlying already-correct behavior, a different shape.
    func testScanFolderTreeDoesNotRecurseIntoAMutualSymlinkCycle() throws {
        let a = try makeDir("cycle2/a")
        let b = try makeDir("cycle2/b")
        touch("in_a.jpg", in: a)
        touch("in_b.jpg", in: b)
        try FileManager.default.createSymbolicLink(at: a.appendingPathComponent("to_b"), withDestinationURL: b)
        try FileManager.default.createSymbolicLink(at: b.appendingPathComponent("to_a"), withDestinationURL: a)

        let root = try XCTUnwrap(PhotoImporter.scanFolderTree(at: tempDir.appendingPathComponent("cycle2")))

        let aNode = try XCTUnwrap(root.children.first(where: { $0.url.lastPathComponent == "a" }))
        let bNode = try XCTUnwrap(root.children.first(where: { $0.url.lastPathComponent == "b" }))
        XCTAssertEqual(aNode.imageFiles.map(\.lastPathComponent), ["in_a.jpg"])
        XCTAssertEqual(bNode.imageFiles.map(\.lastPathComponent), ["in_b.jpg"])
        XCTAssertTrue(aNode.children.isEmpty)
        XCTAssertTrue(bNode.children.isEmpty)
    }

    // MARK: - confirmedActiveFolderRoot (D5, IMPROVEMENTS.md — missing-file detection)

    func testConfirmedActiveFolderRootMatchesAPhotoDirectlyUnderAnActiveFolder() {
        let activeFolders: Set<String> = ["/Users/x/Trip"]

        XCTAssertEqual(
            PhotoImporter.confirmedActiveFolderRoot(
                forPhotoAt: "/Users/x/Trip/photo.jpg", activeFolders: activeFolders
            ),
            "/Users/x/Trip"
        )
    }

    /// Folder-tree imports only bookmark the ROOT — a photo several levels
    /// deep under that root must still match.
    func testConfirmedActiveFolderRootMatchesAPhotoInANestedSubfolder() {
        let activeFolders: Set<String> = ["/Users/x/Trip"]

        XCTAssertEqual(
            PhotoImporter.confirmedActiveFolderRoot(
                forPhotoAt: "/Users/x/Trip/Day1/Morning/photo.jpg", activeFolders: activeFolders
            ),
            "/Users/x/Trip"
        )
    }

    func testConfirmedActiveFolderRootIsNilWhenNoFolderIsActive() {
        XCTAssertNil(
            PhotoImporter.confirmedActiveFolderRoot(forPhotoAt: "/Users/x/Trip/photo.jpg", activeFolders: [])
        )
    }

    /// The reason for the `+ "/"` suffix in the implementation: a naive
    /// `hasPrefix` without it would wrongly match a sibling folder that
    /// merely shares a string prefix.
    func testConfirmedActiveFolderRootDoesNotMatchASimilarlyNamedSiblingFolder() {
        let activeFolders: Set<String> = ["/Users/x/Trip"]

        XCTAssertNil(
            PhotoImporter.confirmedActiveFolderRoot(
                forPhotoAt: "/Users/x/Trip2/photo.jpg", activeFolders: activeFolders
            )
        )
    }

    /// Reviewer-flagged gap: `activeFolders` entries come from `URL.path`,
    /// which never carries a trailing slash — but pin the assumption
    /// directly, since the whole prefix check rests on it.
    func testConfirmedActiveFolderRootIsNilWhenActiveFolderHasATrailingSlash() {
        let activeFolders: Set<String> = ["/Users/x/Trip/"]

        XCTAssertNil(
            PhotoImporter.confirmedActiveFolderRoot(
                forPhotoAt: "/Users/x/Trip/photo.jpg", activeFolders: activeFolders
            ),
            "activeFolders entries are assumed never to carry a trailing slash"
        )
    }

    /// Degenerate case: a photo path can never legitimately EQUAL an
    /// active folder's own path (a folder isn't a photo file), but the
    /// prefix check must not match this either.
    func testConfirmedActiveFolderRootIsNilWhenPhotoPathEqualsTheActiveFolder() {
        let activeFolders: Set<String> = ["/Users/x/Trip"]

        XCTAssertNil(
            PhotoImporter.confirmedActiveFolderRoot(forPhotoAt: "/Users/x/Trip", activeFolders: activeFolders)
        )
    }

    /// Two active roots can both match the same photo (a flat import of
    /// `/Trip/Day1` followed later by a tree import of `/Trip` itself puts
    /// BOTH in `activeFolders`) — the longest (most specific) match must
    /// win deterministically, not whichever `Set` happens to iterate first.
    func testConfirmedActiveFolderRootPicksTheLongestMatchWhenMultipleRootsMatch() {
        let activeFolders: Set<String> = ["/Users/x/Trip", "/Users/x/Trip/Day1"]

        XCTAssertEqual(
            PhotoImporter.confirmedActiveFolderRoot(
                forPhotoAt: "/Users/x/Trip/Day1/photo.jpg", activeFolders: activeFolders
            ),
            "/Users/x/Trip/Day1"
        )
    }

    // MARK: - matchByFilename (D5 follow-up — relocating missing photos)

    private func makePhoto(id: Int64, filename: String) -> Photo {
        Photo(id: id, path: "/tmp/gone/\(filename)", filename: filename, fileSize: nil, importedAt: Date())
    }

    func testMatchByFilenameMatchesCaseInsensitively() throws {
        try touch("Photo.JPG")
        let photo = makePhoto(id: 1, filename: "photo.jpg")

        let (moves, unmatchedCount) = PhotoImporter.matchByFilename([photo], in: tempDir)

        XCTAssertEqual(moves.count, 1)
        XCTAssertEqual(moves.first?.photoID, 1)
        XCTAssertEqual(moves.first?.newPath, tempDir.appendingPathComponent("Photo.JPG").path)
        XCTAssertEqual(unmatchedCount, 0)
    }

    func testMatchByFilenameCountsUnmatchedPhotos() throws {
        try touch("found.jpg")
        let found = makePhoto(id: 1, filename: "found.jpg")
        let notFound = makePhoto(id: 2, filename: "missing.jpg")

        let (moves, unmatchedCount) = PhotoImporter.matchByFilename([found, notFound], in: tempDir)

        XCTAssertEqual(moves.map(\.photoID), [1])
        XCTAssertEqual(unmatchedCount, 1)
    }

    /// `matchByFilename` reuses `imageFiles(in:)`, which already excludes
    /// sidecar/non-image files — this just confirms that filtering still
    /// applies here, not a re-test of `imageFiles(in:)` itself.
    func testMatchByFilenameIgnoresNonImageFilesInTheFolder() throws {
        try touch("photo.jpg.photoapp.json") // a sidecar, not an image
        let photo = makePhoto(id: 1, filename: "photo.jpg.photoapp.json")

        let (moves, unmatchedCount) = PhotoImporter.matchByFilename([photo], in: tempDir)

        XCTAssertTrue(moves.isEmpty)
        XCTAssertEqual(unmatchedCount, 1)
    }
}
