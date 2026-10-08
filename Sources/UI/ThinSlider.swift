import SwiftUI

/// Pure value↔pixel mapping for `ThinSlider`, kept SwiftUI-independent
/// (same pattern as `CropAspectMath`) so the one place an off-by-a-
/// thumb-radius bug could hide is unit-tested, not eyeballed.
enum ThinSliderGeometry {
    static func fraction(of value: Double, in range: ClosedRange<Double>) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return ((value - range.lowerBound) / span).clamped(to: 0...1)
    }

    static func value(atFraction fraction: Double, in range: ClosedRange<Double>) -> Double {
        let f = fraction.clamped(to: 0...1)
        return range.lowerBound + f * (range.upperBound - range.lowerBound)
    }

    /// The thumb's CENTER x for a given fraction, inset by half the
    /// thumb's own horizontal extent so it never overhangs either end of
    /// the track.
    static func thumbCenterX(fraction: Double, trackWidth: Double, thumbWidth: Double) -> Double {
        let usableSpan = max(trackWidth - thumbWidth, 0)
        return thumbWidth / 2 + fraction.clamped(to: 0...1) * usableSpan
    }

    /// Inverse of `thumbCenterX`: a drag x (in track-local coordinates)
    /// back to a clamped 0...1 fraction.
    static func fraction(atX x: Double, trackWidth: Double, thumbWidth: Double) -> Double {
        let usableSpan = max(trackWidth - thumbWidth, 0)
        guard usableSpan > 0 else { return 0 }
        return ((x - thumbWidth / 2) / usableSpan).clamped(to: 0...1)
    }

    /// The step size for one VoiceOver increment/decrement — 1/20th of the
    /// range. Shared by `incremented`/`decremented` below purely so the
    /// `/20` constant isn't duplicated between them.
    private static func step(in range: ClosedRange<Double>) -> Double {
        (range.upperBound - range.lowerBound) / 20
    }

    /// D6 (IMPROVEMENTS.md): one VoiceOver increment, clamped to `range` —
    /// matches what `ThinSlider`'s `accessibilityAdjustableAction` used
    /// inline before this was extracted so it could be unit-tested and
    /// reused by `CompareDividerOverlay`'s own adjustable action.
    static func incremented(_ value: Double, in range: ClosedRange<Double>) -> Double {
        Swift.min(value + step(in: range), range.upperBound)
    }

    /// One VoiceOver decrement, clamped to `range`.
    static func decremented(_ value: Double, in range: ClosedRange<Double>) -> Double {
        Swift.max(value - step(in: range), range.lowerBound)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

/// A thin flat-track slider matching Apple Photos' Adjust panel look —
/// replaces the native `Slider`'s glossy 3D knob, which can't be
/// restyled to match. Drop-in for `Slider(value:in:)`: same
/// `Binding<Double>`/`ClosedRange<Double>` API, same row height.
struct ThinSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// D6 (IMPROVEMENTS.md): the announced `accessibilityValue` defaulted
    /// to a bare 0-100% of `range`, which reviewer-caught mismatches what's
    /// actually on screen for most rows — a Temperature row shows "6500K"
    /// but VoiceOver said "62%"; an EV row shows "0.00 EV" but VoiceOver
    /// said "50%". Callers that already have a real formatted string (e.g.
    /// `EditSliderRow`'s own `format` closure) pass it here instead. `nil`
    /// keeps the previous percent behavior — additive, no call-site changes
    /// required elsewhere.
    var valueDescription: ((Double) -> String)? = nil

    /// The filled part of the track is a dimmer white than the thumb, so the thumb is the one bright mark.
    static let filledTrackOpacity = 0.55
    private let trackHeight: CGFloat = 4
    private let thumbWidth: CGFloat = 5
    private let thumbHeight: CGFloat = 18
    private let rowHeight: CGFloat = 22

    var body: some View {
        GeometryReader { proxy in
            let trackWidth = proxy.size.width
            let fraction = ThinSliderGeometry.fraction(of: value, in: range)
            let thumbX = ThinSliderGeometry.thumbCenterX(
                fraction: fraction, trackWidth: trackWidth, thumbWidth: thumbWidth
            )

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.15))
                    .frame(height: trackHeight)
                Capsule()
                    .fill(Color.white.opacity(Self.filledTrackOpacity))
                    .frame(width: thumbX, height: trackHeight)
                // No shadow on the thumb: flat, like the rest of the editor.
                Capsule()
                    .fill(Color.white)
                    .frame(width: thumbWidth, height: thumbHeight)
                    .offset(x: thumbX - thumbWidth / 2)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let f = ThinSliderGeometry.fraction(
                            atX: drag.location.x, trackWidth: trackWidth, thumbWidth: thumbWidth
                        )
                        value = ThinSliderGeometry.value(atFraction: f, in: range)
                    }
            )
        }
        .frame(height: rowHeight)
        .accessibilityElement()
        .accessibilityValue(Text(
            valueDescription?(value) ?? String(format: "%.0f%%", ThinSliderGeometry.fraction(of: value, in: range) * 100)
        ))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = ThinSliderGeometry.incremented(value, in: range)
            case .decrement: value = ThinSliderGeometry.decremented(value, in: range)
            @unknown default: break
            }
        }
    }
}
