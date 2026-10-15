import Foundation
import GRDB

/// What a catalog file looked like when it was inspected (read-only).
struct CatalogFileInfo: Equatable, Sendable {
    var photoCount: Int
    /// An older catalog that this build would migrate when opened (fine to restore: migrations run on the next launch).
    var needsMigration: Bool
}

/// Which backup a file is, from its name: `catalog-<yyyyMMdd-HHmmss>[-pre-migration|-before-restore|-damaged].sqlite`.
enum CatalogBackupKind: String, CaseIterable, Sendable {
    case automatic = ""
    /// Taken right before pending migrations run on the live file (a migration is the one thing that can change data in place).
    case preMigration = "-pre-migration"
    /// The catalog that a restore replaced.
    case beforeRestore = "-before-restore"
    /// An unreadable catalog a restore set aside instead of copying.
    case damaged = "-damaged"
}

/// What the launch-time restore step did; shown once after launch.
enum CatalogRestoreReport: Equatable, Sendable {
    case restored(photoCount: Int)
    case failed(String)

    var message: String {
        switch self {
        case .restored(let count): return "Catalog restored from backup (\(count) photo\(count == 1 ? "" : "s")). Your previous catalog was kept in the Backups folder."
        case .failed(let reason): return "The catalog restore didn't complete: \(reason)"
        }
    }
}

/// Hands the launch-time restore result from `CatalogDatabase.init()` (a detached task) to `CatalogModel`, which shows it.
final class CatalogRestoreReportStore: @unchecked Sendable {
    static let shared = CatalogRestoreReportStore()
    private let lock = NSLock()
    private var report: CatalogRestoreReport?

    func set(_ new: CatalogRestoreReport) { lock.lock(); report = new; lock.unlock() }
    func take() -> CatalogRestoreReport? { lock.lock(); defer { lock.unlock() }; let taken = report; report = nil; return taken }
}

extension CatalogDatabaseError: LocalizedError {
    var errorDescription: String? { message }
}

/// Catalog backups (IMPROVEMENTS.md / docs/RELEASE.md): the catalog holds ratings, flags, labels, keywords, collections, smart collections,
/// presets, faces and the rename log — but NOT edits (those live in `.photoapp.json` sidecars next to the photos) and NOT folder permissions
/// (security-scoped bookmarks live in UserDefaults). A backup therefore restores fully on the SAME Mac; on a new Mac the folders must be
/// imported / granted again.
///
/// Every copy goes through SQLite's online backup API (`DatabaseQueue.backup`), never `FileManager` on the live file, built in a scratch
/// location first, validated, and only then published — so a half-written or damaged file can never be mistaken for a backup.
extension CatalogDatabase {
    static let backupsFolderName = "Backups"
    static let pendingRestoreFileName = "catalog.restore-pending.sqlite"
    /// An automatic backup is skipped when any backup is newer than this.
    static let automaticBackupInterval: TimeInterval = 20 * 3600
    static let defaultBackupsToKeep = 5

    static func backupsDirectory(in catalogDirectory: URL) -> URL {
        catalogDirectory.appendingPathComponent(backupsFolderName, isDirectory: true)
    }

    // MARK: Naming

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    static func backupFileName(_ kind: CatalogBackupKind, at date: Date) -> String {
        "catalog-\(stampFormatter.string(from: date))\(kind.rawValue).sqlite"
    }

    /// The kind and timestamp encoded in a backup file name, or nil if it is not one of ours.
    static func parseBackupFileName(_ name: String) -> (kind: CatalogBackupKind, stamp: String)? {
        guard name.hasPrefix("catalog-"), name.hasSuffix(".sqlite") else { return nil }
        let body = String(name.dropFirst("catalog-".count).dropLast(".sqlite".count))
        for kind in CatalogBackupKind.allCases where kind != .automatic && body.hasSuffix(kind.rawValue) {
            let stamp = String(body.dropLast(kind.rawValue.count))
            return stampFormatter.date(from: stamp) == nil ? nil : (kind, stamp)
        }
        return stampFormatter.date(from: body) == nil ? nil : (.automatic, body)
    }

    // MARK: Inspect

    /// Opens `url` read-only and checks it is a healthy catalog this build can use: SQLite integrity, a `photo` table, and no migrations
    /// from a NEWER build (GRDB would otherwise open such a file and ignore the unknown ones).
    static func inspectCatalogFile(at url: URL) throws -> CatalogFileInfo {
        var configuration = Configuration()
        configuration.readonly = true
        do {
            let queue = try DatabaseQueue(path: url.path, configuration: configuration)
            return try queue.read { db in
                guard try db.tableExists("photo") else {
                    throw CatalogDatabaseError(message: "That file isn't a Lightbench catalog.")
                }
                guard try String.fetchAll(db, sql: "PRAGMA integrity_check") == ["ok"] else {
                    throw CatalogDatabaseError(message: "That catalog file is damaged.")
                }
                let migrator = makeMigrator()
                if try migrator.hasBeenSuperseded(db) {
                    throw CatalogDatabaseError(message: newerVersionMessage)
                }
                let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM photo") ?? 0
                return CatalogFileInfo(photoCount: count, needsMigration: !(try migrator.hasCompletedMigrations(db)))
            }
        } catch let error as CatalogDatabaseError {
            throw error
        } catch {
            throw CatalogDatabaseError(message: "That file isn't a readable Lightbench catalog.")
        }
    }

