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
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename \(model.photoCount) Photo\(model.photoCount == 1 ? "" : "s")")
                .font(.headline)
            Text("This renames the original files on disk (and their edit files). Nothing is renamed until every row below is fine, and you can undo the last rename.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Text("New name")
                TextField("{name}", text: $model.template)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                if let error = model.templateError {
                    Text(error.errorDescription ?? "Invalid template")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Text("Tokens: {name} {seq} {seq:4} {date} {datetime} {rating} {label} {flag} — the file extension is kept.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            HStack(spacing: 8) {
                Text("Start numbering at")
                TextField("1", text: $model.sequenceStartText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                if let message = model.sequenceStartMessage {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }

            HStack {
                Text(summary).font(.caption).foregroundStyle(.secondary)
                if model.isLoadingDates || model.isLoadingOwners {
                    ProgressView().controlSize(.small)
                    Text(model.isLoadingDates ? "Reading capture dates…" : "Checking the library…")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            previewList

            if let error = model.sheetError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if model.isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isWorking)
                Button("Rename") { model.apply() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canApply)
            }
        }
        .padding()
        .frame(width: 580, height: 560)
        .interactiveDismissDisabled(model.isWorking) // never lose the sheet (and its errors) mid-rename
        .onAppear { model.sheetDidAppear() }
        .onDisappear { model.sheetDidDisappear() }
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
                        .foregroundStyle(.secondary)
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
                Text(oldName).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                Text(entry.newName ?? "").lineLimit(1).truncationMode(.middle)
            }
            .font(.system(.caption, design: .monospaced))
        case .unchanged:
            Text("\(oldName)  (unchanged)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        case .blocked(let block):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.red)
                Text(oldName).lineLimit(1).truncationMode(.middle)
                Text(block.message).foregroundStyle(.red)
            }
            .font(.system(.caption, design: .monospaced))
        }
    }
}
