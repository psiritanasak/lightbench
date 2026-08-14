import CoreGraphics

/// The Compare feature's UI-facing mode — what the toolbar `Menu` binds to.
/// `.off` means no compare at all (the single-image view, unchanged).
enum CompareViewMode: Equatable {
    case off, sideBySide, split
}

/// Which way the Split mode's divider runs. `.vertical` = a vertical LINE
/// (left/right split, drag horizontally); `.horizontal` = a horizontal
/// LINE (top/bottom split, drag vertically) — named after the divider's
/// own orientation, matching how the user described the two options.
enum SplitOrientation: Equatable {
    case vertical, horizontal
}

/// The renderer-facing compare mode — deliberately narrower than
/// `CompareViewMode` (no `.off` case): `ImageRenderer`/`MetalImageView`
/// only ever see a `CompareRenderConfig?`, where `nil` already means
/// "compare off," so this type only needs to describe the two ACTIVE
/// render shapes.
enum CompareRenderMode: Equatable {
    case sideBySide
    case split(orientation: SplitOrientation, position: Double)
}

/// Everything `ImageRenderer.draw(in:)` needs to render a compare frame,
/// bundled so `MetalImageView`'s redraw guard can compare it in one
/// `Equatable` check (see `MetalImageView.updateNSView`).
struct CompareRenderConfig: Equatable {
    var originalState: EditState
    var mode: CompareRenderMode
}

/// Pure, SwiftUI-independent geometry for the Compare feature — mirrors
/// `CropAspectMath`'s/`ThinSliderGeometry`'s established pattern (a plain
/// `CoreGraphics`-only enum of static functions, unit-tested directly)
/// rather than burying this arithmetic inside `ImageRenderer` or a
/// SwiftUI view where it can't get direct coverage.
enum CompareLayout {
    /// Two CONGRUENT aspect-fit rects for Side by Side: `imageSize` fit
    /// into the LEFT and RIGHT halves of `drawableSize`. Since both
    /// compared images share one extent (Compare's "original" keeps the
    /// current crop/straighten geometry — see `EditState.comparisonOriginal()`),
    /// one `AspectFit.rect` call against a half-width container gives a
    /// rect valid for BOTH halves; `right` is just `left` offset by
    /// exactly half the drawable's width.
    static func sideBySideFitRects(imageSize: CGSize, drawableSize: CGSize) -> (left: CGRect, right: CGRect) {
        let halfWidth = drawableSize.width / 2
        let halfContainer = CGSize(width: halfWidth, height: drawableSize.height)
        let left = AspectFit.rect(fitting: imageSize, in: halfContainer)
        guard left != .zero else { return (.zero, .zero) }
        let right = left.offsetBy(dx: halfWidth, dy: 0)
        return (left, right)
    }

    /// Splits `rect` into two sub-rects along a divider at `position`
    /// (0...1, clamped), tiling `rect` EXACTLY with no gap or overlap.
    /// `first` is the sub-rect nearer `rect`'s `minX` (vertical) or
    /// `minY` (horizontal) — purely a rectangle subdivision, agnostic to
    /// which visual side ends up "left"/"top": callers own that mapping
    /// (and must verify it live — see `ImageRenderer`'s documented
    /// y-convention caveat for the horizontal case).
    static func splitRects(_ rect: CGRect, orientation: SplitOrientation, position: Double) -> (first: CGRect, second: CGRect) {
        let p = min(max(position, 0), 1)
        switch orientation {
        case .vertical:
            let firstWidth = rect.width * p
            let first = CGRect(x: rect.minX, y: rect.minY, width: firstWidth, height: rect.height)
            let second = CGRect(x: rect.minX + firstWidth, y: rect.minY, width: rect.width - firstWidth, height: rect.height)
            return (first, second)
        case .horizontal:
            let firstHeight = rect.height * p
            let first = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstHeight)
            let second = CGRect(x: rect.minX, y: rect.minY + firstHeight, width: rect.width, height: rect.height - firstHeight)
            return (first, second)
        }
    }

    /// An absolute drag/tap `location` (in `fitRect`'s own coordinate
    /// space) converted to a clamped 0...1 divider fraction — the inverse
    /// direction of `splitRects`' `position`. Degenerate zero-size
    /// `fitRect` returns 0.5 (centered) rather than dividing by zero.
    static func dividerFraction(at location: CGPoint, in fitRect: CGRect, orientation: SplitOrientation) -> Double {
        guard fitRect.width > 0, fitRect.height > 0 else { return 0.5 }
        let raw: Double
        switch orientation {
        case .vertical:
            raw = (location.x - fitRect.minX) / fitRect.width
        case .horizontal:
            raw = (location.y - fitRect.minY) / fitRect.height
        }
        return min(max(raw, 0), 1)
    }
}
