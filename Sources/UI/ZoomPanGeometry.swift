import CoreGraphics

/// Pure, SwiftUI-independent geometry for the Editor's zoom/pan feature —
/// mirrors `CompareLayout`'s/`CropAspectMath`'s/`ThinSliderGeometry`'s
/// established pattern (a plain `CoreGraphics`-only enum of static
/// functions, unit-tested directly) rather than burying this arithmetic
/// inside `ImageRenderer` or a gesture closure. Every quantity here is
/// normalized to the on-screen fit rect and expressed in SwiftUI's
/// top-left-origin/y-DOWN convention — the renderer (`ImageRenderer.
/// fitted(_:into:zoomScale:panOffsetNorm:)`) is the ONE place that
/// converts to its own y-UP drawable convention, so none of this file
/// needs to reason about that distinction.
enum ZoomPanGeometry {
    static let minZoom: CGFloat = 1
    static let maxZoom: CGFloat = 8

    /// A multiplicative zoom step from a raw scroll delta, clamped to
    /// `[minZoom, maxZoom]`. Multiplicative (not additive) so each scroll
    /// "notch" feels like a consistent proportional zoom regardless of
    /// the current zoom level — matches how every other zoom UI (Preview,
    /// Photos, browsers) feels. `sensitivity` and the delta's sign are
    /// feel parameters, tuned live against real trackpad/mouse-wheel
    /// deltas, not derived — only the shape (monotonic, clamped) is
    /// something to get right here.
    static func steppedZoom(
        current: CGFloat, scrollDelta: CGFloat, sensitivity: CGFloat = 0.01,
        minZoom: CGFloat = minZoom, maxZoom: CGFloat = maxZoom
    ) -> CGFloat {
        let factor = exp(scrollDelta * sensitivity)
        return min(max(current * factor, minZoom), maxZoom)
    }

    /// The new normalized pan that keeps the point under `cursorFraction`
    /// fixed on screen as zoom changes from `oldZoom` to `newZoom`.
    /// Derived (not eyeballed) from requiring the content-space point the
    /// cursor sits over to map back to the same on-screen fraction after
    /// the zoom change; `r = newZoom / oldZoom`:
    /// `p' = (f - 0.5) * (1 - r) + r * p`
    /// — verified by hand at `f = 0.5` (any zoom leaves pan unchanged,
    /// i.e. zooming about dead-center never needs to pan) and at `f = 0`/
    /// `f = 1` (the corresponding edge of the content stays pinned to
    /// that edge of the fit rect through the zoom change).
    static func panForZoomAboutCursor(
        oldZoom: CGFloat, newZoom: CGFloat, cursorFraction: CGPoint, oldPan: CGSize
    ) -> CGSize {
        let r = newZoom / oldZoom
        return CGSize(
            width: (cursorFraction.x - 0.5) * (1 - r) + r * oldPan.width,
            height: (cursorFraction.y - 0.5) * (1 - r) + r * oldPan.height
        )
    }

    /// Clamps `pan` so the zoomed content always fully covers the fit
    /// rect — never reveals background past the image's own edge.
    /// Derived from requiring the content interval `[0.5 - z/2 + p,
    /// 0.5 + z/2 + p]` to contain `[0, 1]`: `p ∈ [-(z-1)/2, (z-1)/2]`.
    /// At `zoom == 1` this collapses to exactly `0` (no pan possible at
    /// fit, matching that there's nothing to pan to yet).
    static func clampedPan(_ pan: CGSize, zoom: CGFloat) -> CGSize {
        let maxOffset = max(0, (zoom - 1) / 2)
        return CGSize(
            width: min(max(pan.width, -maxOffset), maxOffset),
            height: min(max(pan.height, -maxOffset), maxOffset)
        )
    }

