import SwiftUI

/// The pinned header above the Edit tab's sidebar scroll: the live histogram plus a one-line EXIF strip, so the histogram stays visible while
/// the sliders scroll. It is the only histogram; it is the Levels input (`ImageDocumentModel.recomputeHistogram` holds the Levels sliders at
/// identity), i.e. the edit as it stands BEFORE Levels. A click on it cycles the mode (Luminance / RGB). Height budget about 100-110 pt.
struct EditorHistogramHeader: View {
    let data: HistogramData
    @Binding var mode: HistogramDisplayMode
    let cameraInfo: PhotoMetadataReader.Fields?

    /// The header belongs to the Edit tab only.
    static func isShown(on tab: EditorTab) -> Bool { tab == .adjust }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.px3) {
            Button { mode = mode.next } label: {
                HistogramView(data: data, channels: mode.channels)
                    .overlay(alignment: .topTrailing) {
                        Text(mode.rawValue).font(.caption2).foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, Theme.Space.xs).padding(.vertical, Theme.Space.px1)
                            .background(Theme.panel.opacity(0.7), in: RoundedRectangle(cornerRadius: Theme.Radius.px3))
                            .padding(Theme.Space.xs)
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Histogram of the edited photo, before Levels. Click to switch between Luminance and RGB.")
            .accessibilityLabel("Histogram")
            .accessibilityValue(mode.rawValue)
            .accessibilityHint("Switches between Luminance and RGB")
            // The text lines are read as ONE VoiceOver element; the histogram itself stays hidden (see `HistogramView`).
            VStack(alignment: .leading, spacing: Theme.Space.px3) {
                if let exposure = cameraInfo.flatMap(ExifStripText.exposureLine) {
                    Text(exposure)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                if let camera = cameraInfo.flatMap(ExifStripText.cameraLine) {
                    Text(camera)
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .accessibilityElement(children: .combine)
        }
        .padding(.horizontal)
        .padding(.top, Theme.Space.s)
        .padding(.bottom, Theme.Space.px6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
