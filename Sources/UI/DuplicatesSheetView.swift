import CoreGraphics
import SwiftUI

/// "Find Duplicates…": scan, review groups, reject all but the best. Nothing is deleted; Reject is the existing flag
/// (U un-rejects, the Flag filter lists rejected photos).
struct DuplicatesSheetView: View {
    @ObservedObject var catalog: CatalogModel
    @ObservedObject var model: DuplicatesModel
    let onDone: () -> Void

    @State private var confirmAll = false

    private var rejectCount: Int { model.rejectable(model.groups.idsToReject).reject.count }
    private var pickedLeftCount: Int { model.rejectable(model.groups.idsToReject).leftPicked }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Find Duplicates").font(.headline)
            Text("Compares the photos in the current view. Files are never deleted or changed — \"keep best\" only flags the others as Rejected, which you can undo.")
                .font(.caption).foregroundStyle(Theme.textSecondary)

            Toggle("Include similar shots (same scene, different frame — may be a burst you want to keep)", isOn: $model.includeSimilarShots)
                .disabled(model.isScanning)

            HStack {
                if model.isScanning {
                    ProgressView(value: Double(model.progress?.completed ?? 0), total: Double(max(model.progress?.total ?? 1, 1)))
                        .frame(maxWidth: 220)
                    Text("\(model.progress?.completed ?? 0) of \(model.progress?.total ?? 0)").font(.caption).monospacedDigit()
                    Button("Cancel") { model.cancel() }.buttonStyle(.flat)
                } else {
                    Button(model.hasScanned ? "Scan Again" : "Scan") { catalog.beginDuplicateScan() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(FlatButtonStyle(prominent: true))
                }
            }

            if let summary = model.summary { Text(summary).font(.caption).foregroundStyle(Theme.textSecondary) }
            if let message = model.statusMessage { Text(message).font(.caption).foregroundStyle(Theme.warning) }

            if model.hasScanned && !model.isScanning {
                if model.groups.isEmpty {
                    Text(model.includeSimilarShots ? "No duplicates or similar shots found." : "No duplicates found.")
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(model.groups) { group in groupRow(group) }
                        }
                    }
                    .frame(minHeight: 220, maxHeight: 420)
                    HStack {
                        Text("\(model.groups.count) group\(model.groups.count == 1 ? "" : "s")").font(.caption).foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Button("Reject All But Best (\(rejectCount))") { confirmAll = true }
                            .buttonStyle(.flat)
                            .disabled(rejectCount == 0)
                    }
                }
            }

            HStack { Spacer(); Button("Done", action: onDone).keyboardShortcut(.cancelAction).buttonStyle(.flat) }
        }
        .padding(20)
        .frame(width: 640)
        .confirmationDialog(
            "Reject \(rejectCount) photo\(rejectCount == 1 ? "" : "s")?", isPresented: $confirmAll, titleVisibility: .visible
        ) {
            Button("Reject \(rejectCount)", role: .destructive) { reject(model.groups.idsToReject) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Each group's best photo is kept; the rest are flagged Rejected. Nothing is deleted, and U un-rejects."
                + (pickedLeftCount > 0 ? " \(pickedLeftCount) Picked photo\(pickedLeftCount == 1 ? " is" : "s are") left alone." : ""))
        }
    }

    private func label(_ kind: DuplicateKind) -> String {
        switch kind {
        case .exact: return "Exact copies"
        case .nearIdentical: return "Near-identical"
        case .similarShots: return "Similar shots"
        }
    }

    private func groupRow(_ group: DuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label(group.kind)).font(.subheadline.bold())
                Text("\(group.photoIDs.count) photos").font(.caption).foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("Keep best, reject others") { reject(group.othersIDs) }
                    .buttonStyle(FlatButtonStyle(compact: true))
                    .disabled(model.rejectable(group.othersIDs).reject.isEmpty)
                    .accessibilityLabel("Keep best, reject others: \(label(group.kind)), best is \(model.photosByID[group.bestID]?.filename ?? "unknown")")
            }
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(group.photoIDs, id: \.self) { id in
                        if let photo = model.photosByID[id] {
                            DuplicateThumbnail(catalog: catalog, photo: photo, isBest: id == group.bestID)
                        }
                    }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
    }

    private func reject(_ ids: [Int64]) {
        model.syncFlags(from: catalog.photos)
        let plan = model.rejectable(ids)
        guard !plan.reject.isEmpty else {
            model.statusMessage = plan.leftPicked > 0 ? "Nothing to reject: the others are Picked." : "Nothing to reject."
            return
        }
        Task {
            guard let changed = await catalog.setFlagStatus(.rejected, forPhotoIDs: plan.reject) else {
                model.statusMessage = "Couldn't update the flags — nothing was rejected. Try again."
                return
            }
            model.noteRejected(changed)
            var message = "Rejected \(changed.count) photo\(changed.count == 1 ? "" : "s"). Press U on a photo (or use the Flag filter) to undo."
            if plan.leftPicked > 0 { message += " \(plan.leftPicked) Picked photo\(plan.leftPicked == 1 ? " was" : "s were") left alone." }
            model.statusMessage = message
        }
    }
}

