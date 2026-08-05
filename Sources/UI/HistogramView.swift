import SwiftUI

/// A compact bar-chart rendering of a Levels-style luminance histogram
/// (see `HistogramComputer`). Purely presentational — takes already-computed,
/// normalized (0...1) bin values and draws them; does no image processing
/// itself.
struct HistogramView: View {
    let bins: [Float]

    var body: some View {
        Canvas { context, size in
            guard !bins.isEmpty else { return }

            let barWidth = size.width / CGFloat(bins.count)
            for (index, value) in bins.enumerated() {
                let barHeight = size.height * CGFloat(value)
                let rect = CGRect(
                    x: CGFloat(index) * barWidth,
                    y: size.height - barHeight,
                    width: barWidth,
                    height: barHeight
                )
                context.fill(Path(rect), with: .color(.secondary))
            }
        }
        .frame(height: 60)
        .background(Color.black.opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