    static let newerVersionMessage = "This catalog was made by a newer version of Lightbench and can't be opened by this one. Update the app, or restore an older backup."

    // MARK: Snapshot

    /// Copies `source` to `destination` through the SQLite backup API: scratch file → validate → publish. The scratch file lives in `scratch`
    /// (the app's own temp directory by default), NOT beside `destination`: a sandboxed save panel only grants the one chosen file. If
    /// `destination` exists it is replaced, but only once the new copy is complete (a failed copy restores the old file where the file system allows).
    @discardableResult
    static func snapshot(from source: DatabaseQueue, to destination: URL, scratch: URL = FileManager.default.temporaryDirectory,
                         replace: (URL, URL) throws -> Void = defaultReplace) throws -> CatalogFileInfo {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        let partial = scratch.appendingPathComponent("catalog-backup-\(UUID().uuidString).partial")
        defer { try? fileManager.removeItem(at: partial) }
        do {
            let target = try DatabaseQueue(path: partial.path)
            try source.backup(to: target)
        }
        let info = try inspectCatalogFile(at: partial)
        try publish(partial, as: destination, scratch: scratch, replace: replace)
        return info
    }

    /// The atomic swap `publish` tries first (a seam so the fallback can be tested).
    static let defaultReplace: @Sendable (URL, URL) throws -> Void = { destination, partial in
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: partial)
    }

    /// Puts `partial` at `destination`. An existing destination is never deleted before the new copy is complete: if the atomic swap is not
    /// available (a sandboxed save panel may not allow its temporary file) the old file is moved aside, the copy is made, and on failure the
    /// partial copy is removed and the old file moved back.
    private static func publish(_ partial: URL, as destination: URL, scratch: URL, replace: (URL, URL) throws -> Void) throws {
        let fileManager = FileManager.default
        var aside: URL?
        if fileManager.fileExists(atPath: destination.path) {
            do {
                try replace(destination, partial)
                return
            } catch {
                let held = scratch.appendingPathComponent("catalog-backup-previous-\(UUID().uuidString)")
                try fileManager.moveItem(at: destination, to: held)
                aside = held
            }
        }
        do {
            try fileManager.copyItem(at: partial, to: destination)
            if let aside { try? fileManager.removeItem(at: aside) }
        } catch {
            try? fileManager.removeItem(at: destination)
            if let aside { try? fileManager.moveItem(at: aside, to: destination) }
            throw error
        }
    }

    /// A consistent snapshot of THIS catalog while the app keeps running (other writes wait on the queue).
    func backUp(to destination: URL) async throws -> CatalogFileInfo {
        try await Task.detached { try Self.snapshot(from: self.dbQueue, to: destination) }.value
    }

    // MARK: Pruning

    /// Keeps the newest `keepNewest` backups of EACH kind in `directory` (newest by the timestamp in the file name) and deletes the rest.
    /// Files that are not ours are never touched.
    @discardableResult
    static func pruneBackups(in directory: URL, keepNewest: Int) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var removed: [String] = []
        for kind in CatalogBackupKind.allCases {
            let ours = names.compactMap { name -> (String, String)? in
                guard let parsed = parseBackupFileName(name), parsed.kind == kind else { return nil }
                return (name, parsed.stamp)
            }.sorted { $0.1 > $1.1 }
            for (name, _) in ours.dropFirst(max(1, keepNewest)) {
                if (try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))) != nil { removed.append(name) }
            }
        }
        return removed
    }

    // MARK: Launch

    /// A crash mid-write leaves a "hot" `-journal` next to the catalog. A READ-ONLY open cannot roll it back (it fails with
    /// SQLITE_READONLY_ROLLBACK), and treating the file without its journal as the catalog reads a half-written database. So before anything
    /// is copied, open the file read-write once WITHOUT migrating: SQLite rolls the journal back, nothing else is written.
    static func rollBackHotJournalIfAny(at catalogURL: URL) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: catalogURL.path),
              fileManager.fileExists(atPath: catalogURL.path + "-journal") else { return }
        if let queue = try? DatabaseQueue(path: catalogURL.path) {
            _ = try? queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sqlite_master") }
        }
    }

    /// Takes the launch-time backup BEFORE the catalog is opened with migrations: always when migrations are pending (kind `preMigration`),
    /// otherwise when no backup is newer than `automaticBackupInterval`. Best effort: it never blocks or fails a launch, and a catalog that
    /// cannot even be read is not copied (that would only duplicate the damage).
    static func launchBackup(catalogURL: URL, now: Date = Date(), keepNewest: Int = defaultBackupsToKeep) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: catalogURL.path) else { return }
        let directory = backupsDirectory(in: catalogURL.deletingLastPathComponent())
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            rollBackHotJournalIfAny(at: catalogURL)
            var configuration = Configuration()
            configuration.readonly = true
            let source = try DatabaseQueue(path: catalogURL.path, configuration: configuration)
            let pending = try source.read { try !makeMigrator().hasCompletedMigrations($0) }
            let kind: CatalogBackupKind
            if pending {
                kind = .preMigration
            } else {
                let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
                let newest = names.compactMap { parseBackupFileName($0) }.compactMap { stampFormatter.date(from: $0.stamp) }.filter { $0 <= now }.max()
                // A backup stamped in the future (clock or time zone change) must not suppress backups until that date.
                if let newest, now.timeIntervalSince(newest) < automaticBackupInterval { return }
                kind = .automatic
            }
            try snapshot(from: source, to: directory.appendingPathComponent(backupFileName(kind, at: now)))
            pruneBackups(in: directory, keepNewest: keepNewest)
        } catch {
            // Deliberately silent: see above.
        }
    }

    // MARK: Restore

    /// Validates `backupURL` and stages a copy next to the catalog for the NEXT launch to swap in (the running app holds the catalog open and
    /// every model caches its rows, so a live swap is not safe). Returns what was found in the backup.
    @discardableResult
    static func stageRestore(from backupURL: URL, into catalogDirectory: URL) throws -> CatalogFileInfo {
        _ = try inspectCatalogFile(at: backupURL)
        var configuration = Configuration()
        configuration.readonly = true
        let source = try DatabaseQueue(path: backupURL.path, configuration: configuration)
        return try snapshot(from: source, to: catalogDirectory.appendingPathComponent(pendingRestoreFileName))
    }

    /// Puts the staged file in place of the catalog (a seam so a failing swap can be tested).
    static let defaultInstall: @Sendable (URL, URL) throws -> Void = { staged, catalog in
        if FileManager.default.fileExists(atPath: catalog.path) {
            _ = try FileManager.default.replaceItemAt(catalog, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: catalog)
        }
    }

    /// At launch, BEFORE the catalog is opened: if a restore is staged, set the current catalog aside (a normal `-before-restore` backup, or
    /// `-damaged` if it cannot be copied) and swap the staged file in. Any failure leaves the current catalog in place and discards the stage.
    @discardableResult
    static func applyPendingRestore(in catalogDirectory: URL, now: Date = Date(),
                                    install: (_ staged: URL, _ catalog: URL) throws -> Void = defaultInstall) -> CatalogRestoreReport? {
        let fileManager = FileManager.default
        let staging = catalogDirectory.appendingPathComponent(pendingRestoreFileName)
        guard fileManager.fileExists(atPath: staging.path) else { return nil }
        let catalogURL = catalogDirectory.appendingPathComponent("catalog.sqlite")
        let journalURL = URL(fileURLWithPath: catalogURL.path + "-journal")
        var setAside: URL?
        do {
            let info = try inspectCatalogFile(at: staging)
            if fileManager.fileExists(atPath: catalogURL.path) {
                let directory = backupsDirectory(in: catalogDirectory)
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                rollBackHotJournalIfAny(at: catalogURL)
                do {
                    var configuration = Configuration()
                    configuration.readonly = true
                    let current = try DatabaseQueue(path: catalogURL.path, configuration: configuration)
                    try snapshot(from: current, to: directory.appendingPathComponent(backupFileName(.beforeRestore, at: now)))
                } catch {
                    // Unreadable current catalog (probably why the user is restoring): set it aside whole instead of losing it.
                    let damaged = directory.appendingPathComponent(backupFileName(.damaged, at: now))
                    try fileManager.moveItem(at: catalogURL, to: damaged)
                    setAside = damaged
                }
            }
            try install(staging, catalogURL)
            // Defence in depth (no test reaches it: rollBackHotJournalIfAny, or SQLite's own read-write open of a junk journal, already cleared it): a stale journal would be replayed onto the restored catalog.
            try? fileManager.removeItem(at: journalURL)
            return .restored(photoCount: info.photoCount)
        } catch {
            try? fileManager.removeItem(at: staging)
            var restoredOriginal = true
            if let setAside, !fileManager.fileExists(atPath: catalogURL.path) {
                // The catalog was moved aside but the swap failed: put it back so the next launch finds it.
                do {
                    try fileManager.moveItem(at: setAside, to: catalogURL)
                } catch { restoredOriginal = false }
            }
            let reason = (error as? CatalogDatabaseError)?.message ?? error.localizedDescription
            return .failed((reason.hasSuffix(".") ? reason : reason + ".") + (restoredOriginal ? " Your current catalog was not changed." : " Your previous catalog is in the Backups folder."))
        }
    }
}
