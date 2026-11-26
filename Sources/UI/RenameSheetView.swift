import SwiftUI

/// The Library's "Rename Files…" sheet: a name template, a start number, and a live old → new
/// preview of every selected photo. Renaming changes the names of the ORIGINAL files on disk (and
/// their edit files), so the preview is the whole point: nothing happens until every row is fine.
struct RenameSheetView: View {
    @ObservedObject var model: RenameModel

    private var summary: String {
        guard let plan = model.plan else { return "" }
        let renames = plan.renames.count
        let blocked = plan.entries.filter { if case .blocked = $0.decision { return true } else { return false } }.count
        let unchanged = plan.entries.count - renames - blocked
        var parts = ["\(renames) will be renamed"]
        if unchanged > 0 { parts.append("\(unchanged) unchanged") }
        if blocked > 0 { parts.append("\(blocked) blocked") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        SheetScaffold(
            title: "Rename \(model.photoCount) Photo\(model.photoCount == 1 ? "" : "s")",
            size: .medium,
            height: 560,
            status: model.sheetError.map { SheetStatus(text: $0, tone: .error) },
            actions: .commit(verb: "Rename", enabled: model.canApply, cancelEnabled: !model.isWorking),
            onDismiss: { model.cancel() },
            onPrimary: { model.apply() },
            leading: { if model.isWorking { ProgressView().controlSize(.small) } },
            content: { bodyContent }
        )
        .interactiveDismissDisabled(model.isWorking) // never lose the sheet (and its errors) mid-rename
        .onAppear { model.sheetDidAppear() }
        .onDisappear { model.sheetDidDisappear() }
    }

    private var bodyContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This renames the original files on disk (and their edit files). Nothing is renamed until every row below is fine, and you can undo the last rename.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Text("New name")
                TextField("{name}", text: $model.template)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                if let error = model.templateError {
                    Text(error.errorDescription ?? "Invalid template")
                        .font(.caption)
                        .foregroundStyle(Theme.error)
                } else {
                    Text("Tokens: {name} {seq} {seq:4} {date} {datetime} {rating} {label} {flag} — the file extension is kept.")
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            HStack(spacing: 8) {
                Text("Start numbering at")
                TextField("1", text: $model.sequenceStartText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                if let message = model.sequenceStartMessage {
                    Text(message).font(.caption).foregroundStyle(Theme.error)
                }
            }

            HStack {
                Text(summary).font(.caption).foregroundStyle(Theme.textSecondary)
                if model.isLoadingDates || model.isLoadingOwners {
                    ProgressView().controlSize(.small)
                    Text(model.isLoadingDates ? "Reading capture dates…" : "Checking the library…")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }

            previewList
        }
    }

    private var previewList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if let plan = model.plan {
                    ForEach(Array(plan.entries.enumerated()), id: \.offset) { _, entry in
                        row(for: entry)
                    }
                } else {
                    Text(model.templateError == nil ? "" : "Fix the template to see a preview.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(6)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func row(for entry: RenamePlanEntry) -> some View {
        let oldName = URL(fileURLWithPath: entry.photo.path).lastPathComponent
        switch entry.decision {
        case .rename:
            HStack(spacing: 6) {
                Text(oldName).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(Theme.textTertiary)
                Text(entry.newName ?? "").lineLimit(1).truncationMode(.middle)
            }
            .font(.system(.caption, design: .monospaced))
        case .unchanged:
            Text("\(oldName)  (unchanged)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        case .blocked(let block):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(Theme.error)
                Text(oldName).lineLimit(1).truncationMode(.middle)
                Text(block.message).foregroundStyle(Theme.error)
            }
            .font(.system(.caption, design: .monospaced))
        }
    }
}
