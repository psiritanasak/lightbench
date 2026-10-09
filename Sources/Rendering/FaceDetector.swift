import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// On-device face detection for the People feature: Vision finds the faces, each face gets a padded square crop, and the crop's
/// feature print (`FeaturePrintGenerator`, the same pinned revision the duplicate scan uses) is what grouping compares. Vision has no
/// public face-IDENTITY embedding, so the general-purpose print on a crop is the only on-device option without a bundled model;
/// its accuracy was measured on real faces in the 2026-10-09 spike (docs/ROADMAP_HISTORY.md: no roll alignment, 40 % padding).
///
/// Reads image files only; never writes anything. Synchronous — call it off the main thread.
enum FaceDetector {
    /// Both requests are PINNED (a new SDK default must not silently change which faces are stored). The scan record stores ONE
    /// number, so it combines them: `rectangles * 100 + quality`; a change in either invalidates stored scans.
    static let rectanglesRevision = VNDetectFaceRectanglesRequestRevision3
    static let qualityRevision = VNDetectFaceCaptureQualityRequestRevision2
    static let detectRevision = rectanglesRevision * 100 + qualityRevision
    /// Long edge of the image faces are found in. Larger than the duplicate scan's 512: a face is ~5 % of a group photo's width.
    static let thumbnailPixelSize = 1600
    /// Faces narrower than this many pixels (at `thumbnailPixelSize`) are not kept: too small to tell apart.
    static let minimumFaceWidth = 40.0
    /// `VNDetectFaceCaptureQualityRequest` floor (0...1): blurred crowd faces scored 0.08-0.11, usable ones 0.30-0.81 in the spike.
    static let minimumQuality = 0.15
    /// Extra context around the face box, as a fraction of its larger side on EACH side (the spike's best simple variant).
    static let cropPadding = 0.4
    /// The crop is resized to this square before it is printed.
    static let printSide = 224
    /// The stored tile is this square.
    static let tileSide = 96

    struct DetectedFace: Equatable, Sendable {
        /// Fractions of the oriented image, origin TOP-left.
        var x: Double, y: Double, w: Double, h: Double
        var quality: Double
        var featurePrint: Data
        var crop: Data?
    }

    // MARK: Pure helpers (unit-tested)

    /// Vision's normalised box has its origin at the BOTTOM-left; the catalog stores top-left.
    static func topLeftBox(fromVision rect: CGRect) -> (x: Double, y: Double, w: Double, h: Double) {
        (Double(rect.minX), Double(1 - rect.maxY), Double(rect.width), Double(rect.height))
    }

    /// The padded square around a face, in pixels, kept inside the image (so near an edge it may be narrower than square).
    static func cropRect(box: (x: Double, y: Double, w: Double, h: Double), imageWidth: Int, imageHeight: Int, padding: Double = cropPadding) -> CGRect {
        let width = Double(imageWidth), height = Double(imageHeight)
        let centerX = (box.x + box.w / 2) * width, centerY = (box.y + box.h / 2) * height
        let side = max(box.w * width, box.h * height) * (1 + 2 * padding)
        let rect = CGRect(x: centerX - side / 2, y: centerY - side / 2, width: side, height: side)
        return rect.intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
    }

    static func passesFilters(widthPixels: Double, quality: Double) -> Bool {
        widthPixels >= minimumFaceWidth && quality >= minimumQuality
    }

    // MARK: Detection

    /// A face box with its capture quality, as returned by Vision (box origin BOTTOM-left).
    struct ScoredBox: Equatable {
        var box: CGRect
        var quality: Float?
    }

    /// The boxes with usable scores, or nil when ANY score is missing: a face without a quality is a failed detection (the photo
    /// must be retried), never a quality of 0 that would drop the face and record the photo as faceless forever.
    static func scored(_ results: [ScoredBox]) -> [(box: CGRect, quality: Double)]? {
        var out: [(box: CGRect, quality: Double)] = []
        for result in results {
            guard let quality = result.quality else { return nil }
            out.append((result.box, Double(quality)))
        }
        return out
    }

    /// The faces in the file, or nil when the image cannot be decoded or detection FAILED (the caller then records nothing and retries
    /// next scan). RAW uses its embedded preview (`FeaturePrintGenerator.thumbnail`), so no RAW decode runs and `RawDecoder.RenderGate`
    /// is never touched. The per-photo objects (a ~10 MB image plus Vision buffers) are drained here, not at the end of a long loop.
    static func detect(inFileAt url: URL) -> [DetectedFace]? {
        autoreleasepool {
            FeaturePrintGenerator.thumbnail(ofFileAt: url, pixelSize: thumbnailPixelSize).flatMap(detect(in:))
        }
    }

    /// `[]` means "looked, found no usable face"; `nil` means "could not look" (a failed request, a missing score, a crop that could
    /// not be printed): never recorded as faceless.
    static func detect(in image: CGImage) -> [DetectedFace]? {
        let rectangles = VNDetectFaceRectanglesRequest()
        rectangles.revision = rectanglesRevision
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        guard (try? handler.perform([rectangles])) != nil else { return nil }
        guard let observations = rectangles.results, !observations.isEmpty else { return [] }
        // Quality is requested FOR these observations; each result is itself a face observation with its own box and score, so a box
        // and its score can never be paired by position.
        let quality = VNDetectFaceCaptureQualityRequest()
        quality.revision = qualityRevision
        quality.inputFaceObservations = observations
        guard (try? handler.perform([quality])) != nil, let results = quality.results, results.count == observations.count,
              let scored = scored(results.map { ScoredBox(box: $0.boundingBox, quality: $0.faceCaptureQuality) }) else { return nil }
        var faces: [DetectedFace] = []
        for entry in scored {
            let box = topLeftBox(fromVision: entry.box)
            guard passesFilters(widthPixels: box.w * Double(image.width), quality: entry.quality) else { continue }
            let rect = cropRect(box: box, imageWidth: image.width, imageHeight: image.height)
            guard let cropped = image.cropping(to: rect), let printable = squareFit(cropped, side: printSide),
                  let print = FeaturePrintGenerator.fingerprint(of: printable) else { return nil }
            let tile = squareFit(cropped, side: tileSide).flatMap(jpegData(from:))
            faces.append(DetectedFace(x: box.x, y: box.y, w: box.w, h: box.h, quality: entry.quality, featurePrint: print, crop: tile))
        }
        return faces
    }

    // MARK: Image helpers

    /// The image drawn into a `side` x `side` square keeping its aspect ratio (a crop near the frame edge is not square; stretching it
    /// would distort the face), centred on mid-grey. NOTE: the 2026-10-09 spike stretched instead and measured few edge faces, so
    /// edge-of-frame accuracy is unmeasured either way.
    static func squareFit(_ image: CGImage, side: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let scale = Double(side) / Double(max(image.width, image.height))
        let width = Double(image.width) * scale, height = Double(image.height) * scale
        context.draw(image, in: CGRect(x: (Double(side) - width) / 2, y: (Double(side) - height) / 2, width: width, height: height))
        return context.makeImage()
    }

    private static func jpegData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