private struct DuplicateThumbnail: View {
    @ObservedObject var catalog: CatalogModel
    let photo: Photo
    let isBest: Bool
    @State private var image: CGImage?

    var body: some View {
        VStack(spacing: 3) {
            ZStack(alignment: .topLeading) {
                Group {
                    if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() } else { Color.gray.opacity(0.3) }
                }
                .frame(width: 96, height: 96).clipped()
                .opacity(photo.flagStatus == .rejected ? 0.4 : 1)
                if isBest {
                    Text("BEST").font(.caption2.bold()).padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Theme.markOn, in: Capsule()).foregroundStyle(.black).padding(3)
                }
            }
            Text(photo.filename).font(.caption2).lineLimit(1).frame(width: 96)
            Text(photo.flagStatus == .rejected ? "Rejected" : (photo.rating > 0 ? String(repeating: "★", count: photo.rating) : " "))
                .font(.caption2).foregroundStyle(Theme.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(photo.filename)\(isBest ? ", best" : "")\(photo.flagStatus == .rejected ? ", rejected" : "")\(photo.flagStatus == .picked ? ", picked" : "")")
        .task(id: photo.path) { image = await catalog.thumbnail(for: photo) }
    }
}

/// Presents `DuplicatesSheetView` when the Photo menu requests it, unless another sheet or dialog is up (`blocked`).
struct DuplicatesSheetModifier: ViewModifier {
    @ObservedObject var catalog: CatalogModel
    let blocked: Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: catalog.duplicatesSheetRequested) { _, requested in
                guard requested else { return }
                catalog.duplicatesSheetRequested = false
                if !blocked && !catalog.duplicatesSheetPresented {
                    catalog.duplicates.clear()   // every open starts fresh: no groups from another scope, no stale flags
                    catalog.duplicatesSheetPresented = true
                }
            }
            .sheet(isPresented: $catalog.duplicatesSheetPresented, onDismiss: {
                catalog.duplicates.cancel()
            }) {
                DuplicatesSheetView(catalog: catalog, model: catalog.duplicates) { catalog.duplicatesSheetPresented = false }
            }
    }
}

/// The Library tool sheets (keywords, duplicates, people) as ONE modifier: `ContentView.body` is at the type-checker's limit, so
/// each extra `.modifier` in its chain is not free. The sheets block each other; Photo Merge's dialog rides along.
struct LibraryToolSheetsModifier: ViewModifier {
    @ObservedObject var catalog: CatalogModel
    let blocked: Bool
    /// What Move to Trash re-checks around its prompts (see `TrashModel`): the open photo and everything that makes moving files unsafe.
    let trashProviders: RenameProviders

    func body(content: Content) -> some View {
        content
            .modifier(KeywordSheetModifier(catalog: catalog, blocked: blocked || catalog.duplicatesSheetPresented || catalog.peopleSheetPresented || catalog.mergeBusy || catalog.fileToolBusy))
            .modifier(DuplicatesSheetModifier(catalog: catalog, blocked: blocked || catalog.keywordSheetPhotoIDs != nil || catalog.peopleSheetPresented || catalog.mergeBusy || catalog.fileToolBusy))
            .modifier(PeopleSheetModifier(catalog: catalog, blocked: blocked || catalog.keywordSheetPhotoIDs != nil || catalog.duplicatesSheetPresented || catalog.mergeBusy || catalog.fileToolBusy))
            .modifier(MergeDialogModifier(
                catalog: catalog, model: catalog.merge,
                blocked: blocked || catalog.keywordSheetPhotoIDs != nil || catalog.duplicatesSheetPresented || catalog.peopleSheetPresented || catalog.fileToolBusy
            ))
            .modifier(XMPDialogModifier(
                catalog: catalog, model: catalog.xmp,
                blocked: blocked || catalog.keywordSheetPhotoIDs != nil || catalog.duplicatesSheetPresented || catalog.peopleSheetPresented || catalog.mergeBusy
            ))
            .modifier(TrashDialogModifier(
                catalog: catalog, model: catalog.trash, providers: trashProviders,
                blocked: blocked || catalog.keywordSheetPhotoIDs != nil || catalog.duplicatesSheetPresented || catalog.peopleSheetPresented || catalog.mergeBusy || catalog.xmpBusy
            ))
            .modifier(CatalogBackupDialogModifier(
                catalog: catalog, model: catalog.catalogBackup,
                blocked: blocked || catalog.keywordSheetPhotoIDs != nil || catalog.duplicatesSheetPresented || catalog.peopleSheetPresented
            ))
    }
}
