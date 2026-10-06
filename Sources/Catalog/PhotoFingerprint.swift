import Foundation
import GRDB

/// Cached duplicate-detection data for one photo (see `Migration012PhotoFingerprint`). Two independent, optional
/// payloads — the hash and the feature print are computed at different times — both tied to the file's size and
/// modification time at compute time.
struct PhotoFingerprint: Codable, Equatable, Hashable, Sendable {
    var photoId: Int64
    var fileSize: Int64
    /// `modificationDate.timeIntervalSince1970` when computed.
    var mtime: Double
    /// Lowercase hex SHA-256 of the file's bytes.
    var contentHash: String?
    /// The raw vector of a `VNFeaturePrintObservation` (`.data`). Only the bytes and the request revision are stored;
    /// comparing two prints also needs the element type and count, which the scanner (not this cache) pins — revision
    /// 2 is 768 `Float`s (3,072 bytes, `FeaturePrintProbeTests`) — and treats any mismatch like a revision change.
    var featurePrint: Data?
    var featurePrintRevision: Int?
    /// Informational only. It comes back from the database truncated to milliseconds, so a fetched row does NOT `==`
    /// the row that was saved: never use whole-row equality to decide that nothing changed.
    var computedAt: Date

    /// True while the file still looks exactly as it did when this row was computed. A different size OR a different
    /// modification time (any change, a replaced file, an older restored copy) makes it stale. The database round trip of
    /// a `Double` is exact; the 1 ms tolerance is only defensive, against reading the timestamp through different APIs.
    func isCurrent(fileSize currentSize: Int64, mtime currentMTime: Double) -> Bool {
        fileSize == currentSize && abs(mtime - currentMTime) < 0.001
    }
}

extension PhotoFingerprint: FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "photo_fingerprint"

    enum Columns {
        static let photoId = Column(CodingKeys.photoId)
        static let fileSize = Column(CodingKeys.fileSize)
        static let mtime = Column(CodingKeys.mtime)
        static let contentHash = Column(CodingKeys.contentHash)
        static let featurePrint = Column(CodingKeys.featurePrint)
        static let featurePrintRevision = Column(CodingKeys.featurePrintRevision)
        static let computedAt = Column(CodingKeys.computedAt)
    }
}
