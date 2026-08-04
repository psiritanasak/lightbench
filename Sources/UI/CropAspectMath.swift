import CoreGraphics

/// The aspect-ratio preset list, matching CLAUDE.md's Crop-panel backlog
/// reference. Presentation-only (no `EditState` field) — a locked ratio
/// only changes how `CropOverlayView`'s drag handles behave; the final
/// crop is still just the same four `cropInset*` fractions `applyCrop`
/// already consumes, unaware any lock was ever active.
enum CropAspectPreset: CaseIterable, Equatable {
    case freeform, original, square
    case ratio16x9, ratio4x5, ratio5x7, ratio4x3, ratio3x5, ratio3x2
    case custom

    var label: String {
        switch self {
        case .freeform: return "Freeform"
        case .original: return "Original"
        case .square: return "Square"
        case .ratio16x9: return "16:9"
        case .ratio4x5: return "4:5"
        case .ratio5x7: return "5:7"
        case .ratio4x3: return "4:3"
        case .ratio3x5: return "3:5"
        case .ratio3x2: return "3:2"
        case .custom: return "Custom"
        }
    }

    /// Fixed width:height ratio for presets with a constant ratio; `nil`
    /// for `.freeform` (no constraint), `.original` (depends on the
    /// current displayed frame, resolved by the caller from `fitRect`),
    /// and `.custom` (captured at selection time, resolved by the caller).
    var fixedRatio: Double? {
        switch self {
        case .square: return 1
        case .ratio16x9: return 16.0 / 9.0
        case .ratio4x5: return 4.0 / 5.0
        case .ratio5x7: return 5.0 / 7.0
        case .ratio4x3: return 4.0 / 3.0
        case .ratio3x5: return 3.0 / 5.0
        case .ratio3x2: return 3.0 / 2.0
        case .freeform, .original, .custom: return nil
        }
    }
}

/// Pure, SwiftUI-independent geometry for aspect-ratio-locked cropping —
/// deliberately factored out of `CropOverlayView` so this real arithmetic
/// (division, clamping, several edge cases) gets direct unit test coverage
/// despite living in the UI layer, matching this project's standing
/// preference for testing real math wherever it lives.
///
/// All inputs/outputs are FRACTIONS of `containerSize` (the same
/// `cropInsetTop/Bottom/Left/Right` convention `EditState`/`applyCrop`
/// already use), not absolute points.
enum CropAspectMath {
    /// Minimum fractional width/height a locked-ratio crop rect may shrink
    /// to — prevents the two moving edges of a corner-resize from
    /// crossing/degenerating, mirroring `CropOverlayView.maxInset`'s
    /// existing role for the freeform case (which prevents the OPPOSITE
    /// problem: insets summing past the frame).
    static let minCropSize: Double = 0.05

    /// Reshapes the crop rect to the largest rect of `targetRatio` (width
    /// / height) that fits INSCRIBED and CENTERED within the CURRENT crop
    /// rect described by `top/bottom/left/right` — matches real editors'
    /// "select a preset, the crop snaps to it" behavior. `containerSize` is
    /// the on-screen `fitRect.size` (needed because insets are fractions of
    /// DIFFERENT bases — width fractions of `containerSize.width`, height
    /// fractions of `containerSize.height` — so ratio math must go through
    /// actual points, not raw fractions, to be correct for a non-square
    /// container).
    static func snappedInsets(
        top: Double, bottom: Double, left: Double, right: Double,
        targetRatio: Double, containerSize: CGSize, maxInset: Double
    ) -> (top: Double, bottom: Double, left: Double, right: Double) {
        guard containerSize.width > 0, containerSize.height > 0, targetRatio > 0 else {
            return (top, bottom, left, right)
        }

        let currentWidthPx = containerSize.width * (1 - left - right)
        let currentHeightPx = containerSize.height * (1 - top - bottom)
        let centerX = left + (1 - left - right) / 2
        let centerY = top + (1 - top - bottom) / 2

        let newWidthPx: Double
        let newHeightPx: Double
        if currentHeightPx > 0, currentWidthPx / currentHeightPx > targetRatio {
            newHeightPx = currentHeightPx
            newWidthPx = newHeightPx * targetRatio
        } else {
            newWidthPx = currentWidthPx
            newHeightPx = newWidthPx / targetRatio
        }

        let halfWidthFrac = (newWidthPx / containerSize.width) / 2
        let halfHeightFrac = (newHeightPx / containerSize.height) / 2

        return (
            top: clamp(centerY - halfHeightFrac, 0, maxInset),
            bottom: clamp(1 - (centerY + halfHeightFrac), 0, maxInset),
            left: clamp(centerX - halfWidthFrac, 0, maxInset),
            right: clamp(1 - (centerX + halfWidthFrac), 0, maxInset)
        )
    }

