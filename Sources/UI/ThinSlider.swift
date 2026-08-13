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
                    .fill(Color.white)
                    .frame(width: thumbX, height: trackHeight)
                Capsule()
                    .fill(Color.white)
                    .frame(width: thumbWidth, height: thumbHeight)
                    .shadow(color: .black.opacity(0.4), radius: 1, y: 0.5)
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
        .accessibilityValue(Text(String(format: "%.0f%%", ThinSliderGeometry.fraction(of: value, in: range) * 100)))
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) / 20
            switch direction {
            case .increment: value = Swift.min(value + step, range.upperBound)
            case .decrement: value = Swift.max(value - step, range.lowerBound)
            @unknown default: break
            }
        }
    }
}
