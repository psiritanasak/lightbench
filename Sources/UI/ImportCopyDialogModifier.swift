import SwiftUI

/// The options sheet, progress row (the activity strip) and result (relayed to the window's feedback: a toast or an alert) for "Copy Photos into Library…". Bundled inside `LibraryToolSheetsModifier`. The menus only
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
            .relayFeedback($model.feedback, to: catalog.post)
            .onChange(of: model.activityItem, initial: true) { _, item in catalog.activity.set(.importCopy, item) }
            .onDisappear { catalog.activity.set(.importCopy, nil) }
    }
}

/// The options sheet: where the photos go, how they are grouped and named, with a live preview of the first few results.
struct ImportCopySheetView: View {
    @ObservedObject var model: ImportCopyModel
    let providers: RenameProviders
    @ObservedObject var catalog: CatalogModel

    private var sizeText: String { ByteCountFormatter.string(fromByteCount: model.setup?.totalBytes ?? 0, countStyle: .file) }

    var body: some View {
        let count = model.setup?.sources.count ?? 0
        SheetScaffold(
            title: "Copy \(count) Photo\(count == 1 ? "" : "s") into the Library",
            size: .medium,
            status: model.sheetError.map { SheetStatus(text: $0, tone: .error) },
            // No default button: a destructive Move must never be one stray Return away.
            actions: .commit(verb: model.options.mode == .move ? "Copy and Trash Originals" : "Copy", enabled: model.canCopy,
                             primaryIsDefault: false),
            onDismiss: { model.cancel() },
            onPrimary: { model.requestStart(providers: providers, catalog: catalog) },
            content: { bodyContent }
        )
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

    private var bodyContent: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
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

            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack {
                    Text("Name").frame(width: 70, alignment: .leading)
                    TextField("{name}", text: $model.options.renameTemplate)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
                if let error = model.templateError {
                    Text(error.errorDescription ?? "Invalid template").font(.caption).foregroundStyle(Theme.error)
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

            VStack(alignment: .leading, spacing: Theme.Space.px2) {
                ForEach(Array(model.previewLines().enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }
}
