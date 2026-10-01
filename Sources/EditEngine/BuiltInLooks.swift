import Foundation

/// The app's own creative looks, generated from color math (no third-party LUT assets). Every look is a
/// per-pixel function in the DISPLAY-REFERRED sRGB-gamma domain — the domain `EditPipeline` applies looks
/// in — sampled once into a 33^3 `CubeLUT`. Strengths are deliberately moderate: a look is a starting
/// point that the user's own sliders then refine.
enum BuiltInLooks {
    struct Look: Sendable {
        /// `builtin:<slug>` — stable forever, because it is stored in sidecars. The look's MATH, however, lives in
        /// the renderer and is not pinned per photo: retuning a look later changes how existing edits that use its id
        /// render (same situation as `kMaxTransformAspectStretch` — not a regression when it happens).
        let id: String
        let name: String
        let transform: @Sendable (SIMD3<Float>) -> SIMD3<Float>
    }

    static let cubeSize = 33

    // MARK: - Building blocks

    /// Rec.709 weights applied to GAMMA-ENCODED values: luma, not true luminance — a deliberate departure from
    /// the project's linear-light rule, fine for creative looks.
    static func luma(_ c: SIMD3<Float>) -> Float { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }

    /// 1 = unchanged, 0 = grayscale, >1 = more saturated (about the pixel's own luma).
    static func saturate(_ c: SIMD3<Float>, _ amount: Float) -> SIMD3<Float> {
        let l = luma(c)
        return fitGamut(SIMD3(repeating: l) + (c - SIMD3(repeating: l)) * amount)
    }

    /// Saturation BOOST that backs off as a color is already saturated (vibrance-style): a flat boost drives
    /// the most colorful pixels past the gamut, where they all collapse onto the same output. Amounts <= 1 are
    /// plain `saturate`.
    static func vibrantSaturate(_ c: SIMD3<Float>, _ amount: Float) -> SIMD3<Float> {
        guard amount > 1 else { return saturate(c, amount) }
        let hi = max(c.x, max(c.y, c.z)), lo = min(c.x, min(c.y, c.z))
        let chroma = hi > 0 ? min(max((hi - lo) / hi, 0), 1) : 0
        return saturate(c, 1 + (amount - 1) * (1 - chroma) * (1 - chroma))
    }

    /// Pulls an out-of-gamut color back toward its own luma (hue and luma preserved) instead of letting the
    /// final per-channel clamp flatten it: a saturation boost on a strong color otherwise pushes one channel
    /// past 1 and every brighter input collapses onto the same output (measured by the single-channel
    /// sweep test).
    static func fitGamut(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let l = min(max(luma(c), 0), 1)
        var t: Float = 1
        let hi = max(c.x, max(c.y, c.z))
        if hi > 1, hi > l { t = min(t, (1 - l) / (hi - l)) }
        let lo = min(c.x, min(c.y, c.z))
        if lo < 0, l > lo { t = min(t, l / (l - lo)) }
        return SIMD3(repeating: l) + (c - SIMD3(repeating: l)) * t
    }

    /// Contrast about the midpoint using a smoothstep blend: `k` > 0 steepens, < 0 flattens, 0 = identity.
    static func sCurve(_ x: Float, _ k: Float) -> Float {
        let t = min(max(x, 0), 1)
        let s = t * t * (3 - 2 * t)
        return t + (s - t) * k
    }

    static func sCurve(_ c: SIMD3<Float>, _ k: Float) -> SIMD3<Float> {
        SIMD3(sCurve(c.x, k), sCurve(c.y, k), sCurve(c.z, k))
    }

    /// `out = lift + (1 - lift) * gain * in^(1/gamma)`: raises blacks by `lift`, per-channel `gain`.
    static func liftGammaGain(_ c: SIMD3<Float>, lift: Float, gamma: Float, gain: SIMD3<Float>) -> SIMD3<Float> {
        let g = 1 / max(gamma, 0.01)
        let p = SIMD3(pow(max(c.x, 0), g), pow(max(c.y, 0), g), pow(max(c.z, 0), g))
        return SIMD3(repeating: lift) + (1 - lift) * gain * p
    }

