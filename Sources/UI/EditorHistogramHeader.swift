import SwiftUI

/// The pinned header above the Edit tab's sidebar scroll: the live histogram plus a one-line EXIF strip, so the histogram stays visible while
/// the sliders scroll. It shows the SAME data as the Light section's Levels histogram (`ImageDocumentModel.recomputeHistogram`, which holds
/// the not-yet-applied Levels sliders at identity), so it is a histogram of the edit as it stands BEFORE Levels. Height budget about 100-110 pt.
struct EditorHistogramHeader: View {
    let data: HistogramData
    var channels: HistogramChannelOverlay = .allChannels
    let cameraInfo: PhotoMetadataReader.Fields?

    /// The header belongs to the Edit tab only.
    static func isShown(on tab: EditorTab) -> Bool { tab == .adjust }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HistogramView(data: data, channels: channels)
                .help("Histogram of the edited photo, before Levels")
            // The text lines are read as ONE VoiceOver element; the histogram itself stays hidden (see `HistogramView`).
            VStack(alignment: .leading, spacing: 3) {
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
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
