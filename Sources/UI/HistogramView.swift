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
    /// Whether to layer the Red/Green/Blue channels on top of luminance.
    /// Luminance is always drawn — this only controls the color overlay.
    var showChannels: Bool = true

    var body: some View {
        Canvas { context, size in
            guard !data.luminance.isEmpty else { return }

            let barWidth = size.width / CGFloat(data.luminance.count)

            // Luminance first, as the base layer — normal (non-additive)
            // compositing, same gray fill this view has always used.
            draw(data.luminance, into: context, size: size, barWidth: barWidth, color: .secondary)

            guard showChannels else { return }

            // Red/Green/Blue layered on top with ADDITIVE blending, so
            // overlapping channels visually mix (e.g. red+green reads as
            // yellow) — matches Lightroom/Photos' RGB histogram convention,
            // confirmed with the user over a non-mixing "4 separate strips"
            // alternative. `.plusLighter` is the Canvas compositor's
            // additive operator — real color mixing via the compositor
            // itself, not a manually-computed blend. See this type's own
            // doc comment above: this blend mode is never reset, so it is
            // only safe as the LAST thing drawn in its own `Canvas`.
            context.blendMode = .plusLighter
            draw(data.red, into: context, size: size, barWidth: barWidth, color: .red.opacity(0.65))
            draw(data.green, into: context, size: size, barWidth: barWidth, color: .green.opacity(0.65))
            draw(data.blue, into: context, size: size, barWidth: barWidth, color: .blue.opacity(0.65))
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
    var showChannels: Bool = true

    var body: some View {
        HistogramBars(data: data, showChannels: showChannels)
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