    /// Adds `shadow` tint weighted toward darks and `highlight` tint weighted toward lights.
    static func splitTone(_ c: SIMD3<Float>, shadow: SIMD3<Float>, highlight: SIMD3<Float>) -> SIMD3<Float> {
        let l = luma(c)
        let wh = l * l
        let ws = (1 - l) * (1 - l)
        return c + shadow * ws + highlight * wh
    }

    // MARK: - The looks

    static let all: [Look] = [
        Look(id: "builtin:warm-film", name: "Warm Film") { c in
            // Gains are normalised so the strongest channel is exactly 1: a gain above 1 would hard-clip
            // that channel's highlights flat (0.943...1 became 1.0 with 1.06), losing skin-tone detail.
            var o = liftGammaGain(c, lift: 0.02, gamma: 1.0, gain: SIMD3(1.0, 0.943, 0.858))
            o = sCurve(o, 0.18)
            return saturate(o, 0.95)
        },
        Look(id: "builtin:cool-fade", name: "Cool Fade") { c in
            let o = liftGammaGain(c, lift: 0.045, gamma: 1.0, gain: SIMD3(0.888, 0.935, 1.0))
            return saturate(sCurve(o, 0.05), 0.85)
        },
        Look(id: "builtin:teal-orange", name: "Teal & Orange") { c in
            // Highlights go orange by REMOVING green/blue (adding red would clip it near white).
            var o = splitTone(c, shadow: SIMD3(-0.03, 0.05, 0.08), highlight: SIMD3(0.0, -0.05, -0.14))
            o = sCurve(o, 0.22)
            return vibrantSaturate(o, 1.06)
        },
        Look(id: "builtin:bleach-bypass", name: "Bleach Bypass") { c in
            saturate(sCurve(c, 0.4), 0.5)
        },
        Look(id: "builtin:faded-matte", name: "Faded Matte") { c in
            saturate(liftGammaGain(c, lift: 0.07, gamma: 1.0, gain: SIMD3(0.97, 0.97, 0.97)), 0.9)
        },
        Look(id: "builtin:noir", name: "Noir") { c in
            SIMD3(repeating: sCurve(luma(c), 0.55))
        },
        Look(id: "builtin:sepia", name: "Sepia") { c in
            let l = luma(c)
            return SIMD3(l, l * 0.861, l * 0.648) // red at 1.0 so white stays unclipped
        },
        Look(id: "builtin:cross-process", name: "Cross Process") { c in
            let r = sCurve(c.x, 0.55)
            let g = sCurve(c.y, 0.25)
            let b = 0.08 + 0.84 * sCurve(c.z, 0.1)
            return vibrantSaturate(SIMD3(r, g, b), 1.12)
        },
        Look(id: "builtin:vivid", name: "Vivid") { c in
            vibrantSaturate(sCurve(c, 0.15), 1.35)
        },
        Look(id: "builtin:soft-portrait", name: "Soft Portrait") { c in
            var o = liftGammaGain(c, lift: 0.03, gamma: 1.08, gain: SIMD3(1.0, 0.971, 0.942))
            o = sCurve(o, -0.1)
            return saturate(o, 0.92)
        }
    ]

    static func look(id: String) -> Look? { all.first { $0.id == id } }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: CubeLUT] = [:]

    /// The look's cube, built once and cached (deterministic: the same code always yields the same table).
    static func cube(id: String) -> CubeLUT? {
        lock.lock()
        if let hit = cache[id] { lock.unlock(); return hit }
        lock.unlock()
        guard let look = look(id: id), let cube = CubeLUT.build(size: cubeSize, title: look.name, look.transform) else { return nil }
        lock.lock()
        cache[id] = cube
        lock.unlock()
        return cube
    }
}
