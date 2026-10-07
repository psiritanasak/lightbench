import CoreGraphics

/// Pure screen-space math for the Style Tone/Color pad (`StylePadView`) — CoreGraphics only, no SwiftUI, so the
/// arithmetic is unit-tested instead of eyeballed through a gesture (the `ColorWheelGeometry` convention).
///
/// AXES: horizontal = Color (-1 at the left edge, +1 at the right), vertical = Tone (+1 at the TOP edge, -1 at the
/// bottom — screen Y is down, so Tone's sign is flipped here). Both axes are clamped independently (a square pad, not a
/// polar one).
enum StylePadGeometry {
    /// Inset between the pad's edge and the puck's extreme position, so a puck at ±1 is not half-clipped.
    static let puckInset: CGFloat = 8

    /// A drag within this fraction of an axis' half-extent of the centre line snaps that axis to EXACTLY 0. Load-bearing:
    /// `StyleMath.isIdentity` and the Adjust tab's "is at identity" checks compare to a literal 0, so a real cursor aiming
    /// at the centre must reach it. Per axis (not radial) so a drag along the centre line stays on it.
    static let centerSnapFraction: Double = 0.04

    /// The usable half-extents (x, y) of the plot area, each 0 (never negative) for a tiny rect.
    static func halfExtents(_ rect: CGRect) -> (x: CGFloat, y: CGFloat) {
        (max(0, rect.width / 2 - puckInset), max(0, rect.height / 2 - puckInset))
    }

    /// Tone/Color -> the puck's screen point. Out-of-range or non-finite inputs resolve to an on-pad position.
    static func screenPoint(tone: Double, color: Double, in rect: CGRect) -> CGPoint {
        let half = halfExtents(rect)
        func unit(_ v: Double) -> CGFloat { v.isFinite ? CGFloat(min(max(v, -1), 1)) : 0 }
        return CGPoint(x: rect.midX + half.x * unit(color), y: rect.midY - half.y * unit(tone))
    }

    /// Inverse of `screenPoint` (up to the clamp and the centre snap). `(0, 0)` for a degenerate rect or a non-finite point.
    static func values(at location: CGPoint, in rect: CGRect) -> (tone: Double, color: Double) {
        let half = halfExtents(rect)
        guard half.x > 0, half.y > 0, location.x.isFinite, location.y.isFinite else { return (0, 0) }
        func snapped(_ v: Double) -> Double {
            let c = min(max(v, -1), 1)
            return abs(c) <= centerSnapFraction ? 0 : c
        }
        let color = snapped(Double((location.x - rect.midX) / half.x))
        let tone = snapped(Double(-(location.y - rect.midY) / half.y))
        return (tone, color)
    }

    /// One keyboard/VoiceOver step on an axis, clamped to -1...1 and snapped to an exact 0 when it lands within a step's
    /// rounding of the centre (so repeated +0.1/-0.1 returns to identity, not 1e-17).
    static func stepped(_ value: Double, by delta: Double) -> Double {
        let base = value.isFinite ? value : 0
        let next = min(max(base + delta, -1), 1)
        return abs(next) < 1e-9 ? 0 : (next * 1e9).rounded() / 1e9
    }
}
