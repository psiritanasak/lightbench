import AVFoundation
import ImageIO
import XCTest

/// PERMANENT probe for Depth Range: what an iPhone HEIC's embedded disparity map really looks like through ImageIO + AVDepthData (docs/ROADMAP_HISTORY.md
/// "Depth Range spike"). Reads the user's own files read-only; every test SKIPS when the file is not present. Nothing in `Sources/` uses it yet.
final class EmbeddedDepthProbeTests: XCTestCase {
    private static let candidates = [
        "~/Downloads/IMG_0029.heic",
        "~/Pictures/Photos Library.photoslibrary/originals/9/923DE576-07D2-45AE-B6E8-5FB9C6AE8672.heic",
        "~/Pictures/Photos Library.photoslibrary/originals/9/93C14914-1D06-430B-B371-CB854E1D3704.heic",
        "~/Pictures/Photos Library.photoslibrary/originals/9/99652381-C371-4B2C-9D2B-1A6CCBAF553C.heic",
        "~/Pictures/Photos Library.photoslibrary/originals/9/979CF353-26D9-4DA5-AD43-21A6BB41FC17.heic",
        "~/Pictures/Photos Library.photoslibrary/originals/0/02B1A43B-87BF-4843-93E8-1D55C13FF301.heic",
    ].map { NSString(string: $0).expandingTildeInPath }

    struct Stats { var width = 0, height = 0, minimum: Float = .infinity, maximum: Float = -.infinity, mean: Float = 0, nan = 0, typeName = "" }

    private func readDisparity(_ path: String) throws -> (stats: Stats, map: [Float], imageSize: CGSize, orientation: Int)? {
        guard FileManager.default.isReadableFile(atPath: path) else { return nil }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        guard let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeDisparity) as? [AnyHashable: Any] else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let size = CGSize(width: (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0, height: (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0)
        let depth = try AVDepthData(fromDictionaryRepresentation: info)
        let typeName = String(format: "%08x", depth.depthDataType)
        let oriented = depth.applyingExifOrientation(CGImagePropertyOrientation(rawValue: UInt32(orientation)) ?? .up)
        let converted = oriented.converting(toDepthDataType: kCVPixelFormatType_DisparityFloat32)
        let buffer = converted.depthDataMap
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer), stride = CVPixelBufferGetBytesPerRow(buffer) / 4
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: Float.self) else { return nil }
        var s = Stats(); s.width = w; s.height = h; s.typeName = typeName
        var map = [Float](repeating: 0, count: w * h)
        var sum: Double = 0, n = 0
        for y in 0..<h { for x in 0..<w {
            let v = base[y * stride + x]
            map[y * w + x] = v
            if v.isNaN || v.isInfinite { s.nan += 1; continue }
            s.minimum = min(s.minimum, v); s.maximum = max(s.maximum, v); sum += Double(v); n += 1
        } }
        s.mean = n > 0 ? Float(sum / Double(n)) : 0
        return (s, map, size, orientation)
    }

    /// Every available file: the map reads, converts to Float32 disparity, is finite, and its ASPECT matches the ORIENTED image (portrait photos have a
    /// portrait depth map after `applyingExifOrientation`, not the sensor-frame landscape one).
    func testEmbeddedDisparityReadsOrientsAndMatchesTheImageAspect() throws {
        var read = 0
        for path in Self.candidates {
            guard let r = try readDisparity(path) else { continue }
            read += 1
            let orientedImage = [5, 6, 7, 8].contains(r.orientation) ? CGSize(width: r.imageSize.height, height: r.imageSize.width) : r.imageSize
            let imageAspect = orientedImage.width / max(orientedImage.height, 1), mapAspect = CGFloat(r.stats.width) / CGFloat(max(r.stats.height, 1))
            print("PROBE depth \((path as NSString).lastPathComponent): type \(r.stats.typeName) \(r.stats.width)x\(r.stats.height) orientation \(r.orientation) image \(Int(r.imageSize.width))x\(Int(r.imageSize.height)) range \(r.stats.minimum)...\(r.stats.maximum) mean \(r.stats.mean) nonFinite \(r.stats.nan) aspect image \(imageAspect) map \(mapAspect)")
            XCTAssertEqual(r.stats.nan, 0, "\(path)")
            XCTAssertGreaterThan(r.stats.maximum, r.stats.minimum, "a depth map with no variation is useless: \(path)")
            XCTAssertEqual(mapAspect, imageAspect, accuracy: 0.08, "the oriented depth map must have the oriented image's aspect: \(path)")
        }
        if read == 0 { throw XCTSkip("none of the sample iPhone depth files is present on this machine") }
    }
}
