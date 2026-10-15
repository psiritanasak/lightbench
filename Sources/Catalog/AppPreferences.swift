import Foundation

/// The app's few user-facing preferences (the Preferences window, ⌘,), stored in `UserDefaults`.
///
/// Reads are schema-tolerant like `ExportSettingsStore`: a missing key, a value of the wrong type or an out-of-range number gives the
/// default, never a crash or a surprising state. Every setter clamps. The defaults reproduce the behaviour the app had before the window
/// existed, so a user who never opens it sees no change.
///
/// Under XCTest `shared` is a private throwaway suite, so a test host never reads or writes the developer's real preferences; tests that
/// care inject their own suite and remove it in tearDown.
struct AppPreferences: @unchecked Sendable { // UserDefaults is thread-safe
    static let keepBackupsRange = 1...30
    static let defaultBackupsToKeep = 5

    enum Key {
        static let cullAutoAdvance = "prefs.v1.cullAutoAdvance"
        static let cullStartUnflaggedOnly = "prefs.v1.cullStartUnflaggedOnly"
        static let autoReadXMPOnImport = "prefs.v1.autoReadXMPOnImport"
        static let backupsToKeep = "prefs.v1.backupsToKeep"
    }

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static let shared: AppPreferences = {
        guard CatalogDatabase.isRunningUnderXCTest else { return AppPreferences() }
        let name = "PhotoApp-XCTest-AppPreferences"
        let suite = UserDefaults(suiteName: name) ?? .standard
        suite.removePersistentDomain(forName: name)
        return AppPreferences(defaults: suite)
    }()

    private func bool(_ key: String, default value: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? value }

    /// Culling: after a Pick / Reject / Unflag key the pass moves to the next photo.
    var cullAutoAdvance: Bool {
        get { bool(Key.cullAutoAdvance, default: true) }
        nonmutating set { defaults.set(newValue, forKey: Key.cullAutoAdvance) }
    }

    /// Culling: a new pass starts on the photos with no flag yet (when there are any).
    var cullStartUnflaggedOnly: Bool {
        get { bool(Key.cullStartUnflaggedOnly, default: true) }
        nonmutating set { defaults.set(newValue, forKey: Key.cullStartUnflaggedOnly) }
    }

    /// Import: read rating / label / keywords from `.xmp` sidecars next to newly imported photos (never overwriting a value already set).
    var autoReadXMPOnImport: Bool {
        get { bool(Key.autoReadXMPOnImport, default: true) }
        nonmutating set { defaults.set(newValue, forKey: Key.autoReadXMPOnImport) }
    }

    /// How many backups of each kind (daily, manual) are kept in the Backups folder. The safety kinds (before-migration, before-restore, damaged)
    /// keep at least 5 whatever this is, and Back Up Now prunes only the manual pool.
    var backupsToKeep: Int {
        get {
            guard let stored = defaults.object(forKey: Key.backupsToKeep) as? Int, Self.keepBackupsRange.contains(stored) else {
                return Self.defaultBackupsToKeep
            }
            return stored
        }
        nonmutating set {
            defaults.set(min(max(newValue, Self.keepBackupsRange.lowerBound), Self.keepBackupsRange.upperBound), forKey: Key.backupsToKeep)
        }
    }
}
