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
    /// Added to the stored revision of a scan that ALSO ran the small-face pass (see `FaceScanRecord.isCurrent`). Large against
    /// `detectRevision` (hundreds), so the two can never collide.
    static let smallPassFlag = 10_000
    static func includesSmallPass(revision: Int) -> Bool { revision >= smallPassFlag }
    /// The revision a scan stores for its photos: the base, plus the flag when the small-face pass ran.
    static func scanRevision(includeSmall: Bool) -> Int { detectRevision + (includeSmall ? smallPassFlag : 0) }
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

    // MARK: Small-face pass (opt-in)
    // Measured 2026-11-03 on three 6016x4016 D610 group photos (docs/ROADMAP_HISTORY.md): the full-frame pass at 1600 px found 0 faces
    // (they are ~20 px there), while tiles of 1024 px over the full-size embedded preview found 84-89 boxes per photo, 72-96 px wide,
    // quality median 0.33-0.36, in 0.4-0.9 s. So the SAME width/quality filters apply, in pixels of the larger image.

    /// Long edge of the image the small-face pass tiles (a RAW keeps whatever embedded preview it has, never a RAW decode).
    static let smallPassPixelSize = 6144
    /// The pass is skipped when the source is not clearly larger than the full-frame pass's image: tiling would find nothing new.
    static let smallPassMinimumLongEdge = 2400
    static let smallPassTile = 1024
    /// Neighbouring tiles overlap by this many pixels: more than a whole face, so a face cut by one tile's edge is whole in the next.
    static let smallPassOverlap = 256
    /// A box closer than this to an INTERIOR tile edge is a face cut by that edge (the neighbour tile sees it whole): dropped.
    static let tileEdgeMargin = 4.0
    /// Two boxes overlapping by more than this (intersection over union) are the same face.
    static let duplicateIoU = 0.3
    /// Per photo, best quality first: bounds the rows and the time for a crowd.
    static let maximumSmallFacesPerPhoto = 150

    struct DetectedFace: Equatable, Sendable {
        /// Fractions of the oriented image, origin TOP-left.
        var x: Double, y: Double, w: Double, h: Double
        var quality: Double
        var featurePrint: Data
        var crop: Data?
        /// Found only by the small-face pass: no print (`Data()`), never grouped automatically.
        var isSmall: Bool = false
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

    // MARK: Small-face pass helpers (pure, unit-tested)

    /// Pixel rectangles (origin TOP-left) of `tile` x `tile` tiles that cover the whole image; neighbours overlap by at least `overlap`
    /// (the last tile in a row or column is moved back to end exactly at the edge). An image smaller than a tile is one tile.
    static func tiles(imageWidth: Int, imageHeight: Int, tile: Int = smallPassTile, overlap: Int = smallPassOverlap) -> [CGRect] {
        func starts(_ length: Int) -> [Int] {
            guard length > tile else { return [0] }
            let step = max(1, tile - overlap)
            var out: [Int] = []
            var start = 0
            while true {
                if start + tile >= length { out.append(length - tile); break }
                out.append(start)
                start += step
            }
            return out
        }
        var rects: [CGRect] = []
        for y in starts(imageHeight) {
            for x in starts(imageWidth) {
                rects.append(CGRect(x: x, y: y, width: min(tile, imageWidth), height: min(tile, imageHeight)))
            }
        }
        return rects
    }

    /// A Vision box (normalised to its tile, origin BOTTOM-left) as fractions of the whole image, origin TOP-left.
    static func imageFractions(visionBox: CGRect, tile: CGRect, imageWidth: Int, imageHeight: Int) -> (x: Double, y: Double, w: Double, h: Double) {
        let left = Double(tile.minX) + Double(visionBox.minX) * Double(tile.width)
        let top = Double(tile.minY) + Double(1 - visionBox.maxY) * Double(tile.height)
        return (left / Double(imageWidth), top / Double(imageHeight),
                Double(visionBox.width) * Double(tile.width) / Double(imageWidth), Double(visionBox.height) * Double(tile.height) / Double(imageHeight))
    }

    /// Whether a box touches a tile edge that is NOT the image's own border: such a face may be cut off, and the overlapping neighbour tile
    /// sees it whole.
    static func isCutByInteriorEdge(visionBox: CGRect, tile: CGRect, imageWidth: Int, imageHeight: Int, margin: Double = tileEdgeMargin) -> Bool {
        let left = Double(visionBox.minX) * Double(tile.width), right = Double(visionBox.maxX) * Double(tile.width)
        let top = Double(1 - visionBox.maxY) * Double(tile.height), bottom = Double(1 - visionBox.minY) * Double(tile.height)
        let interiorLeft = tile.minX > 0, interiorRight = Int(tile.maxX) < imageWidth
        let interiorTop = tile.minY > 0, interiorBottom = Int(tile.maxY) < imageHeight
        return (interiorLeft && left < margin) || (interiorRight && right > Double(tile.width) - margin)
            || (interiorTop && top < margin) || (interiorBottom && bottom > Double(tile.height) - margin)
    }

    struct SmallCandidate: Equatable {
        var box: FaceMatching.Box
        var quality: Double
    }

    /// Best quality first; a candidate is dropped when it overlaps (`duplicateIoU`) a face already kept, or one of `existing` (the faces the
    /// full-frame pass found: the same face seen again at higher resolution), or when either box's centre lies inside the other.
    static func suppressDuplicates(_ candidates: [SmallCandidate], existing: [FaceMatching.Box]) -> [SmallCandidate] {
        func same(_ a: FaceMatching.Box, _ b: FaceMatching.Box) -> Bool {
            if FaceMatching.iou(a, b) > duplicateIoU { return true }
            func centreInside(_ p: FaceMatching.Box, _ q: FaceMatching.Box) -> Bool {
                let cx = p.x + p.w / 2, cy = p.y + p.h / 2
                return cx >= q.x && cx <= q.x + q.w && cy >= q.y && cy <= q.y + q.h
            }
            return centreInside(a, b) || centreInside(b, a)
        }
        var kept: [SmallCandidate] = []
        for candidate in candidates.sorted(by: { $0.quality > $1.quality }) {
            if existing.contains(where: { same(candidate.box, $0) }) { continue }
            if kept.contains(where: { same(candidate.box, $0.box) }) { continue }
            kept.append(candidate)
        }
        return kept
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
    /// With `includeSmall` the photo is ALSO searched in tiles at higher resolution (`smallFaces(in:excluding:)`); a failure there makes
    /// the whole photo `nil` (retried), never "no small faces". The normal pass is identical either way.
    static func detect(inFileAt url: URL, includeSmall: Bool = false) -> [DetectedFace]? {
        autoreleasepool {
            guard let base = FeaturePrintGenerator.thumbnail(ofFileAt: url, pixelSize: thumbnailPixelSize), var faces = detect(in: base) else { return nil }
            guard includeSmall else { return faces }
            // A failed decode is "could not look" (nil: the photo is retried), never "no small faces" (which would be recorded for good).
            guard let large = FeaturePrintGenerator.thumbnail(ofFileAt: url, pixelSize: smallPassPixelSize) else { return nil }
            guard max(large.width, large.height) >= smallPassMinimumLongEdge else { return faces }
            guard let small = smallFaces(in: large, excluding: faces) else { return nil }
            faces += small
            return faces
        }
    }

    /// Vision's face boxes (origin BOTTOM-left) with their capture quality, `[]` for "looked, none", `nil` for "could not look" or a
    /// missing score (see `scored`).
    private static func scoredBoxes(in image: CGImage) -> [(box: CGRect, quality: Double)]? {
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
        guard (try? handler.perform([quality])) != nil, let results = quality.results, results.count == observations.count else { return nil }
        return scored(results.map { ScoredBox(box: $0.boundingBox, quality: $0.faceCaptureQuality) })
    }

    /// `[]` means "looked, found no usable face"; `nil` means "could not look" (a failed request, a missing score, a crop that could
    /// not be printed): never recorded as faceless.
    static func detect(in image: CGImage) -> [DetectedFace]? {
        guard let scored = scoredBoxes(in: image) else { return nil }
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

    /// The faces only a higher-resolution look finds: `image` is searched in overlapping tiles, boxes cut by an interior tile edge are
    /// dropped, the rest must pass the SAME width/quality filters (in pixels of `image`), duplicates and the faces the full-frame pass
    /// already found (`existing`) are removed, and at most `maximumSmallFacesPerPhoto` of the best remain. They carry NO feature print:
    /// they are never compared (see `Face.isSmall`). `nil` when any tile could not be searched.
    static func smallFaces(in image: CGImage, excluding existing: [DetectedFace]) -> [DetectedFace]? {
        var candidates: [SmallCandidate] = []
        for tile in tiles(imageWidth: image.width, imageHeight: image.height) {
            var failed = false
            autoreleasepool {
                guard let tileImage = image.cropping(to: tile), let boxes = scoredBoxes(in: tileImage) else { failed = true; return }
                for entry in boxes {
                    if isCutByInteriorEdge(visionBox: entry.box, tile: tile, imageWidth: image.width, imageHeight: image.height) { continue }
                    let f = imageFractions(visionBox: entry.box, tile: tile, imageWidth: image.width, imageHeight: image.height)
                    guard passesFilters(widthPixels: f.w * Double(image.width), quality: entry.quality) else { continue }
                    candidates.append(SmallCandidate(box: FaceMatching.Box(x: f.x, y: f.y, w: f.w, h: f.h), quality: entry.quality))
                }
            }
            if failed { return nil }
        }
        let kept = suppressDuplicates(candidates, existing: existing.map { FaceMatching.Box(x: $0.x, y: $0.y, w: $0.w, h: $0.h) })
        // A face whose tile cannot be encoded is dropped (the user could not recognise a blank tile).
        return kept.compactMap { candidate -> DetectedFace? in
            let box = (x: candidate.box.x, y: candidate.box.y, w: candidate.box.w, h: candidate.box.h)
            let rect = cropRect(box: box, imageWidth: image.width, imageHeight: image.height)
            guard let crop = image.cropping(to: rect).flatMap({ squareFit($0, side: tileSide) }).flatMap(jpegData(from:)) else { return nil }
            return DetectedFace(x: box.x, y: box.y, w: box.w, h: box.h, quality: candidate.quality, featurePrint: Data(), crop: crop, isSmall: true)
        }.prefix(maximumSmallFacesPerPhoto).map { $0 }
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
