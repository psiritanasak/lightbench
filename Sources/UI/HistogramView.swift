import SwiftUI

/// The bare `Canvas` drawing of a Levels-style luminance + per-channel RGB
/// histogram — split out of `HistogramView` for Curves v2 slice 2B, so
/// `ToneCurveEditorView` can layer its own curve stroke in a SEPARATE
/// `Canvas` behind the histogram rather than sharing one.
///
/// THAT SPLIT IS STRUCTURAL, NOT STYLISTIC. This view sets
/// `context.blendMode = .plusLighter` for its RGB pass and never restores
/// it afterward — safe here only because nothing else is drawn in this
/// `Canvas` after that point. If a future caller ever appended more drawing
/// to THIS SAME `Canvas` closure after the RGB pass, it would inherit
/// additive blending with no visual warning (the "sticky blend mode" trap).
/// Keeping the curve stroke in its own `Canvas` in `ToneCurveEditorView`
/// makes that bug UNREPRESENTABLE rather than merely avoided by discipline.
struct HistogramBars: View {
    let data: HistogramData
    /// Which channel series to layer on top of the always-drawn luminance
    /// base (Curves v2 slice 3 — replaces this view's old `showChannels:
    /// Bool`, which could only mean "all three RGB channels or none"; the
    /// tone curve editor needs a THIRD option, exactly one channel, while
    /// that channel's curve is being edited). See `HistogramChannelOverlay`
    /// for why it has no `.none` case.
    var channels: HistogramChannelOverlay = .allChannels

    var body: some View {
        Canvas { context, size in
            guard !data.luminance.isEmpty else { return }

            let barWidth = size.width / CGFloat(data.luminance.count)

            // Luminance first, as the base layer — normal (non-additive)
            // compositing, same gray fill this view has always used.
            draw(data.luminance, into: context, size: size, barWidth: barWidth, color: .secondary)

            guard channels != .luminanceOnly else { return }

            // Additive blending, so overlapping channels visually mix (e.g.
            // red+green reads as yellow) — matches Lightroom/Photos' RGB
            // histogram convention, confirmed with the user over a
            // non-mixing "4 separate strips" alternative. `.plusLighter` is
            // the Canvas compositor's additive operator — real color mixing
            // via the compositor itself, not a manually-computed blend.
            // Still true with only ONE channel drawn (`.red`/`.green`/
            // `.blue` below): additive-over-the-gray-luminance-base is what
            // makes a single channel's own bars legible against it, not
            // just what makes multiple channels mix. See this type's own
            // doc comment above: this blend mode is never reset, so it is
            // only safe as the LAST thing drawn in its own `Canvas`.
            context.blendMode = .plusLighter
            switch channels {
            case .luminanceOnly:
                break
            case .allChannels:
                draw(data.red, into: context, size: size, barWidth: barWidth, color: .red.opacity(0.65))
                draw(data.green, into: context, size: size, barWidth: barWidth, color: .green.opacity(0.65))
                draw(data.blue, into: context, size: size, barWidth: barWidth, color: .blue.opacity(0.65))
            case .red:
                draw(data.red, into: context, size: size, barWidth: barWidth, color: .red.opacity(0.65))
            case .green:
                draw(data.green, into: context, size: size, barWidth: barWidth, color: .green.opacity(0.65))
            case .blue:
                draw(data.blue, into: context, size: size, barWidth: barWidth, color: .blue.opacity(0.65))
            }
        }
    }

    private func draw(_ values: [Float], into context: GraphicsContext, size: CGSize, barWidth: CGFloat, color: Color) {
        for (index, value) in values.enumerated() {
            let barHeight = size.height * CGFloat(value)
            let rect = CGRect(
                x: CGFloat(index) * barWidth,
                y: size.height - barHeight,
                width: barWidth,
                height: barHeight
            )
            context.fill(Path(rect), with: .color(color))
        }
    }
}

/// A compact bar-chart rendering of a Levels-style luminance + per-channel
/// RGB histogram (see `HistogramComputer`/`HistogramData`). Purely
/// presentational — takes already-computed, normalized (0...1 per channel)
/// bin values and draws them; does no image processing itself. A thin
/// wrapper around `HistogramBars` (see that type's own doc comment for why
/// the drawing itself lives there) that adds this view's chrome — zero
/// call-site changes for any existing caller.
struct HistogramView: View {
    let data: HistogramData
    var channels: HistogramChannelOverlay = .allChannels

    var body: some View {
        HistogramBars(data: data, channels: channels)
            .frame(height: 60)
            .background(Color.black.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            // D6 (IMPROVEMENTS.md): purely presentational and non-interactive —
            // a per-bin histogram readout would be meaningless spoken aloud, so
            // this is explicitly, deliberately hidden rather than left silently
            // present as an undescribed `Canvas` element in the AX tree.
            .accessibilityHidden(true)
    }
}
