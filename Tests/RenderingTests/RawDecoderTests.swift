import XCTest
@testable import PhotoApp

/// `RawDecoder.isRaw(_:)` is pure UTType classification, tested against
/// filenames only — no real RAW fixture needed (decode itself needs a real
/// RAW file and is covered by the live-verification pass, not asserted
/// here). `RawDecoder.decode`/`decodeDraft`'s non-RAW behavior is exercised
/// indirectly by `ThumbnailGeneratorTests`/`PhotoExporterTests`, which
/// already write real non-RAW fixtures and would fail if the RawDecoder
/// substitution changed non-RAW output.
final class RawDecoderTests: XCTestCase {
    func testClassifiesCommonRawExtensionsAsRaw() {
        let rawExtensions = ["nef", "cr2", "cr3", "arw", "dng", "raf", "orf", "rw2"]
        for ext in rawExtensions {
            let url = URL(fileURLWithPath: "/tmp/photo.\(ext)")
            XCTAssertTrue(RawDecoder.isRaw(url), "\(ext) should classify as RAW")
        }
    }

    func testClassifiesRawExtensionsCaseInsensitively() {
        XCTAssertTrue(RawDecoder.isRaw(URL(fileURLWithPath: "/tmp/DSC_1017.NEF")))
        XCTAssertTrue(RawDecoder.isRaw(URL(fileURLWithPath: "/tmp/IMG_0001.CR2")))
    }

    func testDoesNotClassifyNonRawImageExtensionsAsRaw() {
        let nonRawExtensions = ["jpg", "jpeg", "png", "tiff", "tif", "heic"]
        for ext in nonRawExtensions {
            let url = URL(fileURLWithPath: "/tmp/photo.\(ext)")
            XCTAssertFalse(RawDecoder.isRaw(url), "\(ext) should not classify as RAW")
        }
    }

    func testDoesNotClassifyNonImageOrUnknownExtensionsAsRaw() {
        XCTAssertFalse(RawDecoder.isRaw(URL(fileURLWithPath: "/tmp/notes.txt")))
        XCTAssertFalse(RawDecoder.isRaw(URL(fileURLWithPath: "/tmp/edits.photoapp.json")))
        XCTAssertFalse(RawDecoder.isRaw(URL(fileURLWithPath: "/tmp/no-extension")))
    }

    func testDecodeReturnsNilForAMissingFileRegardlessOfExtension() {
        XCTAssertNil(RawDecoder.decode(contentsOf: URL(fileURLWithPath: "/tmp/does-not-exist.nef")))
        XCTAssertNil(RawDecoder.decode(contentsOf: URL(fileURLWithPath: "/tmp/does-not-exist.jpg")))
    }

    func testDecodeDraftReturnsNilForAMissingFile() {
        XCTAssertNil(RawDecoder.decodeDraft(contentsOf: URL(fileURLWithPath: "/tmp/does-not-exist.nef"), maxPixelSize: 256))
    }
}
