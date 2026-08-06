import CoreGraphics

/// Pure add/remove decision logic for `RedEyeOverlayView`'s tap gesture,
/// pulled out of the view for direct XCTest coverage — the same pattern
/// `CropAspectMath` already established for UI-layer geometry math that's
/// still worth testing without a SwiftUI harness.
enum RedEyeHitTest {
    /// Returns the index of the nearest existing point (in `screenPoints`,
    /// same SwiftUI-local coordinate space as `tap`) if it's within
    /// `threshold` of the tap, or `nil` if the tap should ADD a new point
    /// instead of removing an existing one. Ties (equidistant points) are
    /// broken by returning the FIRST match in array order — deterministic,
    /// though not expected to matter in practice since two points can't
    /// realistically overlap exactly.
    static func nearestPointIndex(to tap: CGPoint, in screenPoints: [CGPoint], threshold: CGFloat) -> Int? {
        var bestIndex: Int?
        var bestDistance = threshold
        for (index, point) in screenPoints.enumerated() {
            let distance = hypot(point.x - tap.x, point.y - tap.y)
            if distance <= bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        return bestIndex
    }
}
