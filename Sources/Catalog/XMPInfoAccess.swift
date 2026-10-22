import Foundation
import GRDB

/// SEAM between the XMP code and the catalog's Info storage (slice A owns the `photo_info` table; this file deliberately
/// knows nothing about it). `CatalogDatabase.applyLibraryFields` calls these INSIDE its own write transaction, so a read and
/// the write that follows it see the same rows. The real implementation must resolve a virtual copy to its master
/// (Info belongs to the photograph) and normalise stored text through the Info text rules (`InfoText`); a nil access means
/// "ignore Info values found in files".
struct XMPInfoAccess: Sendable {
    /// The photo's current Info; an unknown id returns an empty `PhotoInfo`.
    var load: @Sendable (Database, Int64) throws -> PhotoInfo
    /// Stores the full new Info for the photo.
    var store: @Sendable (Database, Int64, PhotoInfo) throws -> Void
}
