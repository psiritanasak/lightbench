import Foundation
import simd

/// Pure geometry for a planar panorama: chains the homographies between CONSECUTIVE frames into one map per frame to a shared canvas.
///
/// Frames are given in shooting order. `pairs[k]` maps frame `k + 1` pixels to frame `k` pixels (what `FeatureMatcher.register(target: k + 1,
/// reference: k)` returns). The MIDDLE frame is the reference (its geometry is kept; chains are shortest in both directions, so registration
/// error accumulates least). All maps are TOP-LEFT pixel coordinates of the full-resolution frames.
///
/// A homography chain is exact only for a camera rotating about its nodal point (or a flat scene) and it stretches badly toward wide fields of view
/// (docs/ROADMAP_HISTORY.md, Photo Merge spike), so a plan is REFUSED when a frame's corners leave a sane region: a corner sent to or behind
/// infinity, a collapsed or huge frame, or a canvas larger than `maxCanvasPixels`.
enum PanoramaPlan {
    struct FramePlacement: Equatable {
        /// Frame pixel -> canvas pixel (canvas origin top-left, already translated to be non-negative).
        let toCanvas: simd_float3x3
    }

    struct Plan: Equatable {
        let referenceIndex: Int
        let canvasWidth: Int
        let canvasHeight: Int
        let placements: [FramePlacement]
    }

    enum PlanError: Error, Equatable {
        case tooFewFrames
        case tooManyFrames(limit: Int)
        /// Frame index whose placement is geometrically implausible (corner at/behind infinity, collapsed, mirrored or absurdly large).
        case implausibleFrame(index: Int)
        case canvasTooLarge
    }

    static let maxFrames = 12
    /// 200 MP: an 8 bytes/pixel half-float TIFF is already 1.6 GB, and the write needs that much again for its bitmap on top of Core Image's own
    /// intermediates — NOT measured; the target machine has 8 GB.
    static let maxCanvasPixels = 200_000_000

    static func plan(pairs: [simd_float3x3], frameWidth: Int, frameHeight: Int) -> Result<Plan, PlanError> {
        let n = pairs.count + 1
        guard n >= 2 else { return .failure(.tooFewFrames) }
        guard n <= maxFrames else { return .failure(.tooManyFrames(limit: maxFrames)) }
        let reference = (n - 1) / 2
        var toReference = [simd_float3x3](repeating: matrix_identity_float3x3, count: n)
        if reference + 1 < n {
            var m = matrix_identity_float3x3
            for i in (reference + 1)..<n { m = m * pairs[i - 1]; toReference[i] = normalized(m) } // x_i -> x_(i-1) -> ... -> x_ref
        }
        if reference > 0 {
            var m = matrix_identity_float3x3
            for i in stride(from: reference - 1, through: 0, by: -1) { m = m * pairs[i].inverse; toReference[i] = normalized(m) } // x_i -> x_(i+1) -> ... -> x_ref
        }
        let w = Float(frameWidth), h = Float(frameHeight)
        var minX = Float.infinity, minY = Float.infinity, maxX = -Float.infinity, maxY = -Float.infinity
        for (i, m) in toReference.enumerated() {
            guard let corners = mappedCorners(m, w, h), isPlausible(corners, frameWidth: w, frameHeight: h) else { return .failure(.implausibleFrame(index: i)) }
            for c in corners { minX = min(minX, c.x); minY = min(minY, c.y); maxX = max(maxX, c.x); maxY = max(maxY, c.y) }
        }
        let originX = minX.rounded(.down), originY = minY.rounded(.down)
        let extentW = (maxX - originX).rounded(.up), extentH = (maxY - originY).rounded(.up)
        // Check the FLOAT extents before converting (Int(Float) traps beyond Int.max), then the area.
        guard extentW.isFinite, extentH.isFinite, extentW > 0, extentH > 0, extentW <= 1_000_000, extentH <= 1_000_000,
              Double(extentW) * Double(extentH) <= Double(maxCanvasPixels) else { return .failure(.canvasTooLarge) }
        let canvasW = Int(extentW), canvasH = Int(extentH)
        let shift = simd_float3x3(columns: (SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(-originX, -originY, 1)))
        return .success(Plan(referenceIndex: reference, canvasWidth: canvasW, canvasHeight: canvasH, placements: toReference.map { FramePlacement(toCanvas: shift * $0) }))
    }

