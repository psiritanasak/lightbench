import AppKit
import SwiftUI

/// The Preferences window's state: each setting reads from and writes straight through to `AppPreferences` (so a change takes effect
/// the next time its feature looks — a culling pass starts, an import finishes, the next launch backup runs).
@MainActor
final class PreferencesModel: ObservableObject {
    private let store: AppPreferences

    @Published var cullAutoAdvance: Bool { didSet { store.cullAutoAdvance = cullAutoAdvance } }
    @Published var cullStartUnflaggedOnly: Bool { didSet { store.cullStartUnflaggedOnly = cullStartUnflaggedOnly } }
    @Published var autoReadXMPOnImport: Bool { didSet { store.autoReadXMPOnImport = autoReadXMPOnImport } }
    @Published var backupsToKeep: Int {
        didSet {
            let clamped = min(max(backupsToKeep, AppPreferences.keepBackupsRange.lowerBound), AppPreferences.keepBackupsRange.upperBound)
            store.backupsToKeep = clamped
            if clamped != backupsToKeep { backupsToKeep = clamped }
        }
    }

    init(store: AppPreferences = .shared) {
        self.store = store
        cullAutoAdvance = store.cullAutoAdvance
        cullStartUnflaggedOnly = store.cullStartUnflaggedOnly
        autoReadXMPOnImport = store.autoReadXMPOnImport
        backupsToKeep = store.backupsToKeep
    }
}

/// ⌘, — the app's Preferences window.
struct PreferencesView: View {
    @ObservedObject var model: PreferencesModel
    /// Plain values and actions, not the whole `CatalogModel`: observing it would redraw this window on every catalog change.
    var isBackupBusy: Bool
    var backUpNow: () async -> String
    var backupsFolder: () -> URL?
    @State private var backupStatus: String?

    var body: some View {
        Form {
            Section("Culling") {
                Toggle("Move to the next photo after Pick, Reject or Unflag", isOn: $model.cullAutoAdvance)
                Toggle("Start a pass on unflagged photos only", isOn: $model.cullStartUnflaggedOnly)
                Text("Applies the next time you start a culling pass.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textTertiary)
            }
            Section("Import") {
                Toggle("Read rating, label and keywords from .xmp files next to imported photos", isOn: $model.autoReadXMPOnImport)
                Text("Never overwrites a value you already set. Photo ▸ Read Metadata from XMP… does it on request.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textTertiary)
            }
            Section("Catalog backups") {
                Stepper(value: $model.backupsToKeep, in: AppPreferences.keepBackupsRange) {
                    Text("Keep the newest \(model.backupsToKeep) backups of each kind")
                }
                HStack {
                    Button("Back Up Now") { startBackUpNow() }
                        .disabled(isBackupBusy)
                    Button("Show Backups in Finder") { revealBackups() }
                    if isBackupBusy { ProgressView().controlSize(.small) }
                }
                if let backupStatus {
                    Text(backupStatus)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
                Text("A backup holds your ratings, flags, labels, keywords and collections, not your edits (those are saved next to each photo).")
                    .font(.footnote)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func startBackUpNow() {
        backupStatus = nil
        Task { backupStatus = await backUpNow() }
    }

    private func revealBackups() {
        guard let folder = backupsFolder() else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
}
