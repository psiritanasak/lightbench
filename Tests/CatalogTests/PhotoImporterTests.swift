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
}
