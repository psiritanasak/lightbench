import SwiftUI

/// Progress panel while photos are copied.
struct ImportCopyWorkingHUD: View {
    let done: Int
    let total: Int

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(total > 0 ? "Copying photos… \(done) of \(total)" : "Copying photos…").font(.caption)
        }
        .padding(12)
        .solidPanel(cornerRadius: 10)
        .padding(.bottom, 16)
    }
}

/// The options sheet, progress HUD and result alert for "Copy Photos into Library…". Bundled inside `LibraryToolSheetsModifier`. The menus only
/// REQUEST through `catalog.importCopyRequested`; a request made while another sheet or dialog is up is dropped (`blocked`).
struct ImportCopyDialogModifier: ViewModifier {
    @ObservedObject var catalog: CatalogModel
    @ObservedObject var model: ImportCopyModel
    let providers: RenameProviders
    let blocked: Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: catalog.importCopyRequested) { _, requested in
                guard requested else { return }
                catalog.importCopyRequested = false
                guard !blocked else { return }
                model.begin(providers: providers, catalog: catalog)
            }
            .sheet(isPresented: Binding(get: { model.setup != nil }, set: { if !$0 { model.cancel() } })) {
                ImportCopySheetView(model: model, providers: providers, catalog: catalog)
            }
            .alert(
                "Copy Photos",
                isPresented: Binding(get: { model.statusMessage != nil }, set: { if !$0 { model.statusMessage = nil } }),
                presenting: model.statusMessage
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
            .overlay(alignment: .bottom) {
                if model.isWorking { ImportCopyWorkingHUD(done: model.progressDone, total: model.progressTotal) }
            }
    }
}

/// The options sheet: where the photos go, how they are grouped and named, with a live preview of the first few results.
struct ImportCopySheetView: View {
    @ObservedObject var model: ImportCopyModel
    let providers: RenameProviders
    @ObservedObject var catalog: CatalogModel

    private var sizeText: String { ByteCountFormatter.string(fromByteCount: model.setup?.totalBytes ?? 0, countStyle: .file) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let count = model.setup?.sources.count ?? 0
            Text("Copy \(count) Photo\(count == 1 ? "" : "s") into the Library").font(.headline)
            Text("From “\(model.setup?.sourceFolder.lastPathComponent ?? "")” · \(sizeText). \(ImportCopyModel.sheetIntro(mode: model.options.mode))")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("Copy to").frame(width: 70, alignment: .leading)
                Text(model.destination?.path ?? "No folder chosen")
                    .foregroundStyle(model.destination == nil ? Theme.textTertiary : Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Choose…") { model.chooseDestination() }.buttonStyle(.flat)
            }

            HStack {
                Text("Folders").frame(width: 70, alignment: .leading)
                Picker("", selection: $model.options.subfolders) {
                    ForEach(ImportCopyOptions.Subfolders.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Name").frame(width: 70, alignment: .leading)
                    TextField("{name}", text: $model.options.renameTemplate)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
                if let error = model.templateError {
                    Text(error.errorDescription ?? "Invalid template").font(.caption).foregroundStyle(.red)
                } else {
                    Text("Tokens: {name} {seq} {seq:4} {date} {datetime} — the file extension is kept. {name} keeps the original name.")
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            Toggle("Skip photos already in the destination (same name and identical content)", isOn: $model.options.skipAlreadyCopied)
                .font(.caption)

            HStack {
                Text("Originals").frame(width: 70, alignment: .leading)
                Picker("", selection: $model.options.mode) {
                    Text("Keep them").tag(ImportCopyOptions.Mode.copy)
                    Text("Move to the Trash").tag(ImportCopyOptions.Mode.move)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if model.options.mode == .move {
                Text("Each original goes to the Trash only after its copy is flushed to the destination disk and checked against it. A photo that cannot be confirmed stays where it is. Nothing is permanently deleted.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(model.previewLines().enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if let error = model.sheetError {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { model.cancel() }
                    .buttonStyle(.flat)
                    .keyboardShortcut(.cancelAction)
                Button(model.options.mode == .move ? "Copy and Trash Originals" : "Copy") {
                    model.requestStart(providers: providers, catalog: catalog)
                }
                .buttonStyle(FlatButtonStyle(prominent: true))
                .disabled(!model.canCopy)
            }
        }
        .padding()
        .frame(width: 560)
        // Move only: a destructive confirmation with NO default button (Return must not confirm), like the Trash commands.
        .confirmationDialog(
            ImportCopyModel.moveConfirmationTitle(count: model.setup?.sources.count ?? 0),
            isPresented: $model.confirmingMove,
            titleVisibility: .visible
        ) {
            Button("Copy and Move to Trash", role: .destructive) { model.confirm(providers: providers, catalog: catalog, moveConfirmed: true) }
            Button("Cancel", role: .cancel) { model.confirmingMove = false }
        } message: {
            Text(ImportCopyModel.moveConfirmationMessage(
                source: model.setup?.sourceFolder.lastPathComponent ?? "", destination: model.destination?.lastPathComponent ?? ""
            ))
        }
    }
}
