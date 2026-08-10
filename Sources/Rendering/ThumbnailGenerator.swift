import ImageIO
import Foundation

/// Pure, stateless thumbnail decoding — no UI, no `CIContext`. Unlike the
/// `PixelSampler`/`ImageAverageColor`/`Histogram` family (which build a
/// `CIImage` for numeric analysis), a library grid just needs a small,
/// already-oriented bitmap to display, so ImageIO's own thumbnail API is a
/// better fit: it decodes straight to a downsized `CGImage` without ever
/// materializing the full-resolution image, and applies EXIF orientation
/// for us (`kCGImageSourceCreateThumbnailWithTransform`), unlike
/// `ImageDocumentModel.load(from:)`'s `CIImage(contentsOf:).oriented(...)`
/// path which has to do that step itself.
enum ThumbnailGenerator {
    /// Returns a thumbnail for the image at `url`, no larger than
    /// `maxPixelSize` on its longest side, or `nil` if `url` isn't a
    /// readable image (missing, unreadable, unsupported format). Safe to
    /// call off the main thread — does no UI work.
    static func thumbnail(for url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
