import CoreGraphics

/// D8 (IMPROVEMENTS.md): pure step math for the Editor's keyboard-driven
/// crosshair — shared by WB eyedropper pick and Red-Eye point placement,
/// since both are the same "aim a normalized point on the image, then
/// commit" shape. Matches `ZoomPanGeometry`/`CropAspectMath`/
/// `CompareLayout`/`ThinSliderGeometry`/`LibraryGridColumns`'s established
/// pattern — a `CoreGraphics`-only enum of static functions, unit-tested
/// directly rather than buried in a `KeyPress` handler closure.
enum CrosshairGeometry {
    /// One arrow-key step, as a fraction of the fit rect — 2%, chosen so
    /// a full crossing of the image takes ~50 presses (fine enough to be
    /// useful, coarse enough not to feel glacial); holding the key repeats
    /// via `.onKeyPress`'s own default `.repeat` phase, not anything here.
    static let step: Double = 0.02

    /// `position` nudged by `(dx, dy)`, clamped to `0...1` on both axes —
    /// the crosshair can never move off the image it's aiming at.
    static func moved(_ position: CGPoint, dx: Double, dy: Double) -> CGPoint {
        CGPoint(
            x: min(max(position.x + dx, 0), 1),
            y: min(max(position.y + dy, 0), 1)
        )
    }
}
