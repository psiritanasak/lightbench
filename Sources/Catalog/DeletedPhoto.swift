import Foundation

/// What "Recently Deleted" remembers about a photo that Move to Trash took out of the Library (table `deleted_photo`, Migration 018).
/// A SNAPSHOT of the rows, not a hidden photo row. Nothing here touches a file: restoring puts catalog rows back, never a file.
struct DeletedPhotoSnapshot: Codable, Equatable, Sendable {
    /// The JSON layout version stored next to the snapshot (`deleted_photo.schemaVersion`).
    static let currentSchemaVersion = 1

    struct CollectionRef: Codable, Equatable, Sendable {
        var id: Int64
        var name: String
        /// A folder-mirrored collection is also found again by its folder path (a re-import creates a NEW collection row for the same folder).
        var folderPath: String? = nil
    }

    /// One photo row (the master, or a virtual copy) with the things that hang off it by name.
    struct Row: Codable, Equatable, Sendable {
        var photo: Photo
        /// Keyword NAMES (the keyword rows are shared and are re-found or re-created by name).
        var keywords: [String]
        var collections: [CollectionRef]
    }

    struct StackRef: Codable, Equatable, Sendable {
        var stackId: Int64
        var isManual: Bool
        var wasCover: Bool
        var addedManually: Bool
        /// Every member (master ids) of the stack when the photo left.
        var memberIDs: [Int64]
    }

    /// The master first, then its virtual copies; or a single virtual copy trashed on its own.
    var rows: [Row]
    /// The photograph's Library info (master only).
    var info: PhotoInfo?
    var stack: StackRef?
    /// The edit files (original paths) that went to the Trash together with the photo; empty/absent when none (or an older snapshot).
    var editFilePaths: [String]? = nil

    /// How a table that references `photo` is treated by Recently Deleted. EVERY table with a foreign key to `photo` must be listed
    /// (a test enumerates them with `PRAGMA foreign_key_list` and fails when one is missing), so a future table forces a decision.
    enum Handling: Sendable {
        /// Captured in the snapshot and put back by a restore.
        case snapshotted
        /// Not captured: the existing scanners rebuild it after a restore (fingerprints, metadata, faces).
        case rebuiltByScanners
        /// Not captured, on purpose (documented limit).
        case notRestored
    }

    static let foreignKeyHandling: [String: Handling] = [
        "photo": .snapshotted, // masterId: a master's copies travel inside its snapshot
        "collection_photo": .snapshotted,
        "photo_keyword": .snapshotted,
        "photo_info": .snapshotted,
        "photo_stack": .snapshotted, // coverPhotoId
        "photo_stack_member": .snapshotted,
        "photo_stack_exclusion": .notRestored, // an "unstack" memory; the photo simply may be auto-stacked again
        "photo_fingerprint": .rebuiltByScanners,
        "photo_metadata": .rebuiltByScanners,
        "face": .notRestored, // detections are rescanned; face confirmations / names for the photo are not restored in v1
        "face_scan": .rebuiltByScanners
    ]

    var copyCount: Int { rows.first?.photo.isVirtualCopy == true ? 0 : max(rows.count - 1, 0) }
}

/// Why a Recently Deleted entry cannot be restored right now, judged from the catalog alone.
enum DeletedPhotoBlocker: Equatable, Sendable {
    /// Another master row already owns the original path.
    case pathInUse
    /// A virtual copy's master is no longer in the Library.
    case masterMissing
}

/// One entry of the Recently Deleted list.
struct DeletedPhotoEntry: Equatable, Identifiable, Sendable {
    let id: Int64
    let originalPath: String
    let trashedPath: String?
    let deletedAt: Date
    let snapshot: DeletedPhotoSnapshot
    let blocker: DeletedPhotoBlocker?

    var name: String { (originalPath as NSString).lastPathComponent }
    var folder: String { (originalPath as NSString).deletingLastPathComponent }
    /// Virtual copies that come back with the photo (0 for an entry that IS one copy).
    var copyCount: Int { snapshot.copyCount }
    var editFilePaths: [String] { snapshot.editFilePaths ?? [] }
    var isVirtualCopyEntry: Bool { snapshot.rows.first?.photo.isVirtualCopy == true }
}

/// What a restore did.
struct DeletedPhotoRestoreReport: Equatable, Sendable {
    var restoredCopies = 0
    /// Names of collections the photo was in that no longer exist (it is not put back into those).
    var missingCollections: [String] = []
    var stackRestored = false
}

/// An entry whose snapshot cannot be read (a newer layout, or damaged JSON): listed so it can be removed, never restored.
struct UnreadableDeletedPhoto: Equatable, Identifiable, Sendable {
    let id: Int64
    let originalPath: String
    let deletedAt: Date
    var name: String { (originalPath as NSString).lastPathComponent }
}

enum DeletedPhotoRestoreOutcome: Equatable, Sendable {
    case restored(DeletedPhotoRestoreReport)
    case notFound
    /// The file is not at its original path (it may still be in the Trash).
    case fileMissing
    case pathInUse
    case masterMissing
    /// The photo file is back but an edit file that went to the Trash with it is not.
    case editFileMissing
    /// A photo row with one of the original ids exists already (should not happen: ids are never reused).
    case idInUse
}

/// What the sheet says about an entry.
enum RecentlyDeletedStatus: Equatable, Sendable {
    case ready, readyCopy, mayBeInTrash, pathInUse, masterMissing, editFileMissing

    static func of(blocker: DeletedPhotoBlocker?, fileExists: Bool, editFilesExist: Bool = true, isCopy: Bool = false) -> RecentlyDeletedStatus {
        switch blocker {
        case .pathInUse: return .pathInUse
        case .masterMissing: return .masterMissing
        case nil:
            guard fileExists else { return .mayBeInTrash }
            guard editFilesExist else { return .editFileMissing }
            return isCopy ? .readyCopy : .ready
        }
    }

    var canRestore: Bool { self == .ready || self == .readyCopy }

    var message: String {
        switch self {
        case .ready: return "File is back at its original location: ready to restore"
        case .readyCopy: return "The virtual copy's edit file is back: ready to restore"
        case .mayBeInTrash: return "May still be in the Trash — use Put Back in Finder first, together with its edit file and XMP sidecar"
        case .pathInUse: return "Original location is used by another catalogued photo"
        case .masterMissing: return "The photo this virtual copy belongs to is not in the Library"
        case .editFileMissing: return "The photo is back but its edit file is still in the Trash — Put Back the edit file too"
        }
    }
}
