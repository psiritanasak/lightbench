import CoreImage
import Foundation

/// Which detected subject a click on the displayed photo lands on (click-on-image subject picking).
///
/// The click is in the DISPLAYED frame (after straighten/perspective/flip/crop); the stored instance rasters live in
/// the source frame. Instead of inverting `EditPipeline.applyGeometry` by hand, every instance is pushed through the
/// FORWARD pipeline path (`EditPipeline.subjectInstanceMaskImages`) and its coverage is sampled at the click point.
enum SubjectInstancePicker {
    /// An instance counts as hit when its coverage at the point is at least this (the mask edge is soft after the
    /// resample; 0.5 is "more inside than out").
    static let hitThreshold: Double = 0.5

    /// The index (into `Mask.subjectInstancePNGs`) of the instance under `normalizedX/Y`, or nil. `normalizedX/Y` are
    /// fractions of the displayed photo, top-left origin / y down (SwiftUI space). Highest coverage wins; ties go to
    /// the lowest index (Vision's instance masks are disjoint, so a real tie is vanishingly rare).
    static func hit(
        state: EditState, maskID: UUID, source: CIImage, normalizedX: Double, normalizedY: Double
    ) -> Int? {
        guard normalizedX.isFinite, normalizedY.isFinite, (0...1).contains(normalizedX), (0...1).contains(normalizedY) else { return nil }
        let images = EditPipeline.subjectInstanceMaskImages(state, maskID: maskID, source: source)
        var coverages: [Double] = []
        for image in images {
            guard let image else { coverages.append(0); continue }
            let extent = image.extent
            guard extent.width > 0, extent.height > 0 else { coverages.append(0); continue }
            // y-flip: SwiftUI space is top-left/y-down, `CIImage` space is bottom-left/y-up (the same `1 - v`
            // convention the colour pickers use).
            let point = CGPoint(
                x: extent.minX + CGFloat(normalizedX) * extent.width,
                y: extent.minY + CGFloat(1 - normalizedY) * extent.height
            )
            coverages.append(PixelSampler.coverage(of: image, at: point))
        }
        return best(of: coverages)
    }

    /// Pure selection: the highest coverage at/above the threshold, lowest index on a tie.
    static func best(of coverages: [Double]) -> Int? {
        var best: (index: Int, value: Double)?
        for (index, value) in coverages.enumerated() where value >= hitThreshold && value > (best?.value ?? -1) {
            best = (index, value)
        }
        return best?.index
    }
}
