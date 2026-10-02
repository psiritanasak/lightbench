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
    /// The first photo of the batch, used only for the file-name preview.
    var previewPhoto: Photo?
    let onExport: () -> Void

    @State private var useCustomResize = false
    @State private var maxLongEdgeText = "2048"
    /// Read once (off the main thread) when the sheet appears — never per keystroke.
    @State private var previewCaptureDate: Date?

    private var preview: ExportNamePreview? {
        ExportNamePreview.evaluate(
            template: exportModel.settings.namingTemplate, photo: previewPhoto,
            format: exportModel.settings.format, captureDate: previewCaptureDate
        )
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export \(photoCount) Photo\(photoCount == 1 ? "" : "s")")
                .font(.headline)

            Picker("Format", selection: $exportModel.settings.format) {
                ForEach(ExportFormat.allCases) { format in
                    Text(format.label).tag(format)
                }
            }

            Picker("Color space", selection: $exportModel.settings.colorSpace) {
                ForEach(ExportColorSpace.allCases) { space in
                    Text(space.label).tag(space)
                }
            }

            Picker("Sharpening", selection: $exportModel.settings.sharpening) {
                ForEach(ExportSharpening.allCases) { option in
                    Text(option.label).tag(option)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Picker("Metadata", selection: $exportModel.settings.metadata) {
                    ForEach(ExportMetadataPolicy.allCases) { policy in
                        Text(policy.label).tag(policy)
                    }
                }
                if exportModel.settings.metadata == .all {
                    Text("Includes the location (GPS) if the photo has one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if exportModel.settings.format == .jpeg {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Quality: \(Int(exportModel.settings.quality * 100))%")
                    Slider(value: $exportModel.settings.quality, in: 0.1...1.0)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("File name")
                TextField("{name}", text: $exportModel.settings.namingTemplate)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                switch preview {
                case .templateError(let error):
                    Text(error.errorDescription ?? "Invalid template")
                        .font(.caption)
                        .foregroundStyle(.red)
                case .photoError(let error):
                    Text("The first photo would fail: \(error.errorDescription ?? "invalid name"). Other photos may still export.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                case .example(let name):
                    Text("Example: \(name)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .waitingForDate, nil:
                    EmptyView()
                }
                Text("Tokens: {name} {seq} {seq:4} {date} {datetime} {rating} {label} {flag}")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Watermark", isOn: $exportModel.settings.watermark.isEnabled)
                if exportModel.settings.watermark.isEnabled {
                    TextField("Text (e.g. © Your Name)", text: $exportModel.settings.watermark.text)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Watermark text")
                    Picker("Position", selection: $exportModel.settings.watermark.position) {
                        ForEach(WatermarkPosition.allCases) { position in
                            Text(position.label).tag(position)
                        }
                    }
                    HStack {
                        Text("Size")
                        Slider(value: $exportModel.settings.watermark.sizeFraction, in: ExportWatermark.sizeRange)
                            .accessibilityLabel("Watermark size")
                    }
                    HStack {
                        Text("Opacity")
                        Slider(value: $exportModel.settings.watermark.opacity, in: ExportWatermark.opacityRange)
                            .accessibilityLabel("Watermark opacity")
                    }
                    if !exportModel.settings.watermark.isActive {
                        Text("Type some text to add the mark.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
                    let parsedLongEdge: CGFloat = Double(maxLongEdgeText).flatMap { $0.isFinite ? CGFloat($0) : nil } ?? 2048
                    exportModel.settings.resize = useCustomResize
                        ? ExportResize.maxLongEdge(parsedLongEdge).sanitized
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
                .disabled(photoCount == 0 || (preview?.blocksExport ?? false))
            }
        }
        .padding()
    }

    /// The form as-is when it fits; otherwise the same form in a scroll view, so the Export button can never end up
    /// below the bottom of a small screen (the watermark section made the sheet taller).
    var body: some View {
        ViewThatFits(in: .vertical) {
            form
            ScrollView { form }.frame(height: 560)
        }
        .frame(width: 380)
        .onAppear {
            // Seed the resize controls from the remembered setting — otherwise the Export button would overwrite a
            // stored long edge with "original" from this sheet's own unseeded defaults.
            if case .maxLongEdge(let edge) = exportModel.settings.resize.sanitized {
                useCustomResize = true
                maxLongEdgeText = String(Int(edge.rounded()))
            }
        }
        .task {
            guard let photo = previewPhoto else { return }
            let url = URL(fileURLWithPath: photo.path)
            let imported = photo.importedAt
            previewCaptureDate = await Task.detached { CaptureDate.read(from: url, fallback: imported) }.value
        }
    }
}
