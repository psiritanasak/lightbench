import Foundation
import GRDB

/// A group of faces the user can name (see `Migration013Faces`). Automatically found people start with no name.
struct Person: Codable, Equatable, Identifiable, Hashable, Sendable {
    var id: Int64?
    var name: String?
    /// `KeywordName.key(for: name)`: what makes two spellings the same person; `nil` while unnamed.
    var nameKey: String?
    var isHidden: Bool = false
    var createdAt: Date
}

/// One detected face. `x`, `y`, `w`, `h` are fractions of the ORIENTED image with the origin at the TOP-left.
struct Face: Codable, Equatable, Identifiable, Hashable, Sendable {
    var id: Int64?
    var photoId: Int64
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    /// `VNDetectFaceCaptureQualityRequest`'s score, 0...1.
    var quality: Double
    var detectRevision: Int
    var printRevision: Int
    /// The feature print of the padded face crop (`FeaturePrintGenerator`: 768 floats).
    var featurePrint: Data
    /// A small JPEG of the crop for tiles.
    var crop: Data?
    var personId: Int64?
    /// True when the USER assigned (or confirmed) this face's person: regrouping never changes it.
    var isConfirmed: Bool = false
}

/// "This photo was scanned for faces" (so photos with none are not rescanned), trusted only while the file and both revisions match.
struct FaceScanRecord: Codable, Equatable, Hashable, Sendable {
    var photoId: Int64
    var fileSize: Int64
    var mtime: Double
    var detectRevision: Int
    var printRevision: Int
    var faceCount: Int
    /// Informational; comes back from the database truncated to milliseconds, so never compare whole rows.
    var scannedAt: Date

    func isCurrent(fileSize currentSize: Int64, mtime currentMTime: Double, detectRevision: Int, printRevision: Int) -> Bool {
        fileSize == currentSize && abs(mtime - currentMTime) < 0.001
            && self.detectRevision == detectRevision && self.printRevision == printRevision
    }
}

/// A scanned photo's result, saved together.
struct FaceScanResult: Sendable {
    var scan: FaceScanRecord
    var faces: [Face]
}

/// What `FaceGrouping` needs from a face — a dedicated type, not a partial `Face`, so no half-loaded row can be saved back (and
/// erase its crop).
struct FaceGroupingInput: Equatable, Sendable {
    var id: Int64
    var photoId: Int64
    var personId: Int64?
    var isConfirmed: Bool
    var quality: Double
    var featurePrint: Data
}

/// One automatic grouping decision: put the face in a person, or (nil) take an UNCONFIRMED face out of its person.
struct FaceAssignment: Equatable, Sendable {
    var faceID: Int64
    var personID: Int64?
}

/// What the People list shows for one person.
struct PersonSummary: Equatable, Identifiable, Sendable {
    var id: Int64
    var name: String?
    var isHidden: Bool
    var faceCount: Int
    var photoCount: Int
}

enum PersonRenameResult: Equatable, Sendable {
    case renamed
    case cleared
    /// Another person already has that name (its id): the caller offers to merge instead.
    case duplicate(existingID: Int64)
    case notFound
}

extension Person: FetchableRecord, MutablePersistableRecord, TableRecord {
    static let databaseTableName = "person"
    enum Columns {
        static let id = Column(CodingKeys.id)
        static let name = Column(CodingKeys.name)
        static let nameKey = Column(CodingKeys.nameKey)
        static let isHidden = Column(CodingKeys.isHidden)
        static let createdAt = Column(CodingKeys.createdAt)
    }
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension Face: FetchableRecord, MutablePersistableRecord, TableRecord {
    static let databaseTableName = "face"
    enum Columns {
        static let id = Column(CodingKeys.id)
        static let photoId = Column(CodingKeys.photoId)
        static let personId = Column(CodingKeys.personId)
        static let isConfirmed = Column(CodingKeys.isConfirmed)
        static let quality = Column(CodingKeys.quality)
    }
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension FaceScanRecord: FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "face_scan"
    enum Columns {
        static let photoId = Column(CodingKeys.photoId)
    }
}

/// Matches a rescanned photo's new faces to the faces it had before, by box overlap, so a re-scan (the file changed, a newer
/// detector) KEEPS each face's row — and with it the person the user assigned and the "not this person" marks.
enum FaceMatching {
    struct Box: Equatable {
        var x: Double, y: Double, w: Double, h: Double
    }

    /// Intersection over union of two boxes, 0 when they do not touch.
    static func iou(_ a: Box, _ b: Box) -> Double {
        let ix = max(0, min(a.x + a.w, b.x + b.w) - max(a.x, b.x))
        let iy = max(0, min(a.y + a.h, b.y + b.h) - max(a.y, b.y))
        let inter = ix * iy
        let union = a.w * a.h + b.w * b.h - inter
        return union > 0 ? inter / union : 0
    }

    /// For each NEW box, the index of the OLD box it continues (greedy by highest overlap, each old box used once, overlap at least
    /// `minimumIOU`), or `nil` for a face that is new.
    static func match(old: [Box], new: [Box], minimumIOU: Double = 0.5) -> [Int?] {
        var pairs: [(newIndex: Int, oldIndex: Int, iou: Double)] = []
        for (n, nb) in new.enumerated() {
            for (o, ob) in old.enumerated() {
                let value = iou(nb, ob)
                if value >= minimumIOU { pairs.append((n, o, value)) }
            }
        }
        pairs.sort { $0.iou > $1.iou }
        var result = [Int?](repeating: nil, count: new.count)
        var usedOld = Set<Int>()
        for pair in pairs where result[pair.newIndex] == nil && !usedOld.contains(pair.oldIndex) {
            result[pair.newIndex] = pair.oldIndex
            usedOld.insert(pair.oldIndex)
        }
        return result
    }
}
