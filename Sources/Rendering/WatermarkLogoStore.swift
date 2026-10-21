import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Content-addressed folder of logo images used by the export watermark (`Application Support/PhotoApp/WatermarkLogos/`).
/// A logo is imported ONCE: decoded, downscaled to `maximumLongEdge`, re-encoded as PNG (alpha kept) and stored as
/// `<sha256 of the PNG bytes>.png`, so importing the same picture twice shares one file and the settings only ever carry
/// the id. The original file is only read, never modified or referenced again (a logo keeps working after the user moves it).
struct WatermarkLogoStore: Sendable {
    enum ImportError: LocalizedError, Equatable {
        case unreadable
        case tooLarge(bytes: Int)
        case tooManyPixels
        case encodeFailed
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .unreadable: return "That file isn't a PNG, JPEG or HEIC image the app can read."
            case .tooLarge(let bytes):
                return "That file is too large for a logo (\(bytes / 1_000_000) MB; the limit is \(WatermarkLogoStore.maximumSourceBytes / 1_000_000) MB)."
            case .tooManyPixels: return "That image has too many pixels to use as a logo."
            case .encodeFailed: return "The logo could not be converted."
            case .writeFailed: return "The logo could not be saved."
            }
        }
    }

    /// Stored logos are downscaled (never upscaled) so the long edge is at most this many pixels.
    static let maximumLongEdge = 1024
    /// Source files above this size are refused before decoding.
    static let maximumSourceBytes = 20_000_000
    /// Source images above this many pixels (either side) are refused before decoding.
    static let maximumSourceSide = 30_000
    /// Source images above this many pixels IN TOTAL are refused before decoding. A PNG cannot be shrunk while it is
    /// decoded, so a flat 30000 x 29999 file well under the byte cap would still need gigabytes of RAM.
    static let defaultMaximumSourcePixels = 100_000_000

    let directory: URL
    let maximumSourcePixels: Int

    init(directory: URL, maximumSourcePixels: Int = WatermarkLogoStore.defaultMaximumSourcePixels) {
        self.directory = directory
        self.maximumSourcePixels = maximumSourcePixels
    }

    /// Pixel width and height the file's header claims, or nil when they cannot be read (such a file is refused).
    static func pixelSize(of source: CGImageSource) -> (width: Int, height: Int)? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        return (width, height)
    }

    /// The app's real logo folder. Under XCTest it is a throwaway temp folder so tests never touch Application Support.
    static func defaultDirectory(isRunningUnderXCTest: Bool = CatalogDatabase.isRunningUnderXCTest) -> URL {
        if isRunningUnderXCTest {
            return FileManager.default.temporaryDirectory.appendingPathComponent(
                "PhotoApp-XCTest-logos-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("PhotoApp", isDirectory: true).appendingPathComponent("WatermarkLogos", isDirectory: true)
    }

    static let shared = WatermarkLogoStore(directory: defaultDirectory())

    // MARK: Ids

    /// A well-formed id is 64 lowercase hex characters. Settings come from UserDefaults, so an id is never trusted as a
    /// path component without this check (`../x` must not escape the folder).
    static func isValidID(_ id: String) -> Bool {
        id.utf8.count == 64 && id.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }

    func fileURL(forID id: String) -> URL? {
        guard Self.isValidID(id) else { return nil }
        return directory.appendingPathComponent(id).appendingPathExtension("png")
    }

    // MARK: Import

    /// Imports the picture at `source`; returns its id. Idempotent: the same picture gives the same id.
    func importLogo(from source: URL) throws -> String {
        // An unreadable size is a refusal, never "0 bytes".
        guard let size = try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize else { throw ImportError.unreadable }
        guard size <= Self.maximumSourceBytes else { throw ImportError.tooLarge(bytes: size) }
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil), CGImageSourceGetCount(imageSource) > 0,
              let type = CGImageSourceGetType(imageSource).flatMap({ UTType($0 as String) }),
              type.conforms(to: .png) || type.conforms(to: .jpeg) || type.conforms(to: .heic)
        else { throw ImportError.unreadable }
        // Dimensions that cannot be read are a refusal too: the size checks below are the only guard against a decode bomb.
        guard let pixels = Self.pixelSize(of: imageSource) else { throw ImportError.unreadable }
        guard max(pixels.width, pixels.height) <= Self.maximumSourceSide,
              pixels.width <= maximumSourcePixels / pixels.height else { throw ImportError.tooManyPixels }
        // The thumbnail API downsamples while decoding (cheap for a big source) and applies the orientation tag.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.maximumLongEdge
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else { throw ImportError.unreadable }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw ImportError.encodeFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ImportError.encodeFailed }

        let id = SHA256.hash(data: data as Data).map { String(format: "%02x", $0) }.joined()
        guard let url = fileURL(forID: id) else { throw ImportError.encodeFailed }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Write when absent, or when the stored file no longer decodes (a damaged file heals on re-import).
            if !FileManager.default.fileExists(atPath: url.path) || loadImage(id: id) == nil {
                try (data as Data).write(to: url, options: .atomic)
            }
        } catch {
            throw ImportError.writeFailed
        }
        return id
    }

    // MARK: Load

    /// The stored logo, or nil when the id is malformed, the file is gone, its bytes do not hash to its id (the store is
    /// content-addressed, so any truncation or damage is detected exactly; ImageIO alone decodes lazily and would accept
    /// a PNG cut off after its header) or it does not decode. An export therefore never draws a damaged logo.
    func loadImage(id: String) -> CGImage? {
        guard let url = fileURL(forID: id), let data = try? Data(contentsOf: url),
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == id,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
