import CoreGraphics
import simd
import XCTest

/// PERMANENT feasibility probe for a hand-built feature matcher (Harris corners + intensity-centroid orientation + normalised-patch
/// descriptors + mutual ratio-test matching + RANSAC homography). Nothing in `Sources/` uses it yet: it measures whether this approach
/// closes the gap `PanoramaRegistrationProbeTests` found (Vision's homography only handles small motion; its translational request's
/// dy is unreliable on large pans). Frames come from a rotating pinhole camera over a synthetic sphere, so the exact homography is known.
/// Results: docs/ROADMAP_HISTORY.md "Photo Merge spike".
final class FeatureMatchProbeTests: XCTestCase {
    private static let width = 480, height = 320
    private static let focal: Float = 480 / 2 / tan(30 * .pi / 180)

    // MARK: Scene

    private struct Blob { let lon: Float, lat: Float, size: Float, value: Float }
    private static let blobs: [Blob] = {
        var seed: UInt64 = 0xC0FFEE1234567
        func next() -> Float { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Float((seed >> 33) & 0xFFFF) / 65535 }
        return (0..<400).map { _ in Blob(lon: (next() - 0.5) * 2.2, lat: (next() - 0.5) * 0.9, size: 0.012 + next() * 0.03, value: next()) }
    }()

    private static var intrinsics: simd_float3x3 {
        simd_float3x3(columns: (SIMD3(focal, 0, 0), SIMD3(0, focal, 0), SIMD3(Float(width) / 2, Float(height) / 2, 1)))
    }

    /// Camera-to-world rotation from yaw (about y), pitch (about x) and roll (about z), radians.
    private static func rotation(yaw: Float, pitch: Float = 0, roll: Float = 0) -> simd_float3x3 {
        let ry = simd_float3x3(columns: (SIMD3(cos(yaw), 0, -sin(yaw)), SIMD3(0, 1, 0), SIMD3(sin(yaw), 0, cos(yaw))))
        let rx = simd_float3x3(columns: (SIMD3(1, 0, 0), SIMD3(0, cos(pitch), sin(pitch)), SIMD3(0, -sin(pitch), cos(pitch))))
        let rz = simd_float3x3(columns: (SIMD3(cos(roll), sin(roll), 0), SIMD3(-sin(roll), cos(roll), 0), SIMD3(0, 0, 1)))
        return ry * rx * rz
    }

    private static func frame(_ r: simd_float3x3) -> Gray {
        let kInv = intrinsics.inverse
        var px = [Float](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width {
            let d = r * (kInv * SIMD3(Float(x), Float(y), 1))
            let lon = atan2(d.x, d.z), lat = atan2(-d.y, hypot(d.x, d.z))
            var v: Float = 0.15
            for b in blobs {
                let dl = lon - b.lon, dt = lat - b.lat
                let q = (dl * dl + dt * dt) / (b.size * b.size)
                if q < 9 { v += (b.value - 0.15) * exp(-q) }
            }
            px[y * width + x] = min(max(v, 0), 1)
        } }
        return Gray(w: width, h: height, px: px)
    }

    private static func truth(from rb: simd_float3x3, to ra: simd_float3x3) -> simd_float3x3 { intrinsics * ra.transpose * rb * intrinsics.inverse }

    private static func apply(_ h: simd_float3x3, _ p: SIMD2<Float>) -> SIMD2<Float> {
        let q = h * SIMD3(p.x, p.y, 1)
        return SIMD2(q.x / q.z, q.y / q.z)
    }

    // MARK: Matcher prototype

    struct Gray { let w: Int, h: Int; var px: [Float]
        func at(_ x: Int, _ y: Int) -> Float { px[y * w + x] }
        func bilinear(_ x: Float, _ y: Float) -> Float {
            let x0 = Int(floor(x)), y0 = Int(floor(y)); let fx = x - Float(x0), fy = y - Float(y0)
            let a = at(x0, y0), b = at(x0 + 1, y0), c = at(x0, y0 + 1), d = at(x0 + 1, y0 + 1)
            return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy
        }
    }

    struct Keypoint { var p: SIMD2<Float>; var descriptor: [Float] }
    private static let patchRadius = 10 // 21x21 patch

