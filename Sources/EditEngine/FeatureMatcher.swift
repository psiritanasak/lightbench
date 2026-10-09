import Accelerate
import Foundation
import simd

/// Estimates the homography between two overlapping photos from image content alone: Harris corners, ORB-style intensity-centroid
/// orientation, rotated 21x21 zero-mean unit-norm patch descriptors, mutual nearest-neighbour matching with a ratio test, then RANSAC.
/// Pure and `CoreImage`-free (it works on a plain grayscale float buffer), so it is plain-XCTest-testable with exact truth.
///
/// WHY this exists (docs/ROADMAP_HISTORY.md, "Photo Merge spike"): Vision's `VNHomographicImageRegistrationRequest` is a small-motion API
/// (mean error 0.055 px at 1 degree of camera yaw, 18 px at 4, 136 px at 20) and its translational request returned a wrong vertical
/// component on large level pans. This matcher measured 0.2-0.6 px mean error on real-photo crops shifted up to 65% of the frame, rotated to 10
/// degrees and scaled to 1.15x, and on synthetic rotating-camera frames up to a 30 degree yaw step plus pitch/roll.
///
/// Measured limits (not guarantees): the descriptor is rotation-aware but NOT scale-invariant; no model was found at ~33% overlap on the
/// synthetic scene; same-photo crops are the optimistic case (shared noise/exposure); true panorama frames (exposure drift, parallax,
/// distortion) are untested. A homography is exact only for a camera rotating about its nodal point or a planar scene.
///
/// Coordinates are TOP-LEFT pixel coordinates (x right, y down) of the buffers passed in, with the pixel CENTRE at the integer index.
/// Callers that registered a downscaled proxy must scale the result themselves (`scaled(_:by:)`); that plain scaling ignores the half-pixel
/// offset between a downscaled and a full-resolution pixel grid (up to ~0.5 px at full resolution for a 6x downscale with a rotation),
/// so treat the result as accurate to about that much, and refine at full resolution if more is needed.
/// Intended for PROXY-sized inputs (about 1000 px on the long side): the gradient buffers and candidate list grow with width x height and the
/// suppression step is quadratic in accepted points, so full-resolution frames should be downscaled first.
/// Detection uses an absolute Harris floor, so feed it gamma-encoded or normalised luminance, not dark linear data (a -2 EV linear frame
/// loses most corners); the descriptors themselves are gain-invariant.
enum FeatureMatcher {
    /// A grayscale image, `pixels` row-major, values nominally 0...1.
    struct GrayImage {
        let width: Int
        let height: Int
        let pixels: [Float]

        init?(width: Int, height: Int, pixels: [Float]) {
            guard width > 0, height > 0, pixels.count == width * height else { return nil }
            self.width = width
            self.height = height
            self.pixels = pixels
        }

        func at(_ x: Int, _ y: Int) -> Float { pixels[y * width + x] }

