import Foundation

/// Swift mirror of the raised-cosine band weights in `SelectiveColor.cikernel` and `GrayMix.cikernel`, for the Targeted
/// adjustment tool: it must know which of the 8 hue bands the pixel under the cursor belongs to, and by how much, exactly as the
/// kernel will weigh it. `SelectiveColorBandWeightsTests` renders the real kernels and checks these numbers against them.
///
/// Band order everywhere: Red, Orange, Yellow, Green, Aqua, Blue, Purple, Magenta (the kernels' `centersA` then `centersB`).
enum SelectiveColorBandWeights {
    /// Band centres in degrees, kernel order.
    static let centers: [Double] = [0, 30, 60, 120, 180, 240, 280, 320]

    /// Window half-width (degrees) Selective Color uses at `range` (0...1): the kernel's `Wmin + range * (Wmax - Wmin)`.
    static func selectiveWindow(range: Double) -> Double { 20 + range * 60 }

    /// GrayMix's fixed window (degrees).
    static let grayMixWindow: Double = 50

    /// The kernel's `bandWeights` for one hue, BEFORE the saturation weighting. A hue outside a band's window gets exactly 0.
    static func rawWeights(hue: Double, window: Double) -> [Double] {
        centers.map { center in
            let d = abs(hue - center)
            let dc = min(d, 360 - d)
            guard dc <= window else { return 0 }
            return 0.5 * (1 + cos(Double.pi * dc / window))
        }
    }

    /// Selective Color's per-band weights for a pixel: raised cosine times the pixel's OWN (unclamped) HSL saturation, as the
    /// kernel computes them.
    static func selectiveColorWeights(hue: Double, saturation: Double, range: Double) -> [Double] {
        rawWeights(hue: hue, window: selectiveWindow(range: range)).map { $0 * saturation }
    }

    /// B&W Mix's per-band weights: window 50, saturation CLAMPED to 0...1 first (the kernel's own guard for wide-gamut shadows).
    static func grayMixWeights(hue: Double, saturation: Double) -> [Double] {
        let sat = min(max(saturation, 0), 1)
        return rawWeights(hue: hue, window: grayMixWindow).map { $0 * sat }
    }

    // MARK: - Field access

    static func selectiveColorKeyPaths(for property: SelectiveColorProperty) -> [WritableKeyPath<EditState, Double>] {
        switch property {
        case .hue:
            return [\.redHue, \.orangeHue, \.yellowHue, \.greenHue, \.aquaHue, \.blueHue, \.purpleHue, \.magentaHue]
        case .saturation:
            return [\.redSaturation, \.orangeSaturation, \.yellowSaturation, \.greenSaturation,
                    \.aquaSaturation, \.blueSaturation, \.purpleSaturation, \.magentaSaturation]
        case .luminance:
            return [\.redLuminance, \.orangeLuminance, \.yellowLuminance, \.greenLuminance,
                    \.aquaLuminance, \.blueLuminance, \.purpleLuminance, \.magentaLuminance]
        }
    }

    static var grayMixKeyPaths: [WritableKeyPath<EditState, Double>] { [
        \.grayMixRed, \.grayMixOrange, \.grayMixYellow, \.grayMixGreen,
        \.grayMixAqua, \.grayMixBlue, \.grayMixPurple, \.grayMixMagenta
    ] }
}