    static func keypoints(_ g: Gray, maxCount: Int = 500) -> [Keypoint] {
        let margin = patchRadius + 6
        var ixx = [Float](repeating: 0, count: g.w * g.h), iyy = ixx, ixy = ixx
        for y in 1..<(g.h - 1) { for x in 1..<(g.w - 1) {
            let gx = (g.at(x + 1, y) - g.at(x - 1, y)) / 2, gy = (g.at(x, y + 1) - g.at(x, y - 1)) / 2
            ixx[y * g.w + x] = gx * gx; iyy[y * g.w + x] = gy * gy; ixy[y * g.w + x] = gx * gy
        } }
        var scored: [(Float, Int, Int)] = []
        for y in margin..<(g.h - margin) { for x in margin..<(g.w - margin) {
            var a: Float = 0, b: Float = 0, c: Float = 0
            for dy in -2...2 { for dx in -2...2 { let i = (y + dy) * g.w + x + dx; a += ixx[i]; b += iyy[i]; c += ixy[i] } }
            let r = a * b - c * c - 0.04 * (a + b) * (a + b)
            if r > 1e-5 { scored.append((r, x, y)) }
        } }
        scored.sort { $0.0 > $1.0 }
        var accepted: [(Int, Int)] = []
        for (_, x, y) in scored {
            if accepted.allSatisfy({ abs($0.0 - x) > 8 || abs($0.1 - y) > 8 }) { accepted.append((x, y)) }
            if accepted.count >= maxCount { break }
        }
        return accepted.compactMap { x, y in
            // Orientation: intensity centroid (ORB), radius 8.
            var m10: Float = 0, m01: Float = 0
            for dy in -8...8 { for dx in -8...8 where dx * dx + dy * dy <= 64 {
                let v = g.at(x + dx, y + dy); m10 += Float(dx) * v; m01 += Float(dy) * v
            } }
            let theta = atan2(m01, m10), c = cos(theta), s = sin(theta)
            var d: [Float] = []
            d.reserveCapacity((2 * patchRadius + 1) * (2 * patchRadius + 1))
            for v in -patchRadius...patchRadius { for u in -patchRadius...patchRadius {
                let sx = Float(x) + c * Float(u) - s * Float(v), sy = Float(y) + s * Float(u) + c * Float(v)
                d.append(g.bilinear(sx, sy))
            } }
            let mean = d.reduce(0, +) / Float(d.count)
            var norm: Float = 0
            for i in d.indices { d[i] -= mean; norm += d[i] * d[i] }
            norm = sqrt(norm)
            guard norm > 1e-3 else { return nil }
            for i in d.indices { d[i] /= norm }
            return Keypoint(p: SIMD2(Float(x), Float(y)), descriptor: d)
        }
    }

    /// Mutual nearest neighbours (by correlation) that also pass Lowe's ratio test on the B -> A direction.
    static func match(_ b: [Keypoint], _ a: [Keypoint], ratio: Float = 0.85) -> [(SIMD2<Float>, SIMD2<Float>)] {
        func dot(_ x: [Float], _ y: [Float]) -> Float { var s: Float = 0; for i in x.indices { s += x[i] * y[i] }; return s }
        var bestForA = [Int](repeating: -1, count: a.count), bestScoreA = [Float](repeating: -2, count: a.count)
        var forward: [(Int, Int, Float)] = []
        for (i, kb) in b.enumerated() {
            var best = -2 as Float, second = -2 as Float, bestJ = -1
            for (j, ka) in a.enumerated() {
                let c = dot(kb.descriptor, ka.descriptor)
                if c > best { second = best; best = c; bestJ = j } else if c > second { second = c }
                if c > bestScoreA[j] { bestScoreA[j] = c; bestForA[j] = i }
            }
            // distance^2 = 2 - 2 corr for unit vectors; ratio test on distances.
            let d1 = sqrt(max(2 - 2 * best, 0)), d2 = sqrt(max(2 - 2 * second, 0))
            if bestJ >= 0, d1 < ratio * d2 { forward.append((i, bestJ, best)) }
        }
        return forward.filter { bestForA[$0.1] == $0.0 }.map { (b[$0.0].p, a[$0.1].p) }
    }

