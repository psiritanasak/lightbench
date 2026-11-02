import SwiftUI

/// Colour ramps for `ThinSlider`'s optional gradient track (D58-2): the track itself says what the slider does (cool to warm,
/// green to magenta, the hue wheel, grey to colour). Pure data, so the stop counts, ends and directions are unit-tested.
/// Presentation only: the ramps are indications, not colour-managed renderings of what the pipeline will do.
enum SliderTrackPalette {
    /// Selective Color's Hue slider moves a band's hue by `value * kHue` degrees; `kHue` in `SelectiveColor.cikernel`.
    /// A test pins this against the kernel source.
    static let selectiveHueSpanDegrees: Double = 30

    private static func hsb(_ degrees: Double, saturation: Double = 1, brightness: Double = 1) -> Color {
        var h = degrees.truncatingRemainder(dividingBy: 360)
        if h < 0 { h += 360 }
        return Color(hue: h / 360, saturation: saturation, brightness: brightness)
    }

    private static let grey = Color(white: 0.5)

    // MARK: White balance

    /// Cool (blue) on the left, neutral, warm (amber) on the right: a higher Temperature value renders warmer (measured).
    static let temperature: [Color] = [
        Color(red: 0.25, green: 0.52, blue: 1.0), grey, Color(red: 1.0, green: 0.62, blue: 0.12)
    ]

    /// Green on the left, magenta on the right (measured: tint -100 renders green, +100 magenta).
    static let tint: [Color] = [
        Color(red: 0.2, green: 0.8, blue: 0.3), grey, Color(red: 0.9, green: 0.25, blue: 0.8)
    ]

    // MARK: Colour

    /// The hue wheel as the Hue slider (-180...180 degrees) turns it: the colour at stop `a` is what red becomes at angle `a`
    /// (measured with a one-pixel pipeline probe: +60 moves red towards yellow, -60 towards magenta). Seven stops, 60 degrees
    /// apart, red in the middle, cyan at both ends.
    static let hue: [Color] = stride(from: -180.0, through: 180.0, by: 60.0).map { hsb($0) }

    /// A rainbow whose saturation rises steadily from 0 (grey, left) through 0.5 at the middle (identity) to 1 (right), so the
    /// track shows the saturation level the slider would give. Seven stops, hue 60 degrees apart; brightness rises with the
    /// saturation so the left end is the same mid grey as the other ramps.
    static let saturation: [Color] = (0...6).map { i in
        let t = Double(i) / 6
        return hsb(Double(i) * 60, saturation: t, brightness: 0.5 + 0.5 * t)
    }

    /// Same ramp as Saturation (Vibrance protects already-vivid colours, but the track shows the direction, not the curve).
    static let vibrance: [Color] = saturation

    // MARK: Selective Color

    private static func bandCentre(_ band: SelectiveColorBand) -> Double {
        let index = SelectiveColorBand.allCases.firstIndex(of: band) ?? 0
        return SelectiveColorBandWeights.centers[index]
    }

    /// The band's hue shifted by -30...+30 degrees (the most the slider can move it).
    static func selectiveHue(_ band: SelectiveColorBand) -> [Color] {
        let centre = bandCentre(band)
        return [
            hsb(centre - selectiveHueSpanDegrees), hsb(centre), hsb(centre + selectiveHueSpanDegrees)
        ]
    }

    /// Grey on the left, the band's own swatch colour on the right.
    static func selectiveSaturation(_ band: SelectiveColorBand) -> [Color] {
        [grey, band.swatchColor]
    }

    /// Dark, the band colour, light.
    static func selectiveLuminance(_ band: SelectiveColorBand) -> [Color] {
        let centre = bandCentre(band)
        return [hsb(centre, saturation: 1, brightness: 0.25), hsb(centre), hsb(centre, saturation: 0.45, brightness: 1)]
    }

    // MARK: Local adjustments (mask panel)

    static let maskSaturation: [Color] = saturation
    static let maskTemperature: [Color] = temperature
    static let maskTint: [Color] = tint
}
