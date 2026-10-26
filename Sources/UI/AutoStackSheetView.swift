import SwiftUI

/// "Auto Stack…": groups bursts (shots taken seconds apart that also look alike) into stacks. Nothing is written until Apply.
struct AutoStackSheetView: View {
    @ObservedObject var catalog: CatalogModel
    @ObservedObject var model: AutoStackModel
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Auto Stack").font(.headline)
            Text("Looks at the \(model.shownCount) photos shown (originals only; virtual copies follow their original) and proposes a stack for each burst: shots taken within the time below that also look alike. Nothing changes until you press Apply.")
                .font(.caption).foregroundStyle(Theme.textSecondary)

            HStack {
                Text("Within")
                Stepper(value: $model.maxGapSeconds, in: AutoStackModel.gapRange, step: 1) {
                    Text("\(Int(model.maxGapSeconds)) second\(Int(model.maxGapSeconds) == 1 ? "" : "s") of each other").monospacedDigit()
                }
                .disabled(model.isApplying)
            }
            Text("The time limit and the look-alike limit are rules of thumb tried on one trip's photos, not tested on bracketed HDR, panorama or portrait series, so check the preview. The cover of each stack is the best-rated, Picked or largest photo.")
                .font(.caption).foregroundStyle(Theme.textSecondary)
            Text("Stacks you made or changed by hand are never changed. Photos you unstacked are remembered and not stacked again.")
                .font(.caption).foregroundStyle(Theme.textSecondary)

            if catalog.metadataScanProgress != nil {
                Text("Camera data is still being read; photos without it are not stacked yet. Scan again when it finishes for a fuller result.")
                    .font(.caption).foregroundStyle(Theme.warning)
            }

            HStack {
                if model.isScanning {
                    ProgressView(value: Double(model.progress?.completed ?? 0), total: Double(max(model.progress?.total ?? 1, 1)))
                        .frame(maxWidth: 220)
                    Text("\(model.progress?.completed ?? 0) of \(model.progress?.total ?? 0)").font(.caption).monospacedDigit()
                    Button("Cancel") { model.cancel() }.buttonStyle(.flat)
                } else if model.preview == nil {
                    Button("Scan") { catalog.beginAutoStackScan() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(FlatButtonStyle(prominent: true))
                        .disabled(model.isApplying)
                } else {
                    Button("Scan Again") { catalog.beginAutoStackScan() }
                        .buttonStyle(.flat)
                        .disabled(model.isApplying)
                }
            }

            if let preview = model.preview, !model.isScanning {
                if preview.stackCount == 0 {
                    Text("No bursts found.").foregroundStyle(Theme.textSecondary)
                } else {
                    Text("\(preview.stackCount) stack\(preview.stackCount == 1 ? "" : "s") covering \(preview.photoCount) photos")
                        .font(.subheadline.bold())
                    if preview.replacedStacks > 0 {
                        Text("Replaces \(preview.replacedStacks) existing automatic stack\(preview.replacedStacks == 1 ? "" : "s").")
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
                if preview.keptStacks > 0 {
                    Text("\(preview.keptStacks) existing stack\(preview.keptStacks == 1 ? " was" : "s were") kept because not all their photos were examined. Clear the filters or show the whole folder to include them.")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }
                if preview.deferred > 0 {
                    Text("\(preview.deferred) photos were not examined: one run looks at the newest photos only. Narrow the view (for example to one folder) to reach the rest.")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            if model.undatedCount > 0 {
                Text("\(model.undatedCount) photo\(model.undatedCount == 1 ? " has" : "s have") no capture date and \(model.undatedCount == 1 ? "is" : "are") left out; their existing stacks are kept.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
            if model.unreadableCount > 0 {
                Text("\(model.unreadableCount) photo file\(model.unreadableCount == 1 ? "" : "s") could not be read (offline or missing) and \(model.unreadableCount == 1 ? "is" : "are") left out; their existing stacks are kept.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
            if model.skippedManual > 0 {
                Text("\(model.skippedManual) photo\(model.skippedManual == 1 ? " is" : "s are") in stacks you made by hand and left alone.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
            if model.skippedUnstacked > 0 {
                HStack {
                    Text("\(model.skippedUnstacked) of the shown photo\(model.skippedUnstacked == 1 ? " was" : "s were") unstacked by you and skipped.")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                    Button("Forget unstacked photos (whole library)") { Task { await catalog.forgetUnstackedPhotos() } }
                        .buttonStyle(FlatButtonStyle(compact: true))
                        .disabled(model.isWorking)
                }
            }
            if let message = model.statusMessage { Text(message).font(.caption).foregroundStyle(Theme.warning) }

            HStack {
                Spacer()
                Button("Apply") { Task { await catalog.applyAutoStack() } }
                    .buttonStyle(FlatButtonStyle(prominent: true))
                    .disabled(!model.canApply)
                Button("Done", action: onDone).keyboardShortcut(.cancelAction).buttonStyle(.flat)
                    .disabled(model.isApplying)
            }
        }
        .padding(20)
        .frame(width: 560)
        // An Apply is writing: the sheet stays until it and the Library refresh after it are done.
        .interactiveDismissDisabled(model.isApplying)
    }
}

/// Presents `AutoStackSheetView` when the Photo menu requests it, unless another sheet or dialog is up (`blocked`).
struct AutoStackSheetModifier: ViewModifier {
    @ObservedObject var catalog: CatalogModel
    let blocked: Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: catalog.autoStackSheetRequested) { _, requested in
                guard requested else { return }
                catalog.autoStackSheetRequested = false
                if !blocked && !catalog.autoStackSheetPresented && !catalog.autoStack.isWorking {
                    catalog.autoStack.clear()   // every open starts fresh: no preview from another scope
                    catalog.autoStack.shownCount = catalog.autoStackScopePhotos.count
                    catalog.autoStackSheetPresented = true
                }
            }
            .sheet(isPresented: $catalog.autoStackSheetPresented, onDismiss: {
                catalog.autoStack.cancel()
            }) {
                AutoStackSheetView(catalog: catalog, model: catalog.autoStack) { catalog.autoStackSheetPresented = false }
            }
    }
}
