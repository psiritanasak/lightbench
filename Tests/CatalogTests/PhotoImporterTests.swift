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

    func testScanFolderTreeReturnsNilWhenRootHasOnlyNonImageFiles() throws {
        let root = try makeDir("non-image-root")
        touch("readme.txt", in: root)

        XCTAssertNil(PhotoImporter.scanFolderTree(at: root))
    }
}
