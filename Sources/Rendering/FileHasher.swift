import CryptoKit
import Foundation

/// Streamed SHA-256 of a file's bytes. Reads in fixed chunks through a `FileHandle` — never memory-maps (the same
/// SIGBUS-safety convention as `SourceIntegrity`: a mapped file that shrinks mid-read kills the process).
enum FileHasher {
    static let chunkSize = 1 << 20

    /// Lowercase hex digest, or nil when the file cannot be opened or a read fails.
    static func sha256Hex(ofFileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
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
}
