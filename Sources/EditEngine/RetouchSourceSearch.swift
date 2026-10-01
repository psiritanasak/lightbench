import Foundation

/// Picks a good SOURCE for a spot automatically: the candidate circle whose surroundings look most like the
/// destination's surroundings. Pure, deterministic CPU work over a small PERCEPTUAL (sRGB-gamma) RGB bitmap
/// (≈512 px long side), so it is unit-testable without Core Image and costs a fraction of a millisecond.
///
/// MEASURED (spot-removal spike, `docs/ROADMAP_HISTORY.md`): this works on smooth content (sky, water — the usual
/// dust/blemish case) and is UNRELIABLE on strongly textured content; adding a texture-energy term did not help
/// (it made one case worse). It is a convenience; the user can always drag the source.
enum RetouchSourceSearch {
    /// Row 0 = TOP, like a decoded bitmap. `rgb` holds `width * height * 3` floats.
    struct Bitmap {
        let width: Int
        let height: Int
        let rgb: [Float]

        init?(width: Int, height: Int, rgb: [Float]) {
            guard width > 0, height > 0, rgb.count == width * height * 3 else { return nil }
            self.width = width
            self.height = height
            self.rgb = rgb
        }

        func value(_ x: Int, _ y: Int, _ channel: Int) -> Float { rgb[(y * width + x) * 3 + channel] }
    }

    /// A region the source must stay clear of (other spots, and their sources are not tracked — v1).
    struct Obstacle: Equatable {
        var x: Double          // fraction of width
        var y: Double          // fraction of height, y UP
        var radius: Double     // fraction of min side
    }

    struct Result: Equatable {
        /// Offset to the source centre, fractions of `min(width, height)`, y UP.
        var dx: Double
        var dy: Double
        var cost: Double
    }

    static let distances: [Double] = [2.6, 3.5, 5.0, 7.0]   // in spot radii
    static let angleCount = 16

    /// Returns `nil` — and the caller MUST then fall back (e.g. a default offset the user can drag) — when the
    /// inputs are not finite, when no destination ring fits inside the bitmap (the spot is within about 2 radii of
    /// the frame edge — common for dust near a border), or when every candidate is blocked by an obstacle or falls
    /// outside the frame. `radius` is clamped to `RetouchSpot.radiusRange` (a fraction of the min side).
    static func bestSource(
        in bitmap: Bitmap, x: Double, y: Double, radius rawRadius: Double, avoiding obstacles: [Obstacle] = []
    ) -> Result? {
        guard x.isFinite, y.isFinite, rawRadius.isFinite,
              obstacles.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.radius.isFinite })
        else { return nil }
        let radius = min(max(rawRadius, RetouchSpot.radiusRange.lowerBound), RetouchSpot.radiusRange.upperBound)
        let w = bitmap.width, h = bitmap.height
        let minSide = Double(min(w, h))
        let r = max(radius * minSide, 2)
        let cx = x * Double(w)
        let cy = (1 - y) * Double(h)            // bitmap rows run top-down
        let rin = r * 1.25, rout = r * 2.0
        let reach = Int(rout.rounded(.up))

        // One fixed sample pattern for the destination AND every candidate.
        var offsets: [(Int, Int)] = []
        for dy in -reach...reach {
            for dx in -reach...reach {
                let d = (Double(dx * dx + dy * dy)).squareRoot()
                if d >= rin && d <= rout { offsets.append((dx, dy)) }
            }
        }
        guard !offsets.isEmpty else { return nil }

        func ring(_ ax: Double, _ ay: Double) -> [Float]? {
            let icx = Int(ax.rounded()), icy = Int(ay.rounded())
            guard icx - reach >= 0, icy - reach >= 0, icx + reach < w, icy + reach < h else { return nil }
            var v = [Float]()
            v.reserveCapacity(offsets.count * 3)
            for (dx, dy) in offsets { for c in 0..<3 { v.append(bitmap.value(icx + dx, icy + dy, c)) } }
            return v
        }
        func meanRemoved(_ v: [Float]) -> (centered: [Float], means: [Float]) {
            var means = [Float](repeating: 0, count: 3)
            let n = v.count / 3
            for i in 0..<n { for c in 0..<3 { means[c] += v[i * 3 + c] } }
            for c in 0..<3 { means[c] /= Float(n) }
            var out = v
            for i in 0..<n { for c in 0..<3 { out[i * 3 + c] -= means[c] } }
            return (out, means)
        }

        guard let destination = ring(cx, cy) else { return nil }
        let (dCentered, dMeans) = meanRemoved(destination)
        var best: Result?
        for distance in distances {
            for k in 0..<angleCount {
                let angle = Double(k) / Double(angleCount) * 2 * .pi
                let ax = cx + cos(angle) * distance * r
                let ay = cy + sin(angle) * distance * r
                // Keep clear of other spots (in bitmap pixels; obstacle y is y-UP).
                let blocked = obstacles.contains { o in
                    let ox = o.x * Double(w), oy = (1 - o.y) * Double(h)
                    let gap = ((ox - ax) * (ox - ax) + (oy - ay) * (oy - ay)).squareRoot()
                    return gap < (o.radius * minSide + r) * 1.3
                }
                if blocked { continue }
                guard let candidate = ring(ax, ay) else { continue }
                let (cCentered, cMeans) = meanRemoved(candidate)
                var cost = 0.0
                for i in 0..<dCentered.count { cost += Double(abs(dCentered[i] - cCentered[i])) }
                cost /= Double(dCentered.count)
                for c in 0..<3 { cost += 0.5 * Double(abs(dMeans[c] - cMeans[c])) / 3 }
                if best == nil || cost < best!.cost {
                    // The offset that was actually SCORED (not `distance * radius`: `r` is floored at 2 px, so for a
                    // tiny radius those differ and the caller would get an unevaluated source). Bitmap rows run
                    // down while the offset is y UP: flip dy.
                    best = Result(dx: (ax - cx) / minSide, dy: -(ay - cy) / minSide, cost: cost)
                }
            }
        }
        return best
    }
}
