import Foundation

/// The file half of "Create Virtual Copy": a copy is another catalog row over the SAME image file, whose edits live in their own
/// `<file>.<versionKey>.photoapp.json`. Pure file I/O (no UI, no catalog); the caller holds the folder's security scope.
///
/// Safety rules (tested): the image file is never opened for writing, moved or touched; an existing version sidecar is NEVER overwritten
/// (a key that already has a file on disk is refused, so an orphan from an earlier session is not silently adopted); a source whose edit
/// file exists but cannot be read is refused rather than copied as "no edits"; the copy starts WITHOUT the source's undo history.
enum VirtualCopyFiles {
    enum Failure: Error, LocalizedError, Equatable {
        case fileMissing
        case sourceEditsUnreadable
        case versionFileExists

        var errorDescription: String? {
            switch self {
            case .fileMissing: return "the photo's file is missing"
            case .sourceEditsUnreadable: return "its saved edits could not be read, so they could not be copied"
            case .versionFileExists: return "an edit file for that version already exists"
            }
        }
    }

    /// A fresh version key: eight lowercase hex characters (`SidecarStore.isValidVersionKey`) whose edit file does not already exist
    /// beside `photoURL`. `random` is injectable so tests can force collisions.
    static func newVersionKey(
        forPhotoAt photoURL: URL,
        random: () -> UInt32 = { UInt32.random(in: 0...UInt32.max) },
        fileExists: (URL) -> Bool = { RenameEngine.itemExists($0) }
    ) -> String? {
        for _ in 0..<16 {
            let key = String(format: "%08x", random())
            if !fileExists(SidecarStore.sidecarURL(for: photoURL, versionKey: key)) { return key }
        }
        return nil
    }

    /// Writes the new version's edit file: the SOURCE version's saved edits (`source` is a master or another copy), without `_history`.
    /// Returns the file written, or nil when the source has no saved edits (nothing to copy: a version with no file means "unedited").
    @discardableResult
    static func writeVersionSidecar(from source: Photo, versionKey: String) throws -> URL? {
        let photoURL = URL(fileURLWithPath: source.path)
        guard FileManager.default.fileExists(atPath: photoURL.path) else { throw Failure.fileMissing }
        let target = SidecarStore.sidecarURL(for: photoURL, versionKey: versionKey)
        guard !RenameEngine.itemExists(target) else { throw Failure.versionFileExists }
        switch SidecarStore.read(forPhotoAt: photoURL, versionKey: source.versionKey) {
        case .missing:
            return nil
        case .undecodable:
            throw Failure.sourceEditsUnreadable
        case .decoded(let state):
            try SidecarStore.write(state, forPhotoAt: photoURL, versionKey: versionKey)
            return target
        }
    }
}
