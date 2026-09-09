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

    /// D8 (IMPROVEMENTS.md): the full add-or-remove decision, pulled out
    /// so `RedEyeOverlayView`'s mouse tap gesture and `ContentView`'s
    /// keyboard Return-to-commit share ONE implementation instead of two
    /// independently-maintained copies of the same normalize → hit-test →
    /// remove-else-append sequence (reviewer-caught during D8: the two
    /// had drifted to sharing only the threshold constant, not the logic
    /// itself). `normalizedTap`/`points` are in the SAME normalized
    /// 0...1/y-DOWN space `RedEyePoint` itself uses; `fitRect` is only
    /// used to convert into screen space for the actual distance check.
    static func toggling(
        _ normalizedTap: CGPoint, in points: [RedEyePoint], fitRect: CGRect, threshold: CGFloat
    ) -> [RedEyePoint] {
        let tapScreenPoint = CGPoint(x: normalizedTap.x * fitRect.width, y: normalizedTap.y * fitRect.height)
        let screenPoints = points.map { CGPoint(x: $0.x * fitRect.width, y: $0.y * fitRect.height) }
        var result = points
        if let index = nearestPointIndex(to: tapScreenPoint, in: screenPoints, threshold: threshold) {
            result.remove(at: index)
        } else {
            result.append(RedEyePoint(x: normalizedTap.x, y: normalizedTap.y))
        }
        return result
    }
}
