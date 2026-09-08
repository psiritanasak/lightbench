import Foundation

/// D4 (IMPROVEMENTS.md): how many `cellSize`-minimum columns fit across a
/// measured width, at a given spacing — the same fit `GridItem(.adaptive(
/// minimum:))` computes internally for `LibraryGridView`'s grid, made
/// explicit and pure so Up/Down arrow-key navigation has an AUTHORITATIVE
/// column count to jump by. SwiftUI never exposes the column count an
/// adaptive grid actually rendered with, so `LibraryGridView` switched from
/// `.adaptive` to explicit `.fixed` columns using this exact count — the
/// grid's layout and the keyboard math now share one source of truth
/// instead of one approximating the other.
///
/// Pure, SwiftUI-independent, and its own file purely for direct unit test
/// coverage — the same pattern `CropAspectMath`/`CompareLayout`/
/// `ZoomPanGeometry`/`ThinSliderGeometry` already established for
/// `Sources/UI/`-hosted geometry.
enum LibraryGridColumns {
    /// `N` columns of at least `cellSize`, `spacing` apart, fit in `width`
    /// when `N * cellSize + (N - 1) * spacing <= width`, i.e.
    /// `N <= (width + spacing) / (cellSize + spacing)` — the largest such
    /// `N`, floored, and never less than `1` (a grid with zero columns
    /// can't render anything). Degenerate inputs (a not-yet-laid-out
    /// `GeometryReader` briefly reporting `0`/negative width, a
    /// non-positive `cellSize`, a non-finite width) all fall back to `1`
    /// rather than dividing by zero or returning something nonsensical.
    /// Reviewer-caught: `cellSize` itself must be positive, not just
    /// `cellSize + spacing` — a `0` `cellSize` with real `spacing` used to
    /// pass the old guard and return a large, meaningless column count.
    static func count(forWidth width: Double, cellSize: Double, spacing: Double) -> Int {
        guard cellSize > 0, spacing.isFinite, width.isFinite else { return 1 }
        let denominator = cellSize + spacing
        guard denominator > 0 else { return 1 }
        let fit = (width + spacing) / denominator
        guard fit.isFinite, fit >= 1 else { return 1 }
        // Clamped before the `Int` conversion — an absurdly large but still
        // finite `width` (unreachable via `GeometryReader` in practice, but
        // not guarded against otherwise) would trap `Int(...)` on overflow.
        return Int(min(fit, 1_000_000).rounded(.down))
    }
}