        /// Bilinear sample; callers keep (x, y) at least one pixel inside the image.
        func bilinear(_ x: Float, _ y: Float) -> Float {
            let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down))
            let fx = x - Float(x0), fy = y - Float(y0)
            let top = at(x0, y0) * (1 - fx) + at(x0 + 1, y0) * fx
            let bottom = at(x0, y0 + 1) * (1 - fx) + at(x0 + 1, y0 + 1) * fx
            return top * (1 - fy) + bottom * fy
        }
    }

    /// Keypoints plus their descriptors stored as one contiguous row-major matrix (`count` rows of `descriptorLength`).
    struct KeypointSet {
        var points: [SIMD2<Float>] = []
        var descriptors: [Float] = []
        var count: Int { points.count }
    }

    struct Match: Equatable {
        /// Position in the TARGET image.
        let target: SIMD2<Float>
        /// Position of the same content in the REFERENCE image.
        let reference: SIMD2<Float>
    }

    struct Registration {
        /// Maps TARGET pixels to REFERENCE pixels (top-left coordinates of the buffers given to `register`).
        let homography: simd_float3x3
        let inlierCount: Int
        let matchCount: Int
        let targetKeypointCount: Int
        let referenceKeypointCount: Int
        var inlierRatio: Double { matchCount == 0 ? 0 : Double(inlierCount) / Double(matchCount) }
    }

    // MARK: Tunables (values the spike measured with)

    static let patchRadius = 10
    static var descriptorLength: Int { (2 * patchRadius + 1) * (2 * patchRadius + 1) }
    static let ratioThreshold: Float = 0.85
    static let ransacThreshold: Float = 3
    static let ransacIterations = 2000
    static let minimumInliers = 12

    // MARK: Public entry point

    /// Registers `target` onto `reference`. Returns nil when there is too little texture, too few matches, no consistent model, or the model is
    /// geometrically implausible. Deterministic: RANSAC uses a fixed-seed generator.
    static func register(target: GrayImage, reference: GrayImage, maxKeypoints: Int = 1000) -> Registration? {
        let kt = keypoints(in: target, maxCount: maxKeypoints)
        let kr = keypoints(in: reference, maxCount: maxKeypoints)
        let matches = match(target: kt, reference: kr)
        guard let (h, inliers) = ransac(matches), isPlausible(h, width: target.width, height: target.height) else { return nil }
        return Registration(homography: h, inlierCount: inliers, matchCount: matches.count,
                            targetKeypointCount: kt.count, referenceKeypointCount: kr.count)
    }

    /// The same homography expressed for images `factor` times larger (or smaller) than the ones it was estimated on.
    static func scaled(_ h: simd_float3x3, by factor: Float) -> simd_float3x3 {
        let s = simd_float3x3(columns: (SIMD3(factor, 0, 0), SIMD3(0, factor, 0), SIMD3(0, 0, 1)))
        let sInv = simd_float3x3(columns: (SIMD3(1 / factor, 0, 0), SIMD3(0, 1 / factor, 0), SIMD3(0, 0, 1)))
        return s * h * sInv
    }

    static func apply(_ h: simd_float3x3, to p: SIMD2<Float>) -> SIMD2<Float> {
        let q = h * SIMD3(p.x, p.y, 1)
        return SIMD2(q.x / q.z, q.y / q.z)
    }

    /// Rejects matrices that are finite but cannot be a plausible photo-to-photo map: a flipped or near-collapsed image, a huge scale change,
    /// or strong perspective that sends a corner to infinity.
    static func isPlausible(_ h: simd_float3x3, width: Int, height: Int) -> Bool {
        let det = h.columns.0.x * h.columns.1.y - h.columns.1.x * h.columns.0.y
        guard det.isFinite, det > 0.04, det < 25 else { return false }
        for corner in [SIMD2<Float>(0, 0), SIMD2(Float(width), 0), SIMD2(0, Float(height)), SIMD2(Float(width), Float(height))] {
            let w = (h * SIMD3(corner.x, corner.y, 1)).z
            guard w.isFinite, w > 0.1, w < 10 else { return false }
        }
        return true
    }

    // MARK: Keypoints and descriptors

    static func keypoints(in g: GrayImage, maxCount: Int) -> KeypointSet {
        // A patch rotated by any angle reaches patchRadius * sqrt(2) from the centre; +2 leaves room for the bilinear +1 and the gradient ring.
        let margin = Int((Float(patchRadius) * Float(2).squareRoot()).rounded(.up)) + 2
        guard g.width > 2 * margin + 2, g.height > 2 * margin + 2, maxCount > 0 else { return KeypointSet() }
        let w = g.width, h = g.height
        var ixx = [Float](repeating: 0, count: w * h), iyy = ixx, ixy = ixx
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let gx = (g.at(x + 1, y) - g.at(x - 1, y)) / 2, gy = (g.at(x, y + 1) - g.at(x, y - 1)) / 2
                let i = y * w + x
                ixx[i] = gx * gx; iyy[i] = gy * gy; ixy[i] = gx * gy
            }
        }
        var scored: [(score: Float, x: Int, y: Int)] = []
        for y in margin..<(h - margin) {
            for x in margin..<(w - margin) {
                var a: Float = 0, b: Float = 0, c: Float = 0
                for dy in -2...2 {
                    let row = (y + dy) * w + x
                    for dx in -2...2 { a += ixx[row + dx]; b += iyy[row + dx]; c += ixy[row + dx] }
                }
                let response = a * b - c * c - 0.04 * (a + b) * (a + b)
                if response > 1e-5 { scored.append((response, x, y)) }
            }
        }
        scored.sort { $0.score > $1.score }
        var accepted: [(x: Int, y: Int)] = []
        for s in scored {
            if accepted.allSatisfy({ abs($0.x - s.x) > 8 || abs($0.y - s.y) > 8 }) { accepted.append((s.x, s.y)) }
            if accepted.count >= maxCount { break }
        }
        var set = KeypointSet()
        set.descriptors.reserveCapacity(accepted.count * descriptorLength)
        var patch = [Float](repeating: 0, count: descriptorLength)
        for (x, y) in accepted {
            var m10: Float = 0, m01: Float = 0
            for dy in -8...8 {
                for dx in -8...8 where dx * dx + dy * dy <= 64 {
                    let v = g.at(x + dx, y + dy)
                    m10 += Float(dx) * v; m01 += Float(dy) * v
                }
            }
            let theta = atan2(m01, m10), c = cos(theta), s = sin(theta)
            var i = 0
            for v in -patchRadius...patchRadius {
                for u in -patchRadius...patchRadius {
                    patch[i] = g.bilinear(Float(x) + c * Float(u) - s * Float(v), Float(y) + s * Float(u) + c * Float(v))
                    i += 1
                }
            }
            let mean = patch.reduce(0, +) / Float(descriptorLength)
            var norm: Float = 0
            for k in 0..<descriptorLength { patch[k] -= mean; norm += patch[k] * patch[k] }
            norm = norm.squareRoot()
            guard norm > 1e-3 else { continue } // a flat patch carries no information
            for k in 0..<descriptorLength { patch[k] /= norm }
            set.points.append(SIMD2(Float(x), Float(y)))
            set.descriptors.append(contentsOf: patch)
        }
        return set
    }

    // MARK: Matching

    /// Mutual nearest neighbours by correlation that also pass Lowe's ratio test on the target -> reference direction.
    static func match(target: KeypointSet, reference: KeypointSet) -> [Match] {
        let nt = target.count, nr = reference.count
        guard nt > 0, nr > 1 else { return [] }
        // scores[i * nr + j] = correlation of target i with reference j (descriptors are unit vectors): (nt x L) * (L x nr).
        var referenceTransposed = [Float](repeating: 0, count: descriptorLength * nr)
        for j in 0..<nr {
            for k in 0..<descriptorLength { referenceTransposed[k * nr + j] = reference.descriptors[j * descriptorLength + k] }
        }
        var scores = [Float](repeating: 0, count: nt * nr)
        vDSP_mmul(target.descriptors, 1, referenceTransposed, 1, &scores, 1, vDSP_Length(nt), vDSP_Length(nr), vDSP_Length(descriptorLength))
        var bestTargetForReference = [Int](repeating: -1, count: nr)
        var bestScoreForReference = [Float](repeating: -.infinity, count: nr)
        var forward: [(target: Int, reference: Int)] = []
        for i in 0..<nt {
            var best: Float = -.infinity, second: Float = -.infinity, bestJ = -1
            for j in 0..<nr {
                let c = scores[i * nr + j]
                if c > best { second = best; best = c; bestJ = j } else if c > second { second = c }
                if c > bestScoreForReference[j] { bestScoreForReference[j] = c; bestTargetForReference[j] = i }
            }
            // For unit vectors distance = sqrt(2 - 2 corr).
            let d1 = max(2 - 2 * best, 0).squareRoot(), d2 = max(2 - 2 * second, 0).squareRoot()
            if bestJ >= 0, d1 < ratioThreshold * d2 { forward.append((i, bestJ)) }
        }
        return forward.filter { bestTargetForReference[$0.reference] == $0.target }
            .map { Match(target: target.points[$0.target], reference: reference.points[$0.reference]) }
    }

    // MARK: Homography estimation

    /// Solves the n x n system `a x = rhs` by Gaussian elimination with partial pivoting; nil if (numerically) singular.
    static func solve(_ a: [[Double]], _ rhs: [Double]) -> [Double]? {
        let n = rhs.count
        guard n > 0, a.count == n, a.allSatisfy({ $0.count == n }) else { return nil }
        var m = a, r = rhs
        for col in 0..<n {
            var pivot = col
            for row in col..<n where abs(m[row][col]) > abs(m[pivot][col]) { pivot = row }
            guard abs(m[pivot][col]) > 1e-12 else { return nil }
            m.swapAt(col, pivot); r.swapAt(col, pivot)
            for row in stride(from: col + 1, to: n, by: 1) {
                let f = m[row][col] / m[col][col]
                for k in col..<n { m[row][k] -= f * m[col][k] }
                r[row] -= f * r[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var s = r[row]
            for k in stride(from: row + 1, to: n, by: 1) { s -= m[row][k] * x[k] }
            x[row] = s / m[row][row]
        }
        return x
    }

    /// Least-squares homography (h33 = 1) from at least 4 correspondences, with Hartley-style conditioning (centre and scale each point set).
    static func fitHomography(_ matches: [Match]) -> simd_float3x3? {
        guard matches.count >= 4 else { return nil }
        func conditioner(_ pts: [SIMD2<Float>]) -> (cx: Double, cy: Double, scale: Double) {
            let n = Double(pts.count)
            let cx = pts.reduce(0) { $0 + Double($1.x) } / n, cy = pts.reduce(0) { $0 + Double($1.y) } / n
            let mean = pts.reduce(0) { $0 + hypot(Double($1.x) - cx, Double($1.y) - cy) } / n
            return (cx, cy, mean > 0 ? 2.0.squareRoot() / mean : 1)
        }
        let tc = conditioner(matches.map(\.target)), rc = conditioner(matches.map(\.reference))
        var ata = [[Double]](repeating: [Double](repeating: 0, count: 8), count: 8)
        var atb = [Double](repeating: 0, count: 8)
        for m in matches {
            let x = (Double(m.target.x) - tc.cx) * tc.scale, y = (Double(m.target.y) - tc.cy) * tc.scale
            let u = (Double(m.reference.x) - rc.cx) * rc.scale, v = (Double(m.reference.y) - rc.cy) * rc.scale
            for (row, rhs) in [([x, y, 1, 0, 0, 0, -x * u, -y * u], u), ([0, 0, 0, x, y, 1, -x * v, -y * v], v)] {
                for i in 0..<8 {
                    atb[i] += row[i] * rhs
                    for j in 0..<8 { ata[i][j] += row[i] * row[j] }
                }
            }
        }
        guard let h = solve(ata, atb) else { return nil }
        let hc = simd_float3x3(columns: (SIMD3(Float(h[0]), Float(h[3]), Float(h[6])), SIMD3(Float(h[1]), Float(h[4]), Float(h[7])), SIMD3(Float(h[2]), Float(h[5]), 1)))
        let tb = simd_float3x3(columns: (SIMD3(Float(tc.scale), 0, 0), SIMD3(0, Float(tc.scale), 0), SIMD3(Float(-tc.cx * tc.scale), Float(-tc.cy * tc.scale), 1)))
        let raInv = simd_float3x3(columns: (SIMD3(Float(1 / rc.scale), 0, 0), SIMD3(0, Float(1 / rc.scale), 0), SIMD3(Float(rc.cx), Float(rc.cy), 1)))
        let result = raInv * hc * tb
        guard (0..<3).allSatisfy({ c in (0..<3).allSatisfy { result[c][$0].isFinite } }) else { return nil }
        return result
    }

    /// RANSAC over `fitHomography`; returns the refit model and its inlier count, nil if fewer than `minimumInliers` agree.
    static func ransac(_ matches: [Match], iterations: Int = ransacIterations, threshold: Float = ransacThreshold) -> (simd_float3x3, Int)? {
        guard matches.count >= minimumInliers else { return nil }
        var state: UInt64 = 42
        func random(below n: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(n))
        }
        func inlierIndices(_ h: simd_float3x3) -> [Int] {
            matches.indices.filter { i in
                let q = h * SIMD3(matches[i].target.x, matches[i].target.y, 1)
                guard abs(q.z) > 1e-6 else { return false }
                return simd_distance(SIMD2(q.x / q.z, q.y / q.z), matches[i].reference) < threshold
            }
        }
        var best: [Int] = []
        for _ in 0..<iterations {
            // An ORDERED sample (not a Set): Set iteration order changes per process, which would change floating-point summation order.
            var sample: [Int] = []
            while sample.count < 4 {
                let index = random(below: matches.count)
                if !sample.contains(index) { sample.append(index) }
            }
            guard let h = fitHomography(sample.map { matches[$0] }) else { continue }
            let found = inlierIndices(h)
            if found.count > best.count { best = found }
        }
        guard best.count >= minimumInliers, var h = fitHomography(best.map { matches[$0] }) else { return nil }
        for _ in 0..<2 {
            let refit = inlierIndices(h)
            if refit.count >= minimumInliers, let h2 = fitHomography(refit.map { matches[$0] }) { h = h2 }
        }
        let count = inlierIndices(h).count
        return count >= minimumInliers ? (h, count) : nil
    }
}
