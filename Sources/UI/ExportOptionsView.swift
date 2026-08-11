import SwiftUI

/// The format/quality/resize options sheet for batch export — the first
/// `.sheet` in this app (a standard SwiftUI pattern, not the same class
/// of risk as `ContentView`'s earlier chained-`.alert` type-checker
/// issue, which was about one long expression, not sheets). Confirming
/// here hands control back to `ExportModel.runExport(photos:)` via
/// `onExport`, which is what actually prompts for a destination folder.
struct ExportOptionsView: View {
    @ObservedObject var exportModel: ExportModel
    @Environment(\.dismiss) private var dismiss
    let photoCount: Int
    let onExport: () -> Void

    @State private var useCustomResize = false
    @State private var maxLongEdgeText = "2048"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export \(photoCount) Photo\(photoCount == 1 ? "" : "s")")
                .font(.headline)

            Picker("Format", selection: $exportModel.settings.format) {
                ForEach(ExportFormat.allCases) { format in
                    Text(format.label).tag(format)
                }
            }

            if exportModel.settings.format == .jpeg {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Quality: \(Int(exportModel.settings.quality * 100))%")
                    Slider(value: $exportModel.settings.quality, in: 0.1...1.0)
                }
            }

            Toggle("Resize", isOn: $useCustomResize)
            if useCustomResize {
                HStack {
                    Text("Long edge:")
                    TextField("pixels", text: $maxLongEdgeText)
                        .frame(width: 80)
                    Text("px")
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Export") {
                    // `resized(_:option:)` also guards against a
                    // non-positive value, but clamping here too means an
                    // invalid/empty field falls back to a sane default
                    // rather than a silent no-op-sized export.
                    let parsedLongEdge: CGFloat = Double(maxLongEdgeText).map { CGFloat($0) } ?? 2048
                    exportModel.settings.resize = useCustomResize
                        ? .maxLongEdge(max(parsedLongEdge, 1))
                        : .original
                    dismiss()
                    // Deferred to the next run loop turn, AFTER the sheet
                    // has actually finished dismissing — live-tested and
                    // confirmed: calling `onExport()` (which opens an
                    // `NSOpenPanel.runModal()`) synchronously right after
                    // `dismiss()` races the sheet's own still-in-progress
                    // dismissal, and the resulting panel appears but
                    // doesn't respond to clicks.
                    DispatchQueue.main.async {
                        onExport()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(photoCount == 0)
            }
        }
        .padding()
        .frame(width: 320)
    }
}