    /// A cursor point (in the SAME point space `fitRect`/`containerSize`
    /// are already in) converted to a fraction of `fitRect`, y-DOWN.
    /// Degenerate zero-size `fitRect` returns the center `(0.5, 0.5)`
    /// rather than dividing by zero — matches `CompareLayout.
    /// dividerFraction`'s NaN-avoidance for the same class of input.
    static func cursorFractionInFitRect(cursor: CGPoint, fitRect: CGRect) -> CGPoint {
        guard fitRect.width > 0, fitRect.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(
            x: (cursor.x - fitRect.minX) / fitRect.width,
            y: (cursor.y - fitRect.minY) / fitRect.height
        )
    }

    // MARK: - Where the zoomed picture actually is

    /// The origin (bottom-left) of the zoomed picture in the RENDERER's y-UP space, for a picture that fills `fitRect` at zoom 1:
    /// centred on `fitRect`'s own centre (so zooming about the middle needs no pan), then shifted by `panNorm` — fit-rect-normalised
    /// fractions in SwiftUI's y-DOWN convention, so the y component is negated here and nowhere else. `ImageRenderer.fitted` calls
    /// this very function, so the renderer and `displayedRect` can never disagree.
    static func zoomedOriginYUp(fitRect: CGRect, zoom: CGFloat, panNorm: CGSize) -> CGPoint {
        CGPoint(
            x: fitRect.midX - fitRect.width * zoom / 2 + panNorm.width * fitRect.width,
            y: fitRect.midY - fitRect.height * zoom / 2 - panNorm.height * fitRect.height
        )
    }

    /// The rectangle the zoomed, panned picture occupies in the on-screen pane's y-DOWN point space — what the on-image overlays must
    /// be positioned against once the view is zoomed (at `zoom == 1`, `pan == .zero` it is `fitRect`). Derived from
    /// `zoomedOriginYUp` by mirroring about `fitRect.midY`. Returns `fitRect` for non-finite input rather than propagating NaN.
    static func displayedRect(fitRect: CGRect, zoom: CGFloat, pan: CGSize) -> CGRect {
        guard zoom.isFinite, zoom > 0, pan.width.isFinite, pan.height.isFinite,
              fitRect.width.isFinite, fitRect.height.isFinite, fitRect.minX.isFinite, fitRect.minY.isFinite else { return fitRect }
        let height = fitRect.height * zoom
        let origin = zoomedOriginYUp(fitRect: fitRect, zoom: zoom, panNorm: pan)
        // y-up bottom edge -> y-down top edge: mirror about the fit rect's centre.
        let topYDown = 2 * fitRect.midY - (origin.y + height)
        return CGRect(x: origin.x, y: topYDown, width: fitRect.width * zoom, height: height)
    }

    /// The part of the picture that is actually visible: the displayed rectangle clipped to the pane. `CGRect.null` (infinite origin —
    /// check `isNull`/`isEmpty` before using the origin) when they do not overlap; a zero-size, non-null rect when they only touch. In single-image mode a zoomed picture fills the letterbox as well, so this is NOT `fitRect`.
    static func visiblePictureRect(displayedRect: CGRect, paneBounds: CGRect) -> CGRect {
        displayedRect.intersection(paneBounds)
    }

    /// The pan that puts the image point (`spotX` right, `spotYUp` UP, both 0...1 fractions of the picture) at the centre of the fit
    /// rect, for the given zoom — clamped so the picture still covers the fit rect. Used to bring an off-screen spot into view.
    /// Derived from `displayedRect`: the point sits at `minX + x*W`, and `minX = midX - W/2 + pan.w*fit.w` gives `pan.w = z*(0.5 - x)`;
    /// in y-DOWN terms `yDown = 1 - spotYUp`, so `pan.h = z*(0.5 - yDown)`.
    static func panToCenter(spotX: Double, spotYUp: Double, zoom: CGFloat) -> CGSize {
        guard spotX.isFinite, spotYUp.isFinite, zoom.isFinite, zoom >= 1 else { return .zero }
        let yDown = 1 - spotYUp
        return clampedPan(CGSize(width: zoom * (0.5 - CGFloat(spotX)), height: zoom * (0.5 - CGFloat(yDown))), zoom: zoom)
    }
}

