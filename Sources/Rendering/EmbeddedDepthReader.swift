import AVFoundation
import Foundation
import ImageIO

/// Reads the depth an iPhone embeds in a photo (an ImageIO auxiliary DISPARITY map: larger = nearer) and returns it UPRIGHT, in the frame
/// `RawDecoder.decode` produces (EXIF orientation applied), as plain Float32 — the form `DepthNormalizer` takes.
///
/// Measured in the Depth Range spike (`EmbeddedDepthProbeTests`): every sample map is `hdis` (DisparityFloat16), 576x768 or 768x576, finite, and has
/// the oriented image's aspect after `applyingExifOrientation`. Disparity is stereo-derived: usable for close subjects, noisy beyond a few metres.
/// Pure file reading; no UI, safe off the main thread.
enum EmbeddedDepthReader {
    struct Field {
        /// Row-major, row 0 = top, larger = nearer. Non-finite values are possible (holes) and left for `DepthNormalizer` to handle.
        let values: [Float]
        let width: Int
        let height: Int
    }

    /// The first auxiliary depth item the file carries: DISPARITY (every iPhone file sampled) or, failing that, DEPTH. `AVDepthData` converts either to
    /// Float32 disparity below, so the rest of the reader does not care which it got.
    private static func auxiliaryInfo(_ source: CGImageSource) -> [AnyHashable: Any]? {
        for type in [kCGImageAuxiliaryDataTypeDisparity, kCGImageAuxiliaryDataTypeDepth] {
            if let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type) as? [AnyHashable: Any] { return info }
        }
        return nil
    }

    /// True when the file carries an auxiliary disparity or depth map. Cheap enough for UI state (it copies the small map's metadata, not the photo).
    static func hasEmbeddedDepth(at url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return auxiliaryInfo(source) != nil
    }

    /// The upright disparity field, or nil when the file has none or it cannot be read.
    static func readUpright(at url: URL) -> Field? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let info = auxiliaryInfo(source),
              let depth = try? AVDepthData(fromDictionaryRepresentation: info)
        else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let raw = (props?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: raw) ?? .up
        let buffer = depth.applyingExifOrientation(orientation).converting(toDepthDataType: kCVPixelFormatType_DisparityFloat32).depthDataMap
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_DisparityFloat32,
              let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: Float.self) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer), stride = CVPixelBufferGetBytesPerRow(buffer) / MemoryLayout<Float>.size
        guard width > 0, height > 0 else { return nil }
        var values = [Float](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width { values[y * width + x] = base[y * stride + x] } }
        return Field(values: values, width: width, height: height)
    }
}
