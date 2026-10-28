import Foundation
import CoreGraphics

/// A validity raster of the picture AFTER its geometry (rotation, straighten, perspective, scale/stretch, flip) and
/// BEFORE any crop: `valid[y * width + x]` is true where the pixel is opaque (row 0 = the picture's top). Measured from the
/// real pipeline's alpha by `AutoCropMaskRenderer`; this type carries no Core Image.
struct AutoCropMask: Equatable, Sendable {
    let width: Int
    let height: Int
    let valid: [Bool]
}

/// Largest axis-aligned crop that contains no transparent (revealed) pixel. Pure: no UI, no Core Image.
///
/// A cell counts only when it AND its four neighbours are valid (a neighbour outside the frame counts as valid: the frame edge is
/// not an empty area), so an anti-aliased edge cell can never end up on a crop edge; the rectangle found by `LargestRectangle`
/// is then shrunk by one more cell on every side that does not already lie on the frame edge.
enum AutoCropSolver {
    struct Insets: Equatable {
        var top: Double, bottom: Double, left: Double, right: Double
        var maxInset: Double { max(max(top, bottom), max(left, right)) }
    }

    enum Outcome: Equatable {
        case cropped(Insets)
        case nothingToCrop
        case tooLarge
        case empty
    }

    /// Mirrors `EditPipeline.kMaxCropInset` (private there), like `CropOverlayView.maxInset`.
    static let maxInset: Double = 0.45

    /// `aspectRatio` (width / height in PIXELS of the mask's frame) fits that ratio centred inside the found rectangle.
    static func solve(_ mask: AutoCropMask, aspectRatio: Double? = nil) -> Outcome {
        let w = mask.width, h = mask.height
        guard w > 0, h > 0, mask.valid.count == w * h else { return .empty }
        if !mask.valid.contains(false) { return .nothingToCrop }
        guard mask.valid.contains(true) else { return .empty }

        var eroded = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            for x in 0..<w where mask.valid[y * w + x] {
                let leftOK = x == 0 || mask.valid[y * w + x - 1]
                let rightOK = x == w - 1 || mask.valid[y * w + x + 1]
                let upOK = y == 0 || mask.valid[(y - 1) * w + x]
                let downOK = y == h - 1 || mask.valid[(y + 1) * w + x]
                eroded[y * w + x] = leftOK && rightOK && upOK && downOK
            }
        }
        guard let found = LargestRectangle.find(mask: eroded, width: w, height: h) else { return .empty }
        var x0 = found.x, y0 = found.y, x1 = found.x + found.width, y1 = found.y + found.height
        if x0 > 0 { x0 += 1 }
        if y0 > 0 { y0 += 1 }
        if x1 < w { x1 -= 1 }
        if y1 < h { y1 -= 1 }
        guard x1 > x0, y1 > y0 else { return .empty }

        var insets = Insets(
            top: Double(y0) / Double(h), bottom: Double(h - y1) / Double(h),
            left: Double(x0) / Double(w), right: Double(w - x1) / Double(w))
        if insets.maxInset == 0 { return .nothingToCrop }
        if insets.maxInset > maxInset { return .tooLarge }
        if let ratio = aspectRatio, ratio.isFinite, ratio > 0 {
            let snapped = CropAspectMath.snappedInsets(
                top: insets.top, bottom: insets.bottom, left: insets.left, right: insets.right,
                targetRatio: ratio, containerSize: CGSize(width: w, height: h), maxInset: 1)
            insets = Insets(top: snapped.top, bottom: snapped.bottom, left: snapped.left, right: snapped.right)
            if insets.maxInset > maxInset { return .tooLarge }
        }
        return .cropped(insets)
    }
}

/// User-facing wording for Auto Crop outcomes that change nothing.
enum AutoCropMessages {
    static let nothingToCrop = "Nothing to crop: the picture has no empty corners."
    static let tooLarge = "The empty corners are too large to crop away. Reduce Straighten or Scale first."
    static let unmeasurable = "The empty corners could not be measured for this photo."
    static let changedMeanwhile = "The picture's geometry changed while it was being measured, so nothing was changed. Try again."
    static let alreadyApplied = "The crop already fits the picture's filled area."
}
