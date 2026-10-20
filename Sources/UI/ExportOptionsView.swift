import SwiftUI
import UniformTypeIdentifiers

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
    @State private var logoImporterShown = false
    /// The chosen logo's picture for the thumbnail, nil when none/unreadable. Refreshed when the sheet appears and when the choice changes.
    @State private var logoThumbnail: CGImage?
    /// Why the enabled watermark would draw nothing (nil when it will be drawn), refreshed with the thumbnail.
    @State private var watermarkProblem: String?
    @State private var logoImportError: String?
    @State private var logoImportBusy = false

    /// What the keyword toggle does and does NOT control. The toggle only adds the keywords typed in the Library; keywords
    /// the original file already carries (e.g. written by another app) follow the Metadata setting, not this toggle.
    private var keywordCaption: String {
        switch exportModel.settings.metadata {
        case .none:
            return "Not available with No metadata — no keywords are written."
        case .all:
            return "Adds the keywords you gave this photo in the Library. Keywords already inside the original file are kept either way."
        case .withoutLocation:
            return "Adds the keywords you gave this photo in the Library. Keywords already inside the original file are kept either way, and neither kind is filtered by \"All except location\" — a keyword that names a place is included."
        }
    }

    private var preview: ExportNamePreview? {
        ExportNamePreview.evaluate(
            template: exportModel.settings.namingTemplate, photo: previewPhoto,
            format: exportModel.settings.format, captureDate: previewCaptureDate
        )
    }

    /// Thumbnail + Choose/Remove. Picking uses `.fileImporter` (attached to the watermark section in `form`, which is
    /// always present), never an `NSOpenPanel` opened from here (see the note at the Export button about panels and
    /// sheet dismissal).
    private var logoRow: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Theme.raised)
                if let logoThumbnail {
                    Image(decorative: logoThumbnail, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .padding(3)
                }
            }
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)
            Button(exportModel.settings.watermark.logoID == nil ? "Choose Logo…" : "Change Logo…") { logoImporterShown = true }
                .buttonStyle(.flat)
                .disabled(logoImportBusy)
            if exportModel.settings.watermark.logoID != nil {
                Button("Remove") {
                    exportModel.settings.watermark.logoID = nil
                    logoImportError = nil
                    refreshLogoState()
                }
                .buttonStyle(.flat)
                .disabled(logoImportBusy)
            }
            if logoImportBusy { ProgressView().controlSize(.small) }
        }
    }

    /// One decode of the stored logo feeds both the thumbnail and the "why is nothing drawn" message.
    private func refreshLogoState() {
        let watermark = exportModel.settings.watermark
        // The logo file is only opened in Image mode with the watermark on, so typing in Text mode never touches the disk.
        let image = (watermark.isEnabled && watermark.kind == .image)
            ? watermark.logoID.flatMap { WatermarkLogoStore.shared.loadImage(id: $0) } : nil
        logoThumbnail = image
        watermarkProblem = watermark.inactiveReason(logoLoads: { _ in image != nil })
    }

    /// Decoding and re-encoding the picture runs off the main thread; a second pick is blocked meanwhile.
    private func importLogo(_ result: Result<URL, Error>) {
        guard !logoImportBusy else { return }
        switch result {
        case .failure:
            logoImportError = "The logo could not be opened."
            refreshLogoState()
        case .success(let url):
            logoImportBusy = true
            Task {
                let outcome: Result<String, Error> = await Task.detached {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    return Result { try WatermarkLogoStore.shared.importLogo(from: url) }
                }.value
                switch outcome {
                case .success(let id):
                    exportModel.settings.watermark.logoID = id
                    logoImportError = nil
                case .failure(let error):
                    logoImportError = (error as? LocalizedError)?.errorDescription ?? "The logo could not be used."
                }
                logoImportBusy = false
                refreshLogoState()
            }
        }
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
                        .foregroundStyle(Theme.textSecondary)
                }
                Toggle("Add Library keywords", isOn: $exportModel.settings.includeKeywords)
                    .disabled(exportModel.settings.metadata == .none)
                Text(keywordCaption)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            if exportModel.settings.format.isLossy {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Quality: \(Int(exportModel.settings.quality * 100))%")
                    ThinSlider(
                        value: Binding(get: { Double(exportModel.settings.quality) }, set: { exportModel.settings.quality = CGFloat(($0 * 100).rounded() / 100) }),
                        range: 0.1...1.0,
                        valueDescription: { "\(Int($0 * 100))%" }
                    )
                    .accessibilityLabel("\(exportModel.settings.format.label) quality")
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
                        .foregroundStyle(Theme.warning)
                case .example(let name):
                    Text("Example: \(name)")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                case .waitingForDate, nil:
                    EmptyView()
                }
                Text("Tokens: {name} {seq} {seq:4} {date} {datetime} {rating} {label} {flag}")
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Watermark", isOn: $exportModel.settings.watermark.isEnabled)
                if exportModel.settings.watermark.isEnabled {
                    Picker("Mark", selection: $exportModel.settings.watermark.kind) {
                        ForEach(WatermarkKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityLabel("Watermark type")
                    if exportModel.settings.watermark.kind == .text {
                        TextField("Text (e.g. © Your Name)", text: $exportModel.settings.watermark.text)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Watermark text")
                    } else {
                        logoRow
                    }
                    Picker("Position", selection: $exportModel.settings.watermark.position) {
                        ForEach(WatermarkPosition.allCases) { position in
                            Text(position.label).tag(position)
                        }
                    }
                    HStack {
                        Text("Size")
                        ThinSlider(value: $exportModel.settings.watermark.sizeFraction, range: ExportWatermark.sizeRange)
                            .accessibilityLabel("Watermark size")
                    }
                    HStack {
                        Text("Opacity")
                        ThinSlider(value: $exportModel.settings.watermark.opacity, range: ExportWatermark.opacityRange)
                            .accessibilityLabel("Watermark opacity")
                    }
                    if let problem = watermarkProblem {
                        Text(problem)
                            .font(.caption)
                            .foregroundStyle(Theme.warning)
                    }
                    if let error = logoImportError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(Theme.warning)
                    }
                }
            }
            // On the always-present watermark section (not on `logoRow`, which only exists in Image mode).
            .fileImporter(isPresented: $logoImporterShown, allowedContentTypes: [.png, .jpeg, .heic]) { result in
                importLogo(result)
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
                    .buttonStyle(.flat)
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
                .buttonStyle(FlatButtonStyle(prominent: true))
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
        .onChange(of: exportModel.settings.watermark.isEnabled) { _, _ in refreshLogoState() }
        .onChange(of: exportModel.settings.watermark.kind) { _, _ in refreshLogoState() }
        .onChange(of: exportModel.settings.watermark.text) { _, _ in refreshLogoState() }
        .onAppear {
            refreshLogoState()
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
