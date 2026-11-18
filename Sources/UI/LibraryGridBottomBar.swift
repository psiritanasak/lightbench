import SwiftUI

/// The Library grid's bottom bar: the status line on the left (scan progress, or why a search shows nothing), then Sort, the two layout
/// buttons and the thumbnail-size slider. Sort, layout and size all control HOW photos are shown (not WHICH), so they sit together.
/// The bar is exactly `Theme.Metrics.barHeight` tall whatever the status says, so the grid never jumps when a message appears.
struct LibraryGridBottomBar: View {
    @ObservedObject var catalog: CatalogModel
    @Binding var gridLayout: String
    @Binding var thumbnailSize: Double
    let sizeRange: ClosedRange<Double>

    private var isJustified: Bool { gridLayout == "justified" }

    private var status: (text: String, isWarning: Bool)? {
        LibraryFilterBar.hint(forSearch: catalog.searchText, scanStatus: catalog.metadataScanStatusText,
                              hasAnyMetadata: !catalog.metadataByPhotoID.isEmpty,
                              savedQuery: catalog.selectedSmartCollectionQuery)
    }

    var body: some View {
        HStack(spacing: 10) {
            statusSlot
            Image(systemName: "arrow.up.arrow.down")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .accessibilityHidden(true)
            Picker("Sort", selection: $catalog.sortOption) {
                ForEach(LibrarySortOption.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .labelsHidden()
            .accessibilityLabel("Sort")
            .help("Sort order")
            .fixedSize()
            // Layout: square cells (default) or justified rows (each photo at its own aspect ratio). Flat buttons, the grey `isOn` chip marks the choice.
            Button { gridLayout = "square" } label: { Image(systemName: "square.grid.2x2") }
                .buttonStyle(FlatButtonStyle(isOn: !isJustified))
                .help("Square grid")
                .accessibilityLabel("Square grid")
                .accessibilityAddTraits(!isJustified ? [.isSelected] : [])
            Button { gridLayout = "justified" } label: { Image(systemName: "rectangle.grid.1x2") }
                .buttonStyle(FlatButtonStyle(isOn: isJustified))
                .help("Justified rows: every photo keeps its shape")
                .accessibilityLabel("Justified rows")
                .accessibilityAddTraits(isJustified ? [.isSelected] : [])
            Image(systemName: "photo")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .accessibilityHidden(true)
            // (Moved from `LibraryGridView.swift`; "the cell-width fix" and "the icon row's own `HStack` doc comment" are in that file.)
            // Floor raised from 100 to 120 alongside the cell-width fix
            // below (live-caught overlap bug) — this comment went through
            // two reviewer-caught inaccuracies before landing on real,
            // measured numbers, see the icon row's own `HStack` doc
            // comment for the full history: at the icon row's ORIGINAL
            // font sizes/spacing, 120 was measured as 9pt BELOW the
            // row's true minimum (actively insufficient, not "zero-slack"
            // as an earlier version of this exact comment claimed); the
            // `.caption2` icon shrink alone still left 120 above the
            // minimum; only tightening the row's own spacing (6→4) is
            // what actually brought the row under 120 with real margin.
            ThinSlider(
                value: $thumbnailSize,
                range: sizeRange,
                valueDescription: { "\(Int($0.rounded())) points" }
            )
                .frame(width: 100)
                .accessibilityLabel(isJustified ? "Row height" : "Thumbnail size")
            Image(systemName: "photo")
                .font(.body)
                .foregroundStyle(Theme.textSecondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal)
        .frame(height: Theme.Metrics.barHeight)
    }

    /// Left side: the status text, or an empty filler with the same layout. The controls win when space is short.
    @ViewBuilder private var statusSlot: some View {
        if let status {
            Text(status.text)
                .font(.caption)
                .foregroundStyle(status.isWarning ? Theme.warning : Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(-1)
                .accessibilityLabel(status.text)
        } else {
            Color.clear
                .frame(maxWidth: .infinity)
                .layoutPriority(-1)
                .accessibilityHidden(true)
        }
    }
}