    /// Solve A x = rhs (n x n) by Gaussian elimination with partial pivoting; nil if singular.
    static func solve(_ a: [[Double]], _ rhs: [Double]) -> [Double]? {
        let n = rhs.count
        var m = a; var r = rhs
        for col in 0..<n {
            var pivot = col
            for row in col..<n where abs(m[row][col]) > abs(m[pivot][col]) { pivot = row }
            guard abs(m[pivot][col]) > 1e-12 else { return nil }
            m.swapAt(col, pivot); r.swapAt(col, pivot)
            for row in (col + 1)..<max(n, col + 1) where row < n {
                let f = m[row][col] / m[col][col]
                for k in col..<n { m[row][k] -= f * m[col][k] }
                r[row] -= f * r[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var s = r[row]
            for k in (row + 1)..<max(n, row + 1) where k < n { s -= m[row][k] * x[k] }
            x[row] = s / m[row][row]
        }
        return x
    }

    /// Least-squares homography (h33 = 1) from correspondences b -> a; points are conditioned by centring/scaling.
    static func fitHomography(_ pairs: [(SIMD2<Float>, SIMD2<Float>)]) -> simd_float3x3? {
        guard pairs.count >= 4 else { return nil }
        func conditioner(_ pts: [SIMD2<Float>]) -> (Double, Double, Double) {
            let cx = pts.reduce(0) { $0 + Double($1.x) } / Double(pts.count), cy = pts.reduce(0) { $0 + Double($1.y) } / Double(pts.count)
            let md = pts.reduce(0) { $0 + hypot(Double($1.x) - cx, Double($1.y) - cy) } / Double(pts.count)
            return (cx, cy, md > 0 ? sqrt(2) / md : 1)
        }
        let (bx, by, bs) = conditioner(pairs.map { $0.0 }), (ax, ay, as_) = conditioner(pairs.map { $0.1 })
        var ata = [[Double]](repeating: [Double](repeating: 0, count: 8), count: 8), atb = [Double](repeating: 0, count: 8)
        for (pb, pa) in pairs {
            let x = (Double(pb.x) - bx) * bs, y = (Double(pb.y) - by) * bs, u = (Double(pa.x) - ax) * as_, v = (Double(pa.y) - ay) * as_
            for (row, rhs) in [([x, y, 1, 0, 0, 0, -x * u, -y * u], u), ([0, 0, 0, x, y, 1, -x * v, -y * v], v)] {
                for i in 0..<8 { atb[i] += row[i] * rhs; for j in 0..<8 { ata[i][j] += row[i] * row[j] } }
            }
        }
        guard let h = solve(ata, atb) else { return nil }
        // H_conditioned maps conditioned b -> conditioned a; undo: H = Ta^-1 * Hc * Tb.
        let hc = simd_float3x3(columns: (SIMD3(Float(h[0]), Float(h[3]), Float(h[6])), SIMD3(Float(h[1]), Float(h[4]), Float(h[7])), SIMD3(Float(h[2]), Float(h[5]), 1)))
        let tb = simd_float3x3(columns: (SIMD3(Float(bs), 0, 0), SIMD3(0, Float(bs), 0), SIMD3(Float(-bx * bs), Float(-by * bs), 1)))
        let taInv = simd_float3x3(columns: (SIMD3(Float(1 / as_), 0, 0), SIMD3(0, Float(1 / as_), 0), SIMD3(Float(ax), Float(ay), 1)))
        return taInv * hc * tb
    }

    static func ransac(_ pairs: [(SIMD2<Float>, SIMD2<Float>)], iterations: Int = 2000, threshold: Float = 3) -> (simd_float3x3, Int)? {
        guard pairs.count >= 8 else { return nil }
        var seed: UInt64 = 42
        func rnd(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(n)) }
        func inliers(_ h: simd_float3x3) -> [Int] {
            pairs.indices.filter { i in
                let q = h * SIMD3(pairs[i].0.x, pairs[i].0.y, 1)
                guard abs(q.z) > 1e-6 else { return false }
                return simd_distance(SIMD2(q.x / q.z, q.y / q.z), pairs[i].1) < threshold
            }
        }
        var best: [Int] = []
        for _ in 0..<iterations {
            var idx = Set<Int>(); while idx.count < 4 { idx.insert(rnd(pairs.count)) }
            guard let h = fitHomography(idx.map { pairs[$0] }) else { continue }
            let found = inliers(h)
            if found.count > best.count { best = found }
        }
        guard best.count >= 8, var h = fitHomography(best.map { pairs[$0] }) else { return nil }
        for _ in 0..<2 { let refit = inliers(h); if refit.count >= 8, let h2 = fitHomography(refit.map { pairs[$0] }) { h = h2 } }
        return (h, inliers(h).count)
    }

    // MARK: Measurements

    private static func error(_ h: simd_float3x3, truth t: simd_float3x3) -> (mean: Float, max: Float, n: Int) {
        var errs: [Float] = []
        for y in stride(from: 20, to: height - 20, by: 40) { for x in stride(from: 20, to: width - 20, by: 40) {
            let p = SIMD2(Float(x), Float(y)), q = apply(t, p)
            if q.x > 10, q.x < Float(width) - 10, q.y > 10, q.y < Float(height) - 10 { errs.append(simd_distance(apply(h, p), q)) }
        } }
        return (errs.reduce(0, +) / Float(max(errs.count, 1)), errs.max() ?? .nan, errs.count)
    }

    private func run(_ name: String, a ra: simd_float3x3, b rb: simd_float3x3) throws -> (mean: Float, n: Int) {
        let ga = Self.frame(ra), gb = Self.frame(rb)
        let t0 = Date()
        let ka = Self.keypoints(ga), kb = Self.keypoints(gb)
        let matches = Self.match(kb, ka)
        let result = Self.ransac(matches)
        let seconds = Date().timeIntervalSince(t0)
        guard let (h, inliers) = result else {
            print("PROBE feature match \(name): keypoints \(kb.count)/\(ka.count) matches \(matches.count) NO MODEL (\(seconds)s)")
            return (.infinity, 0)
        }
        let e = Self.error(h, truth: Self.truth(from: rb, to: ra))
        print("PROBE feature match \(name): keypoints B/A \(kb.count)/\(ka.count) matches \(matches.count) inliers \(inliers) | error mean \(e.mean)px max \(e.max)px (n=\(e.n)) | \(seconds)s")
        return (e.mean, e.n)
    }

    /// Measured 2026-10-09 (Apple M1, macOS 27.0, Debug build, 480x320 frames, 60 degree FOV, ~85-105 keypoints per frame on this sparse synthetic
    /// scene): yaw 10 deg: 51 matches / 47 inliers, mean error 0.22 px; 20 deg: 36 / 25, 0.33 px (max 1.10); 30 deg: 30 / 14, 0.37 px (max 1.50);
    /// 40 deg (about 33% overlap): 27 matches, RANSAC found NO model. Timings (~2 s per pair) are from an UNOPTIMISED Debug build with array-based
    /// loops and are not representative. 10 and 40 deg are not re-run here to keep the suite fast.
    func testLevelYawSteps() throws {
        for degrees: Float in [20, 30] {
            let r = try run("yaw \(degrees)", a: Self.rotation(yaw: 0), b: Self.rotation(yaw: degrees * .pi / 180))
            XCTAssertLessThan(r.mean, 2, "yaw \(degrees)")
        }
    }

    /// Measured same setup: yaw 20 + pitch 5 + roll 5 deg: 31 matches / 21 inliers, mean 0.56 px (max 1.09); yaw 15 + pitch -8 + roll 12 deg: 33 / 23,
    /// mean 0.29 px (max 0.56). The second case is not re-run here (suite time). Vision's homography and translation could not do either.
    func testPitchAndRollBetweenFrames() throws {
        let deg: Float = .pi / 180
        let r = try run("yaw 20 + pitch 5 + roll 5", a: Self.rotation(yaw: 0), b: Self.rotation(yaw: 20 * deg, pitch: 5 * deg, roll: 5 * deg))
        XCTAssertLessThan(r.mean, 3)
    }
}
