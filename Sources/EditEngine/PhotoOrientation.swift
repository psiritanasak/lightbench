import CoreImage
import Foundation

/// A photo's turn-and-flip edit (`EditState.rotationQuarterTurns` / `flipHorizontal` / `flipVertical`) and nothing else: what Photo Merge reads
/// from each source's edit file so the merged picture shows the photo the way the Library shows it. Pure; no UI.
struct PhotoOrientation: Equatable {
    var quarterTurns: Int
    var flipHorizontal: Bool
    var flipVertical: Bool

    static let identity = PhotoOrientation(quarterTurns: 0, flipHorizontal: false, flipVertical: false)

    init(quarterTurns: Int = 0, flipHorizontal: Bool = false, flipVertical: Bool = false) {
        self.quarterTurns = QuarterTurn.normalized(quarterTurns)
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
    }

    /// Reads ONLY the three orientation fields; every other edit is ignored.
    init(from state: EditState) {
        self.init(quarterTurns: state.rotationQuarterTurns, flipHorizontal: state.flipHorizontal, flipVertical: state.flipVertical)
    }

    var isIdentity: Bool { self == .identity }

    /// `image` turned and flipped exactly (a pixel permutation, no resampling), extent origin at (0, 0). Same order as
    /// `EditPipeline.applyGeometry`: the turn first, the flips later.
    func apply(to image: CIImage) -> CIImage {
        var result = image
        let start = result.extent
        if !start.isInfinite, start.minX != 0 || start.minY != 0 {
            result = result.transformed(by: CGAffineTransform(translationX: -start.minX, y: -start.minY))
        }
        result = QuarterTurn.apply(quarterTurns, to: result)
        // Mirror about the (origin-anchored) extent: exact, like `EditPipeline.applyFlip`.
        let extent = result.extent
        if flipHorizontal {
            result = result.transformed(by: CGAffineTransform(scaleX: -1, y: 1).concatenating(CGAffineTransform(translationX: extent.width, y: 0)))
        }
        if flipVertical {
            result = result.transformed(by: CGAffineTransform(scaleX: 1, y: -1).concatenating(CGAffineTransform(translationX: 0, y: extent.height)))
        }
        return result
    }
}
