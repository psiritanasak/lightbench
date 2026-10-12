import Foundation

/// Pure maths for the Depth Range mask (docs/ROADMAP_HISTORY.md "Depth Range spike"). A depth RASTER stores per-pixel NEARNESS as 8-bit gray
/// (0 = farthest, 255 = nearest, normalised per image by `DepthNormalizer`); the mask selects pixels whose nearness lies in a window, with soft edges.
/// `EditPipeline.depthMaskImages` renders the SAME weights on the GPU with `DepthWindow.cikernel`; this file is the single source of truth the tests
/// (and that kernel's tests) check against.
enum DepthRangeSelection {
    /// Width of the soft edge, in nearness units, at `feather == 1`.
    static let maxFeatherSpan: Float = 0.25
    /// The window never collapses below this width (a hairline window would select almost nothing and flicker with raster noise).
    static let minimumWidth: Float = 0.01

    struct Window: Equatable {
        /// Nearness range that is fully selected: `low...high`.
        let low: Float
        let high: Float
        /// Soft-edge width below `low` and above `high`; 0 = hard edges.
        let edge: Float
    }

    /// The window for the user's parameters. `farLimit` is the FARTHEST nearness included, `nearLimit` the NEAREST (so a fresh mask `0.5...1`
    /// selects the nearer half). Non-finite input falls back to the defaults, values are clamped to 0...1, reversed limits are swapped, and the
    /// window is widened to `minimumWidth` around its centre (staying inside 0...1).
    static func window(farLimit: Double, nearLimit: Double, feather: Double) -> Window {
        func clean(_ v: Double, _ fallback: Float) -> Float { v.isFinite ? Float(min(max(v, 0), 1)) : fallback }
        var low = clean(farLimit, 0.5), high = clean(nearLimit, 1)
        if low > high { swap(&low, &high) }
        if high - low < minimumWidth {
            let centre = (low + high) / 2
            low = min(max(centre - minimumWidth / 2, 0), 1 - minimumWidth)
            high = low + minimumWidth
        }
        return Window(low: low, high: high, edge: clean(feather, 0) * maxFeatherSpan)
    }

    /// Selection weight, 0...1, of a pixel of the given nearness: 1 inside the window, a smoothstep ramp of width `edge` outside it, 0 beyond.
    static func weight(nearness: Float, window w: Window) -> Float {
        guard nearness.isFinite else { return 0 }
        let n = min(max(nearness, 0), 1)
        if n >= w.low && n <= w.high { return 1 }
        guard w.edge > 0 else { return 0 }
        let distance = n < w.low ? w.low - n : n - w.high
        let t = 1 - distance / w.edge
        guard t > 0 else { return 0 }
        return t * t * (3 - 2 * t)
    }

    /// 256-entry weight table for 8-bit nearness (index = raster byte); what a lookup-based renderer would use. Index `i` means nearness `i / 255`.
    static func table(for window: Window) -> [Float] { (0...255).map { weight(nearness: Float($0) / 255, window: window) } }
}

/// Turns whatever scale a depth source delivers — an iPhone's disparity (ranges seen: 0.49...0.57, 0...0.16, 0.0067...2.37) or a monocular model's
/// relative inverse depth — into the 8-bit nearness raster the mask stores. Larger input = NEARER (disparity and inverse depth both are).
enum DepthNormalizer {
    struct Result: Equatable {
        /// Row-major, row 0 = top, 0 = farthest ... 255 = nearest.
        let bytes: [UInt8]
        /// The input values that mapped to 0 and 255 (the 2nd and 98th percentiles), for diagnostics.
        let low: Float
        let high: Float
    }

    /// Fraction of the values clipped at each end so a few stray pixels (specular noise, a hole filled with 0) do not squash the useful range.
    static let clip: Double = 0.02
    /// A map whose clipped range is narrower than this FRACTION of its typical magnitude carries no usable depth (an almost flat map would be
    /// stretched into pure noise).
    static let minimumRelativeSpread: Float = 0.005

    /// nil when there are no finite values or the map is effectively flat.
    static func normalize(_ values: [Float]) -> Result? {
        let finite = values.filter { $0.isFinite }
        guard !finite.isEmpty else { return nil }
        let sorted = finite.sorted()
        let last = Double(sorted.count - 1)
        let low = sorted[Int((last * clip).rounded())], high = sorted[Int((last * (1 - clip)).rounded())]
        let magnitude = max(abs(sorted[sorted.count / 2]), abs(low), abs(high), 1e-6)
        guard high - low > minimumRelativeSpread * magnitude, high - low > 1e-6 else { return nil }
        let span = high - low
        let bytes = values.map { v -> UInt8 in
            // A hole (NaN / +-inf: a failed or saturated reading) becomes byte 0, "farthest": it is never selected as FOREGROUND, but an 8-bit raster has
            // no spare value, so a window that reaches down to 0 ("select the background"), or Invert on a near window, DOES select the holes. +inf
            // (a disparity reading of "very near") is lumped in with them.
            guard v.isFinite else { return 0 }
            return UInt8((min(max((v - low) / span, 0), 1) * 255).rounded())
        }
        return Result(bytes: bytes, low: low, high: high)
    }
}

/// Provenance of a depth raster, stored on the mask as a plain string so it round-trips through the sidecar and survives future models.
enum DepthSourceTag {
    static let embedded = "embedded"
    /// `model:<model id>:<revision>`, e.g. `model:depth-anything-v2-small-f16:cfef6f6f2a70`.
    static func model(id: String, revision: String) -> String { "model:\(id):\(revision)" }
    static func isEmbedded(_ tag: String) -> Bool { tag == embedded }
    static func isModel(_ tag: String) -> Bool { tag.hasPrefix("model:") }
    /// Short text for the UI.
    static func displayName(_ tag: String) -> String {
        if isEmbedded(tag) { return "iPhone depth" }
        if isModel(tag) { return "Depth model" }
        return tag.isEmpty ? "None" : tag
    }
}