    enum Corner {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    /// Resizes the crop rect from a corner drag while maintaining
    /// `ratio` (width/height), anchored at the OPPOSITE corner (its two
    /// insets stay exactly unchanged from `start`) — the standard
    /// photo-editor convention. `dx` is the drag translation as a fraction
    /// of `containerSize.width` (positive = rightward), matching the sign
    /// convention `CropOverlayView`'s existing freeform per-corner cases
    /// already use (`start.left + dx` / `start.right - dx`), so this is a
    /// direct extension of that convention, not a new one. Only the
    /// horizontal component drives the resize; the perpendicular dimension
    /// is derived from `ratio` — a fixed-ratio rect has only one remaining
    /// degree of freedom, so one drag axis is sufficient.
    ///
    /// Single-pass clamping: if the derived (non-dragged) dimension needs
    /// clamping to `maxInset` at an extreme, the result may deviate
    /// slightly from `ratio` right at that boundary rather than iteratively
    /// re-solving — an accepted tradeoff, same philosophy already applied
    /// to the freeform interior-drag clamp.
    static func cornerResize(
        _ corner: Corner,
        start: (top: Double, bottom: Double, left: Double, right: Double),
        dx: Double, ratio: Double, containerSize: CGSize, maxInset: Double
    ) -> (top: Double, bottom: Double, left: Double, right: Double) {
        guard containerSize.width > 0, containerSize.height > 0, ratio > 0 else {
            return start
        }

        func height(forWidthFraction widthFrac: Double) -> Double {
            let widthPx = widthFrac * containerSize.width
            let heightPx = widthPx / ratio
            return heightPx / containerSize.height
        }

        switch corner {
        case .topLeft:
            let rightEdge = 1 - start.right
            let newLeft = clamp(start.left + dx, 0, min(maxInset, rightEdge - minCropSize))
            let newTop = clamp((1 - start.bottom) - height(forWidthFraction: rightEdge - newLeft), 0, maxInset)
            return (top: newTop, bottom: start.bottom, left: newLeft, right: start.right)

        case .topRight:
            let leftEdge = start.left
            let newRight = clamp(start.right - dx, 0, min(maxInset, 1 - leftEdge - minCropSize))
            let newTop = clamp((1 - start.bottom) - height(forWidthFraction: 1 - newRight - leftEdge), 0, maxInset)
            return (top: newTop, bottom: start.bottom, left: start.left, right: newRight)

        case .bottomLeft:
            let rightEdge = 1 - start.right
            let newLeft = clamp(start.left + dx, 0, min(maxInset, rightEdge - minCropSize))
            let newBottom = clamp(1 - start.top - height(forWidthFraction: rightEdge - newLeft), 0, maxInset)
            return (top: start.top, bottom: newBottom, left: newLeft, right: start.right)

        case .bottomRight:
            let leftEdge = start.left
            let newRight = clamp(start.right - dx, 0, min(maxInset, 1 - leftEdge - minCropSize))
            let newBottom = clamp(1 - start.top - height(forWidthFraction: 1 - newRight - leftEdge), 0, maxInset)
            return (top: start.top, bottom: newBottom, left: start.left, right: newRight)
        }
    }

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value, lower), upper)
    }
}
