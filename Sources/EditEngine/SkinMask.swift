import Foundation

/// The skin-colour test behind Styles v3 "Protect skin". Pure arithmetic on 0...255 sRGB components — no Core Image, no Vision.
///
/// The window is the YCbCr box the 2026-10-07 spike used (Y > 40, Cb 77...127, Cr 133...173; full-range BT.601). On its own it
/// is NOT a skin detector: it also contains sand, rock and soil (on the spike's real non-person photos — desert, dusk, red rock, fur/soil — it marked 18-52% of pixels),
/// which is why `SkinMaskBuilder` only ever intersects it with a person-segmentation mask. Numbers and the photos behind them:
/// docs/ROADMAP_HISTORY.md, "Styles v3 skin-protection spike".
enum SkinWindow {
    static func contains(_ r: Double, _ g: Double, _ b: Double) -> Bool {
        guard r.isFinite, g.isFinite, b.isFinite else { return false }
        let y = 0.299 * r + 0.587 * g + 0.114 * b
        let cb = 128 - 0.168736 * r - 0.331264 * g + 0.5 * b
        let cr = 128 + 0.5 * r - 0.418688 * g - 0.081312 * b
        return y > 40 && cb >= 77 && cb <= 127 && cr >= 133 && cr <= 173
    }
}

/// Combines a person-segmentation raster with the colour window into the skin raster that is persisted.
enum SkinMaskBuilder {
    /// Person coverage at or below this counts as "no person". It is a CONVENTION chosen above a measured noise level, not a
    /// measured optimum: Vision's raw 2016x1512 mask on the spike's person-free sand-gradient-plus-rock image (2026-10-07) had a
    /// max of 6 and about 20-23 non-zero pixels (the count varies with input size; the floor applies to the resized mask, whose max is lower still), which without a floor would be persisted as skin wherever the colour window matches.
    static let minimumPersonCoverage: UInt8 = 128

    /// `person`: 8-bit coverage, `width * height` values, row-major. `rgba`: STRAIGHT (unpremultiplied) 8-bit sRGB, 4 bytes per
    /// pixel, same size — premultiplied colours would shift across the window's bounds.
    /// A pixel is 0 where its colour is outside `SkinWindow` or its person coverage is at most the floor; elsewhere the coverage is
    /// rescaled so the floor maps to 0 and 255 stays 255 (`(p - floor) * 255 / (255 - floor)`), keeping the person mask's soft edge
    /// continuous instead of stepping from 0 to 128 at the boundary. Returns nil when the sizes do not match, rather than guessing
    /// an alignment.
    static func combine(person: [UInt8], rgba: [UInt8], width: Int, height: Int) -> [UInt8]? {
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0, !overflow, person.count == pixels, rgba.count == pixels * 4 else { return nil }
        var out = [UInt8](repeating: 0, count: person.count)
        for i in 0..<person.count where person[i] > minimumPersonCoverage {
            let p = i * 4
            if SkinWindow.contains(Double(rgba[p]), Double(rgba[p + 1]), Double(rgba[p + 2])) {
                out[i] = UInt8((Int(person[i]) - Int(minimumPersonCoverage)) * 255 / (255 - Int(minimumPersonCoverage)))
            }
        }
        return out
    }
}