    /// Brightness of every frame relative to the reference, from the measured brightness ratio of each CONSECUTIVE pair (`pairGains[k]` =
    /// brightness of frame `k + 1` / brightness of frame `k`, 1 when unknown). The reference's own entry is exactly 1; dividing a frame by its
    /// entry brings it to the reference exposure. Auto-exposure drift across a sweep is the normal cause.
    static func exposureGains(pairGains: [Float], referenceIndex: Int) -> [Float] {
        let n = pairGains.count + 1
        guard referenceIndex >= 0, referenceIndex < n else { return [Float](repeating: 1, count: n) }
        var gains = [Float](repeating: 1, count: n)
        var running: Float = 1
        for i in stride(from: referenceIndex + 1, to: n, by: 1) { running *= pairGains[i - 1]; gains[i] = running } // i brighter than i-1 by pairGains[i-1]
        running = 1
        for i in stride(from: referenceIndex - 1, through: 0, by: -1) { running /= pairGains[i]; gains[i] = running } // i is pairGains[i] times darker than i+1
        return gains
    }

    /// Indices into the input in SHOOTING order: by capture date when every frame has one (ties and anything else by file name), otherwise by file
    /// name alone (camera file numbers increase in shooting order).
    static func shootingOrder(dates: [Date?], names: [String]) -> [Int] {
        guard dates.count == names.count else { return Array(names.indices) }
        let allDated = dates.allSatisfy { $0 != nil }
        return names.indices.sorted { a, b in
            if allDated, let da = dates[a], let db = dates[b], da != db { return da < db }
            let c = names[a].localizedStandardCompare(names[b])
            return c == .orderedSame ? a < b : c == .orderedAscending
        }
    }

