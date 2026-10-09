import Foundation
import GRDB

/// Faces and people (see `Migration013Faces`). Everything here is catalog-only: no file is read or written.
extension CatalogDatabase {
    // MARK: Scans

    /// The scan records for `photoIDs` (absent ids were never scanned). Callers still check `FaceScanRecord.isCurrent`.
    func faceScans(forPhotoIDs photoIDs: [Int64]) async throws -> [Int64: FaceScanRecord] {
        try await dbQueue.read { db in
            var result: [Int64: FaceScanRecord] = [:]
            for start in stride(from: 0, to: photoIDs.count, by: 500) {
                let chunk = Array(photoIDs[start..<min(start + 500, photoIDs.count)])
                for row in try FaceScanRecord.filter(chunk.contains(FaceScanRecord.Columns.photoId)).fetchAll(db) {
                    result[row.photoId] = row
                }
            }
            return result
        }
    }

    /// Saves scan results in one write. For each photo the new faces are matched to its old faces by box overlap
    /// (`FaceMatching`): a matched face is UPDATED in place (keeping its id, its person, `isConfirmed` and its exclusions), an old
    /// face with no match is deleted, a new face with no match is inserted (unassigned). Photos that no longer exist are skipped
    /// instead of tripping the foreign key and aborting the batch.
    func saveFaceScans(_ results: [FaceScanResult]) async throws {
        try await dbQueue.write { db in
            var existing = Set<Int64>()
            let ids = results.map(\.scan.photoId)
            for start in stride(from: 0, to: ids.count, by: 500) {
                let chunk = Array(ids[start..<min(start + 500, ids.count)])
                existing.formUnion(try Int64.fetchAll(db, Photo.filter(chunk.contains(Photo.Columns.id)).select(Photo.Columns.id)))
            }
            for result in results where existing.contains(result.scan.photoId) {
                let photoID = result.scan.photoId
                let old = try Face.filter(Face.Columns.photoId == photoID).fetchAll(db)
                let matches = FaceMatching.match(
                    old: old.map { FaceMatching.Box(x: $0.x, y: $0.y, w: $0.w, h: $0.h) },
                    new: result.faces.map { FaceMatching.Box(x: $0.x, y: $0.y, w: $0.w, h: $0.h) })
                var keptOld = Set<Int>()
                for (index, var face) in result.faces.enumerated() {
                    face.photoId = photoID
                    if let oldIndex = matches[index] {
                        keptOld.insert(oldIndex)
                        face.id = old[oldIndex].id
                        face.personId = old[oldIndex].personId
                        face.isConfirmed = old[oldIndex].isConfirmed
                        try face.update(db)
                    } else {
                        face.id = nil
                        face.personId = nil
                        face.isConfirmed = false
                        try face.insert(db)
                    }
                }
                for (oldIndex, oldFace) in old.enumerated() where !keptOld.contains(oldIndex) {
                    if let id = oldFace.id { _ = try Face.filter(Face.Columns.id == id).deleteAll(db) }
                }
                var scan = result.scan
                scan.faceCount = result.faces.count
                try scan.save(db)
            }
        }
    }

    // MARK: Faces

    func faces(forPhotoID photoID: Int64) async throws -> [Face] {
        try await dbQueue.read { db in try Face.filter(Face.Columns.photoId == photoID).order(Face.Columns.id).fetchAll(db) }
    }

