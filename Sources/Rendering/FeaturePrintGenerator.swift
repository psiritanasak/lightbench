import Foundation
import ImageIO
import Vision

/// Vision feature prints for duplicate detection. With `SubjectMaskGenerator` this is one of the two files that import
/// Vision. The request revision is PINNED (a new SDK default must not silently change cached prints; the cache stores the
/// revision and the scanner recomputes on a mismatch).
enum FeaturePrintGenerator {
    static let revision = VNGenerateImageFeaturePrintRequestRevision2
    /// Long edge of the image the print is computed from.
    static let maxPixelSize = 512

    /// The print of the image in the file at `url`, from ImageIO's thumbnail (EXIF-oriented). For RAW this is the
    /// embedded preview, so no RAW decode happens and `RawDecoder.RenderGate` is never touched (a 930-NEF scan must
    /// not starve the Editor; measured ~41 ms per NEF in docs/ROADMAP_HISTORY.md). nil when the file cannot be decoded.
    static func fingerprint(ofFileAt url: URL) -> Data? {
        thumbnail(ofFileAt: url).flatMap(fingerprint(of:))
    }

    /// The oriented image the print is computed from. `FromImageIfAbsent` prefers an EMBEDDED thumbnail — wanted for a
    /// RAW's large preview (no decode), but a camera JPEG's EXIF thumbnail is ~160 px and an editor that rewrites pixels may
    /// leave a STALE one behind (two different images would then print identically). So when the result is well under
    /// `maxPixelSize`, regenerate from the real image data.
    static func thumbnail(ofFileAt url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        func make(always: Bool) -> CGImage? {
            CGImageSourceCreateThumbnailAtIndex(source, 0, [
                (always ? kCGImageSourceCreateThumbnailFromImageAlways : kCGImageSourceCreateThumbnailFromImageIfAbsent): true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ] as CFDictionary)
        }
        guard let first = make(always: false) else { return nil }
        // Never for RAW: `FromImageAlways` on a RAW is a FULL RAW decode, which would run outside `RawDecoder.RenderGate` in a
        // loop over the library. A RAW keeps whatever embedded preview it has.
        if RawDecoder.isRaw(url) { return first }
        if max(first.width, first.height) * 10 >= maxPixelSize * 9 { return first }
        return make(always: true) ?? first
    }

    static func fingerprint(of image: CGImage) -> Data? {
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = revision
        guard (try? VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])) != nil,
              let observation = request.results?.first,
              observation.elementType == .float, observation.elementCount == FeaturePrintVector.elementCount
        else { return nil }
        return observation.data
    }
}