    /// The largest axis-aligned rectangle (in FULL-RESOLUTION canvas pixels) that every pixel of which is covered by at least one frame — the
    /// auto-crop of the ragged edges. Found on a coverage mask rasterised at no more than `maskLongEdge` pixels (each frame's mapped quad, which is
    /// convex for any accepted plan), then scaled back up and shrunk by `margin` full-resolution pixels so edge interpolation never shows.
    static func autoCropRectangle(plan: Plan, frameWidth: Int, frameHeight: Int, maskLongEdge: Int = 800, margin: Int = 4) -> LargestRectangle.Rect? {
        let scale = min(1, Float(maskLongEdge) / Float(max(plan.canvasWidth, plan.canvasHeight)))
        let mw = max(1, Int((Float(plan.canvasWidth) * scale).rounded(.up))), mh = max(1, Int((Float(plan.canvasHeight) * scale).rounded(.up)))
        var mask = [Bool](repeating: false, count: mw * mh)
        for placement in plan.placements {
            guard let quad = mappedCorners(placement.toCanvas, Float(frameWidth), Float(frameHeight)) else { continue }
            let q = quad.map { $0 * scale }
            // Order for a convex polygon walk: tl, tr, br, bl.
            let poly = [q[0], q[1], q[3], q[2]]
            func inside(_ p: SIMD2<Float>) -> Bool {
                for k in 0..<4 {
                    let a = poly[k], b = poly[(k + 1) % 4]
                    if (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x) < 0 { return false }
                }
                return true
            }
            let ys = poly.map(\.y), xs = poly.map(\.x)
            guard let lowY = ys.min(), let highY = ys.max(), let lowX = xs.min(), let highX = xs.max() else { continue }
            let minY = max(0, Int(lowY.rounded(.down))), maxY = min(mh - 1, Int(highY.rounded(.up)))
            let minX = max(0, Int(lowX.rounded(.down))), maxX = min(mw - 1, Int(highX.rounded(.up)))
            guard minY <= maxY, minX <= maxX else { continue }
            for y in minY...maxY {
                for x in minX...maxX {
                    // A cell is covered only if ALL FOUR corners lie inside this one frame: a cell is `1 / scale` full-resolution pixels wide, so testing
                    // only its centre would count a cell whose outer half sticks out of every frame (up to ~7 px at an 18000 px canvas).
                    let fx = Float(x), fy = Float(y)
                    if inside(SIMD2(fx, fy)) && inside(SIMD2(fx + 1, fy)) && inside(SIMD2(fx, fy + 1)) && inside(SIMD2(fx + 1, fy + 1)) { mask[y * mw + x] = true }
                }
            }
        }
        guard let r = LargestRectangle.find(mask: mask, width: mw, height: mh) else { return nil }
        let inv = 1 / scale
        let x0 = Int((Float(r.x) * inv).rounded(.up)) + margin, y0 = Int((Float(r.y) * inv).rounded(.up)) + margin
        let x1 = min(plan.canvasWidth, Int((Float(r.x + r.width) * inv).rounded(.down))) - margin
        let y1 = min(plan.canvasHeight, Int((Float(r.y + r.height) * inv).rounded(.down))) - margin
        guard x1 > x0, y1 > y0 else { return nil }
        return LargestRectangle.Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Parses an EXIF `DateTimeOriginal` ("yyyy:MM:dd HH:mm:ss", local wall-clock) plus an optional `SubsecTimeOriginal` ("37" = 0.37 s).
    static func parseExifDate(_ text: String, subsecond: String?) -> Date? {
        let parts = text.split(whereSeparator: { $0 == ":" || $0 == " " }).compactMap { Int($0) }
        guard parts.count == 6, text.count >= 19, (1...12).contains(parts[1]), (1...31).contains(parts[2]),
              (0...23).contains(parts[3]), (0...59).contains(parts[4]), (0...60).contains(parts[5]) else { return nil } // Calendar would roll an impossible date over
        var components = DateComponents()
        components.year = parts[0]; components.month = parts[1]; components.day = parts[2]
        components.hour = parts[3]; components.minute = parts[4]; components.second = parts[5]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current // wall-clock only: a consistent zone is enough to ORDER frames
        guard let base = calendar.date(from: components) else { return nil }
        if let sub = subsecond?.trimmingCharacters(in: .whitespaces), !sub.isEmpty, sub.allSatisfy(\.isNumber), let digits = Double("0." + sub) { return base.addingTimeInterval(digits) }
        return base
    }

    /// Scales the matrix so its bottom-right entry is 1 (a chain of projective maps drifts in scale; `apply` divides by it anyway, but this keeps
    /// the entries well conditioned and makes the plausibility test below meaningful).
    static func normalized(_ m: simd_float3x3) -> simd_float3x3 {
        let s = m.columns.2.z
        return abs(s) > 1e-9 ? m * (1 / s) : m
    }

    /// The frame's four corners (top-left, top-right, bottom-left, bottom-right) under `m`, nil if any maps to a non-finite point.
    static func mappedCorners(_ m: simd_float3x3, _ w: Float, _ h: Float) -> [SIMD2<Float>]? {
        var out: [SIMD2<Float>] = []
        for c in [SIMD2<Float>(0, 0), SIMD2(w, 0), SIMD2(0, h), SIMD2(w, h)] {
            let q = m * SIMD3(c.x, c.y, 1)
            guard q.z.isFinite, q.z > 0.1, q.z < 10 else { return nil } // at/behind infinity, or an extreme perspective
            let p = SIMD2(q.x / q.z, q.y / q.z)
            guard p.x.isFinite, p.y.isFinite else { return nil }
            out.append(p)
        }
        return out
    }

    /// The mapped quadrilateral must keep its orientation (not mirrored/twisted), and its area must stay within 0.05x...16x of the frame's.
    static func isPlausible(_ corners: [SIMD2<Float>], frameWidth: Float, frameHeight: Float) -> Bool {
        let tl = corners[0], tr = corners[1], bl = corners[2], br = corners[3]
        func cross(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Float { (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) }
        // Every corner turn must have the same (positive, in y-down coordinates) sign: a convex, un-mirrored quad.
        let turns = [cross(tl, tr, br), cross(tr, br, bl), cross(br, bl, tl), cross(bl, tl, tr)]
        guard turns.allSatisfy({ $0 > 0 }) else { return false }
        let area = 0.5 * abs((tl.x * tr.y - tr.x * tl.y) + (tr.x * br.y - br.x * tr.y) + (br.x * bl.y - bl.x * br.y) + (bl.x * tl.y - tl.x * bl.y))
        let ratio = area / (frameWidth * frameHeight)
        return ratio > 0.05 && ratio < 16
    }
}

/// The largest axis-aligned rectangle of valid pixels in a mask — the auto-crop of a panorama's ragged edges.
enum LargestRectangle {
    struct Rect: Equatable {
        let x: Int, y: Int, width: Int, height: Int
        var area: Int { width * height }
    }

    /// `mask[y * width + x]` true = valid. Classic histogram-stack maximal-rectangle scan, O(width * height). Ties keep the first found (top-most,
    /// then left-most). Returns nil for an empty mask or a size mismatch.
    static func find(mask: [Bool], width: Int, height: Int) -> Rect? {
        guard width > 0, height > 0, mask.count == width * height else { return nil }
        var heights = [Int](repeating: 0, count: width)
        var best: Rect?
        for y in 0..<height {
            for x in 0..<width { heights[x] = mask[y * width + x] ? heights[x] + 1 : 0 }
            var stack: [Int] = [] // indices with increasing heights
            for x in 0...width {
                let current = x == width ? 0 : heights[x]
                while let top = stack.last, heights[top] >= current {
                    stack.removeLast()
                    let h = heights[top]
                    let left = (stack.last ?? -1) + 1
                    let w = x - left
                    if h > 0, w * h > (best?.area ?? 0) { best = Rect(x: left, y: y - h + 1, width: w, height: h) }
                }
                stack.append(x)
            }
        }
        return best
    }
}
