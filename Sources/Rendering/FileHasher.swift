import CryptoKit
import Foundation

/// Streamed SHA-256 of a file's bytes. Reads in fixed chunks through a `FileHandle` — never memory-maps (the same
/// SIGBUS-safety convention as `SourceIntegrity`: a mapped file that shrinks mid-read kills the process).
enum FileHasher {
    static let chunkSize = 1 << 20

    /// Lowercase hex digest, or nil when the file cannot be opened or a read fails.
    ///
    /// `uncached: true` asks the system not to cache this read (`F_NOCACHE`). It does NOT evict pages that are already resident, so on its own it
    /// is not proof of what the disk holds: a Move first calls `flushToDisk` (which is) and uses this read as a second look.
    static func sha256Hex(ofFileAt url: URL, uncached: Bool = false) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        if uncached { _ = fcntl(handle.fileDescriptor, F_NOCACHE, 1) }
        var hasher = SHA256()
        do {
            // `read(upToCount:)` returns nil (not empty data) at end of file; only a THROW is a failed read.
            while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Forces `url`'s data out to the device: `F_FULLFSYNC` (a barrier to permanent storage), else a plain `fsync` where the file system does
    /// not support it (a plain `fsync` does not flush every drive's own write cache: exFAT/FAT cards get the weaker guarantee), then the containing
    /// folder. False when the file itself could not be synced: the caller must treat the copy as NOT durable.
    static func flushToDisk(_ url: URL) -> Bool {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let synced = fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0
        // The new name lives in the folder: sync it too (best effort) so a pulled drive does not lose the directory entry.
        let folderFD = open(url.deletingLastPathComponent().path, O_RDONLY)
        if folderFD >= 0 { _ = fcntl(folderFD, F_FULLFSYNC) == 0 || fsync(folderFD) == 0; close(folderFD) }
        return synced
    }
}