    /// Every face's grouping data (feature prints included, crops NOT: they are the large part). A dedicated type, never a partial
    /// `Face`. ~3 KB per face: the grouping commit decides how much of this it keeps in memory.
    func allFacesForGrouping() async throws -> [FaceGroupingInput] {
        try await dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT id, photoId, personId, isConfirmed, quality, featurePrint FROM face ORDER BY id").map { row in
                FaceGroupingInput(id: row["id"], photoId: row["photoId"], personId: row["personId"], isConfirmed: row["isConfirmed"],
                                  quality: row["quality"], featurePrint: row["featurePrint"])
            }
        }
    }

    func faces(forPersonID personID: Int64, limit: Int = 200) async throws -> [Face] {
        try await dbQueue.read { db in
            try Face.filter(Face.Columns.personId == personID).order(Face.Columns.quality.desc).limit(limit).fetchAll(db)
        }
    }

    /// Faces with no person, best quality first (the "Unsorted faces" tile).
    func unassignedFaces(limit: Int = 200) async throws -> [Face] {
        try await dbQueue.read { db in
            try Face.filter(Face.Columns.personId == nil).order(Face.Columns.quality.desc).limit(limit).fetchAll(db)
        }
    }

    func unassignedFaceCount() async throws -> Int {
        try await dbQueue.read { db in try Face.filter(Face.Columns.personId == nil).fetchCount(db) }
    }

    /// The best crop of a person, for its tile.
    func representativeCrop(forPersonID personID: Int64) async throws -> Data? {
        try await dbQueue.read { db in
            try Data.fetchOne(db, sql: "SELECT crop FROM face WHERE personId = ? AND crop IS NOT NULL ORDER BY quality DESC LIMIT 1", arguments: [personID])
        }
    }

    /// Writes the assignments `FaceGrouping` decided, in ONE transaction. A decision is skipped (never an error) when, since grouping
    /// read its input, the user confirmed the face (`isConfirmed`), marked it "not this person" for that person, or the person is gone
    /// (deleted or merged away) — so a user's action made while grouping ran is never undone and a stale id cannot fail the batch.
    /// A `nil` person takes an unconfirmed face out of its person.
    func applyAutomaticAssignments(_ assignments: [FaceAssignment]) async throws {
        try await dbQueue.write { db in
            _ = try Self.apply(assignments, in: db)
        }
    }

    struct GroupingApplied: Equatable, Sendable {
        /// New people that exist after the write (a group whose faces were all guarded out is not counted).
        var newPeople: Int
        /// Faces whose person actually changed.
        var facesChanged: Int
    }

    /// Applies a `FaceGrouping` plan in ONE transaction: creates the new unnamed people, assigns their faces, applies the other
    /// assignments (with the guards of `apply`), then removes the unnamed, VISIBLE, now-empty people among the ones this plan touched
    /// (the people faces left, and the ones created here). A person the user hid, a named one, and an empty person someone just
    /// created in the UI are never pruned.
    func applyGroupingPlan(_ plan: FaceGrouping.Plan) async throws -> GroupingApplied {
        try await dbQueue.write { db in
            var all = plan.assignments
            var touched = Set<Int64>()
            for assignment in plan.assignments {
                if let old = try Int64.fetchOne(db, sql: "SELECT personId FROM face WHERE id = ?", arguments: [assignment.faceID]) { touched.insert(old) }
            }
            var created: [Int64] = []
            for group in plan.newGroups {
                var person = Person(id: nil, name: nil, nameKey: nil, isHidden: false, createdAt: Date())
                try person.insert(db)
                guard let personID = person.id else { continue }
                created.append(personID)
                touched.insert(personID)
                all.append(contentsOf: group.map { FaceAssignment(faceID: $0, personID: personID) })
            }
            let changed = try Self.apply(all, in: db)
            for personID in touched {
                try db.execute(sql: """
                    DELETE FROM person WHERE id = ? AND name IS NULL AND isHidden = 0
                    AND NOT EXISTS (SELECT 1 FROM face WHERE face.personId = person.id)
                    """, arguments: [personID])
            }
            let surviving = try created.filter { try Person.fetchOne(db, key: $0) != nil }
            return GroupingApplied(newPeople: surviving.count, facesChanged: changed)
        }
    }

    @discardableResult
    static func apply(_ assignments: [FaceAssignment], in db: Database) throws -> Int {
        var changed = 0
        for assignment in assignments {
            if let personID = assignment.personID {
                try db.execute(sql: """
                    UPDATE face SET personId = ?1 WHERE id = ?2 AND isConfirmed = 0 AND personId IS NOT ?1
                    AND EXISTS (SELECT 1 FROM person WHERE id = ?1)
                    AND NOT EXISTS (SELECT 1 FROM face_exclusion WHERE faceId = ?2 AND personId = ?1)
                    """, arguments: [personID, assignment.faceID])
            } else {
                try db.execute(sql: "UPDATE face SET personId = NULL WHERE id = ? AND isConfirmed = 0 AND personId IS NOT NULL", arguments: [assignment.faceID])
            }
            changed += db.changesCount
        }
        return changed
    }

    // MARK: People

    @discardableResult
    func createPerson(name: String? = nil) async throws -> Person {
        try await dbQueue.write { db in
            let display = name.flatMap(KeywordName.normalize)
            var person = Person(id: nil, name: display, nameKey: display.map(KeywordName.key(for:)), isHidden: false, createdAt: Date())
            try person.insert(db)
            return person
        }
    }

    /// People with their face and photo counts, biggest first.
    func peopleSummaries() async throws -> [PersonSummary] {
        try await dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT person.id AS id, person.name AS name, person.isHidden AS isHidden,
                       COUNT(face.id) AS faceCount, COUNT(DISTINCT face.photoId) AS photoCount
                FROM person LEFT JOIN face ON face.personId = person.id
                GROUP BY person.id ORDER BY faceCount DESC, person.id
                """).map { row in
                PersonSummary(id: row["id"], name: row["name"], isHidden: row["isHidden"], faceCount: row["faceCount"], photoCount: row["photoCount"])
            }
        }
    }

    /// Names (or clears the name of) a person. Another person with the same name key is reported, not overwritten.
    func renamePerson(id: Int64, to raw: String?) async throws -> PersonRenameResult {
        try await dbQueue.write { db in
            guard var person = try Person.fetchOne(db, key: id) else { return .notFound }
            guard let display = raw.flatMap(KeywordName.normalize) else {
                person.name = nil
                person.nameKey = nil
                try person.update(db)
                return .cleared
            }
            let key = KeywordName.key(for: display)
            if let other = try Person.filter(Person.Columns.nameKey == key && Person.Columns.id != id).fetchOne(db), let otherID = other.id {
                return .duplicate(existingID: otherID)
            }
            person.name = display
            person.nameKey = key
            try person.update(db)
            return .renamed
        }
    }

    func setPersonHidden(id: Int64, hidden: Bool) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "UPDATE person SET isHidden = ? WHERE id = ?", arguments: [hidden, id])
        }
    }

    /// Deletes a person; its faces become unassigned and unconfirmed (they may be grouped again).
    func deletePerson(id: Int64) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "UPDATE face SET isConfirmed = 0 WHERE personId = ?", arguments: [id])
            _ = try Person.filter(Person.Columns.id == id).deleteAll(db)
        }
    }

    /// Moves every face of `source` to `target` (a user action, so they become confirmed), keeps the "not this person" marks of
    /// `source` for `target` (except for faces now IN `target`), gives `target` the source's name when it has none, then deletes
    /// `source`. Returns how many faces moved.
    @discardableResult
    func mergePeople(source: Int64, into target: Int64) async throws -> Int {
        guard source != target else { return 0 }
        return try await dbQueue.write { db in
            guard try Person.fetchOne(db, key: source) != nil, var targetPerson = try Person.fetchOne(db, key: target) else { return 0 }
            let moved = try Face.filter(Face.Columns.personId == source).fetchCount(db)
            try db.execute(sql: "UPDATE face SET personId = ?, isConfirmed = 1 WHERE personId = ?", arguments: [target, source])
            try db.execute(sql: "INSERT OR IGNORE INTO face_exclusion (faceId, personId) SELECT faceId, ? FROM face_exclusion WHERE personId = ?",
                           arguments: [target, source])
            try db.execute(sql: """
                DELETE FROM face_exclusion WHERE EXISTS
                (SELECT 1 FROM face WHERE face.id = face_exclusion.faceId AND face.personId = face_exclusion.personId)
                """)
            if targetPerson.name == nil, let sourcePerson = try Person.fetchOne(db, key: source), let name = sourcePerson.name {
                // Free the source's key first (UNIQUE), then take it.
                try db.execute(sql: "UPDATE person SET nameKey = NULL WHERE id = ?", arguments: [source])
                targetPerson.name = name
                targetPerson.nameKey = sourcePerson.nameKey
                try targetPerson.update(db)
            }
            _ = try Person.filter(Person.Columns.id == source).deleteAll(db)
            return moved
        }
    }

    // MARK: Assignments and corrections

    /// The user puts `faceIDs` in `personID` (confirmed), or takes them out (`nil`: unassigned, unconfirmed). Putting a face in a
    /// person lifts any "not this person" mark for that pair.
    func assignFaces(_ faceIDs: [Int64], to personID: Int64?) async throws {
        try await dbQueue.write { db in
            for faceID in faceIDs {
                if let personID {
                    try db.execute(sql: "UPDATE face SET personId = ?, isConfirmed = 1 WHERE id = ?", arguments: [personID, faceID])
                    try db.execute(sql: "DELETE FROM face_exclusion WHERE faceId = ? AND personId = ?", arguments: [faceID, personID])
                } else {
                    try db.execute(sql: "UPDATE face SET personId = NULL, isConfirmed = 0 WHERE id = ?", arguments: [faceID])
                }
            }
        }
    }

    /// "Not this person": the face is excluded from `personID` for good (regrouping will not put it back) and, if it is in that
    /// person now, taken out.
    func excludeFace(_ faceID: Int64, fromPerson personID: Int64) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO face_exclusion (faceId, personId) VALUES (?, ?)", arguments: [faceID, personID])
            try db.execute(sql: "UPDATE face SET personId = NULL, isConfirmed = 0 WHERE id = ? AND personId = ?", arguments: [faceID, personID])
        }
    }

    /// face id -> the people it must never be assigned to.
    func faceExclusions() async throws -> [Int64: Set<Int64>] {
        try await dbQueue.read { db in
            var result: [Int64: Set<Int64>] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT faceId, personId FROM face_exclusion") {
                result[row["faceId"], default: []].insert(row["personId"])
            }
            return result
        }
    }

    // MARK: Library filter

    /// photo id -> the people in it (assigned faces only), for the Library's Person filter.
    func personIDsByPhotoID() async throws -> [Int64: Set<Int64>] {
        try await dbQueue.read { db in
            var result: [Int64: Set<Int64>] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT DISTINCT photoId, personId FROM face WHERE personId IS NOT NULL") {
                result[row["photoId"], default: []].insert(row["personId"])
            }
            return result
        }
    }

    /// Deletes people that have no faces and no name (left behind by merges or rescans).
    func pruneEmptyPeople() async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM person WHERE name IS NULL AND id NOT IN (SELECT personId FROM face WHERE personId IS NOT NULL)")
        }
    }
}
