import AVFoundation
import CoreGraphics
import ImageIO
import XCTest

/// A synthetic HEIC carrying an embedded DISPARITY map, so the embedded-depth path can be tested end to end without any of the user's own photos.
enum SyntheticDepthFixtures {
    /// Writes a `width x height` gray HEIC with EXIF `orientation`, and a `depthWidth x depthHeight` disparity map (stored frame) whose value is
    /// `0.1 + 0.05 * x` (increasing left to right in the STORED frame). `storedAsDepth` writes it as a metric DEPTH item (`1 / disparity`, DepthFloat32) instead of disparity. Throws `XCTSkip` if this machine cannot write such a file.
    static func writeHEIC(to url: URL, width: Int = 40, height: Int = 30, orientation: Int = 1, depthWidth: Int = 20, depthHeight: Int = 15, storedAsDepth: Bool = false) throws {
        var disparity = [Float](repeating: 0, count: depthWidth * depthHeight)
        for y in 0..<depthHeight { for x in 0..<depthWidth { disparity[y * depthWidth + x] = 0.1 + Float(x) * 0.05 } }
        var pixels = [UInt8](repeating: 128, count: width * height * 4)
        for i in 0..<(width * height) { pixels[i * 4 + 3] = 255 }
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: CGDataProvider(data: Data(pixels) as CFData)!,
                                          decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.heic" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        let auxiliary: [String: Any] = [
            kCGImageAuxiliaryDataInfoData as String: disparity.withUnsafeBufferPointer { Data(buffer: $0) },
            kCGImageAuxiliaryDataInfoDataDescription as String: ["Width": depthWidth, "Height": depthHeight, "BytesPerRow": depthWidth * 4,
                                                                  "PixelFormat": kCVPixelFormatType_DisparityFloat32] as [String: Any],
        ]
        if storedAsDepth {
            let depth = disparity.map { 1 / $0 }
            var asDepth = auxiliary
            asDepth[kCGImageAuxiliaryDataInfoData as String] = depth.withUnsafeBufferPointer { Data(buffer: $0) }
            asDepth[kCGImageAuxiliaryDataInfoDataDescription as String] = ["Width": depthWidth, "Height": depthHeight, "BytesPerRow": depthWidth * 4,
                                                                          "PixelFormat": kCVPixelFormatType_DepthFloat32] as [String: Any]
            CGImageDestinationAddAuxiliaryDataInfo(dest, kCGImageAuxiliaryDataTypeDepth, asDepth as CFDictionary)
        } else {
            CGImageDestinationAddAuxiliaryDataInfo(dest, kCGImageAuxiliaryDataTypeDisparity, auxiliary as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw XCTSkip("this machine could not write a HEIC with an auxiliary disparity map") }
    }
}
