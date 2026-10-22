import Foundation
import GRDB

/// Photo stacks (`Migration017PhotoStacks`). Rules shared by every write here:
/// - ONE write transaction per call; ids are resolved to MASTER photos (a virtual copy's id means its master), ids that no longer
///   exist are skipped, lookups are chunked at 500 ids;
/// - a photo belongs to at most one stack, so putting a photo in a stack takes it out of any other one;
/// - a stack with fewer than two members does not exist: a database TRIGGER deletes it the moment it drops below two, whatever
///   removed the member (these writes or a photo deletion). A stack whose cover left it has no cover (nil);
/// - touching a stack by hand (add, remove, set cover, or taking its members for another stack) makes it manual, and a manual stack
///   is never changed by `replaceAutomaticStacks`;
/// - UNSTACK IS REMEMBERED: `dissolveStack` and `removeFromStack` are USER actions and record their photos in `photo_stack_exclusion`;
///   automatic runs (and `createStack(manual: false)`) never stack an excluded photo; a manual `createStack` / `addToStack` clears the
///   exclusion of the photos it stacks; `clearStackExclusions()` forgets them all (for a "reset" in the Auto Stack sheet).
extension CatalogDatabase {
    // MARK: Reading

    /// Every stack with its member ids (masters), ordered by stack id.
    func allStacks() async throws -> [StackSnapshot] {
        try await dbQueue.read { db in
            var members: [Int64: [Int64]] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT photoId, stackId FROM photo_stack_member ORDER BY photoId") {
                members[row["stackId"], default: []].append(row["photoId"])
            }
            return try PhotoStack.order(PhotoStack.Columns.id).fetchAll(db).compactMap { stack in
                guard let id = stack.id else { return nil }
                return StackSnapshot(id: id, isManual: stack.isManual, coverPhotoID: stack.coverPhotoId, memberIDs: members[id] ?? [])
            }
        }
    }

    /// The photos (masters) the user unstacked and automatic runs therefore skip.
    func stackExclusions() async throws -> Set<Int64> {
        try await dbQueue.read { db in Set(try Int64.fetchAll(db, sql: "SELECT photoId FROM photo_stack_exclusion")) }
    }

    /// Forgets every remembered unstack.
    func clearStackExclusions() async throws {
        try await dbQueue.write { db in try db.execute(sql: "DELETE FROM photo_stack_exclusion") }
    }

    // MARK: Manual writes

    /// Stacks the masters of `photoIDs` (at least two must exist, else nothing happens and nil is returned). `cover` (resolved to its
    /// master) must be one of the members, else the stack has no explicit cover. `manual: true` is a user action: it takes photos out
    /// of other stacks (touching them) and clears the photos' exclusions. `manual: false` is for planners: a photo already in a MANUAL
    /// stack, or excluded, is skipped instead. Returns the new stack's id.
    @discardableResult
    func createStack(photoIDs: [Int64], manual: Bool, cover: Int64? = nil) async throws -> Int64? {
        try await dbQueue.write { db in
            var masters = try Self.masterIDs(db, photoIDs)
            if !manual {
                let skipped = try Self.manualStackMembers(db, among: masters).union(Self.excluded(db, among: masters))
                masters.removeAll { skipped.contains($0) }
            }
            guard masters.count >= 2 else { return nil }
            let coverMaster = try cover.flatMap { try Self.masterIDs(db, [$0]).first }.flatMap { masters.contains($0) ? $0 : nil }
            if manual { try Self.clearExclusions(db, masters) }
            return try Self.insertStack(db, members: masters, manual: manual, cover: coverMaster, touchOthers: manual)
        }
    }

    /// Adds the masters of `photoIDs` to `stackID` (a photo already in another stack moves here; that stack is touched). The stack
    /// becomes manual and the photos' exclusions are cleared. Returns how many photos were added; 0 when the stack is gone.
    @discardableResult
    func addToStack(stackID: Int64, photoIDs: [Int64]) async throws -> Int {
        try await dbQueue.write { db in
            guard try PhotoStack.fetchOne(db, key: stackID) != nil else { return 0 }
            let current = Set(try Self.members(db, ofStack: stackID))
            let masters = try Self.masterIDs(db, photoIDs).filter { !current.contains($0) }
            guard !masters.isEmpty else { return 0 }
            try Self.detach(db, masters, touch: true)
            // Detaching can dissolve the target itself only if it had < 2 members, which cannot exist; re-check anyway.
            guard try PhotoStack.fetchOne(db, key: stackID) != nil else { return 0 }
            try Self.clearExclusions(db, masters)
            for master in masters {
                try PhotoStackMember(photoId: master, stackId: stackID, addedManually: true).insert(db)
            }
            try Self.setManual(db, [stackID])
            return masters.count
        }
    }

    /// USER ACTION. Takes the masters of `photoIDs` out of whatever stacks they are in (those stacks become manual; one left with fewer
    /// than two members is dissolved) and remembers them as unstacked. Returns how many photos left a stack.
    @discardableResult
    func removeFromStack(photoIDs: [Int64]) async throws -> Int {
        try await dbQueue.write { db in
            let removed = try Self.detach(db, try Self.masterIDs(db, photoIDs), touch: true)
            try Self.recordExclusions(db, removed)
            return removed.count
        }
    }

    /// Makes the master of `photoID` the cover of `stackID` and the stack manual. False (nothing changed) when it is not a member.
    @discardableResult
    func setCover(stackID: Int64, photoID: Int64) async throws -> Bool {
        try await dbQueue.write { db in
            guard let master = try Self.masterIDs(db, [photoID]).first,
                  try PhotoStackMember.fetchOne(db, key: master)?.stackId == stackID else { return false }
            try db.execute(sql: "UPDATE photo_stack SET coverPhotoId = ?, isManual = 1 WHERE id = ?", arguments: [master, stackID])
            return true
        }
    }

    /// USER ACTION. Deletes the stack (its members stay as ordinary photos) and remembers them as unstacked, so an automatic run does
    /// not rebuild it.
    func dissolveStack(stackID: Int64) async throws {
        try await dbQueue.write { db in
            try Self.recordExclusions(db, try Self.members(db, ofStack: stackID))
            _ = try PhotoStack.deleteOne(db, key: stackID)
        }
    }

    // MARK: Automatic run

    /// Replaces the automatic stacks inside `scope` with `proposals`, in ONE transaction.
    ///
    /// `scope` MUST be the photos the planner actually looked at: pass `StackPlan.plannedIDs`, NOT the whole shown set. Photos the
    /// planner deferred (its caps) are outside the scope and so keep their existing automatic stacks. Virtual copies resolve to masters.
    ///
    /// Existing AUTOMATIC stacks lose their in-scope members (a stack left with fewer than two is dissolved by the trigger; out-of-scope
    /// members stay put); MANUAL stacks are never changed and their members are excluded from the new stacks, as are photos the user
    /// unstacked. A proposal keeps only in-scope, existing, not-already-placed members (the first proposal wins a photo), is dropped
    /// below two members, and keeps its planned cover when that survives, else its best remaining member (proposals list members best
    /// first). Returns how many stacks were created.
    @discardableResult
    func replaceAutomaticStacks(inScope scope: [Int64], with proposals: [StackProposal]) async throws -> Int {
        try await dbQueue.write { db in
            let scoped = try Self.masterIDs(db, scope)
            let scopedSet = Set(scoped)
            let locked = try Self.manualStackMembers(db, among: scoped).union(Self.excluded(db, among: scoped))
            var automatic: [Int64] = []
            for chunk in Self.chunks(scoped) {
                automatic += try Int64.fetchAll(db, sql: """
                    SELECT m.photoId FROM photo_stack_member m JOIN photo_stack s ON s.id = m.stackId
                    WHERE s.isManual = 0 AND m.photoId IN (\(Self.marks(chunk.count)))
                    """, arguments: StatementArguments(chunk))
            }
            try Self.detach(db, automatic, touch: false)

            var placed = locked
            var created = 0
            for proposal in proposals {
                var members: [Int64] = []
                for id in try Self.masterIDsPreservingOrder(db, proposal.memberIDs)
                where scopedSet.contains(id) && !placed.contains(id) && !members.contains(id) {
                    members.append(id)
                }
                guard members.count >= 2 else { continue }
                let cover = proposal.coverID.flatMap { members.contains($0) ? $0 : nil } ?? members.first
                try Self.insertStack(db, members: members, manual: false, cover: cover, touchOthers: false)
                placed.formUnion(members)
                created += 1
            }
            return created
        }
    }

    // MARK: - Transaction helpers

    @discardableResult
    private static func insertStack(_ db: Database, members: [Int64], manual: Bool, cover: Int64?, touchOthers: Bool) throws -> Int64 {
        try detach(db, members, touch: touchOthers)
        var stack = PhotoStack(id: nil, isManual: manual, coverPhotoId: cover, createdAt: Date())
        try stack.insert(db)
        guard let id = stack.id else { throw CatalogDatabaseError(message: "insert(db) did not assign stack.id") }
        for member in members {
            try PhotoStackMember(photoId: member, stackId: id, addedManually: manual).insert(db)
        }
        return id
    }

    /// Removes the memberships of `photos` (already masters), optionally making their stacks manual, then clears covers that left.
    /// (A stack left with fewer than two members is deleted by the trigger.) Returns the photos that actually left a stack.
    @discardableResult
    private static func detach(_ db: Database, _ photos: [Int64], touch: Bool) throws -> [Int64] {
        var affected = Set<Int64>()
        var removed: [Int64] = []
        for chunk in chunks(photos) {
            let list = marks(chunk.count)
            let rows = try Row.fetchAll(db, sql: "SELECT photoId, stackId FROM photo_stack_member WHERE photoId IN (\(list))", arguments: StatementArguments(chunk))
            if rows.isEmpty { continue }
            let stackIDs = Set(rows.map { $0["stackId"] as Int64 })
            // Touch BEFORE deleting: the trigger may dissolve a stack as the last of its members go.
            if touch { try setManual(db, Array(stackIDs)) }
            try db.execute(sql: "DELETE FROM photo_stack_member WHERE photoId IN (\(list))", arguments: StatementArguments(chunk))
            affected.formUnion(stackIDs)
            removed += rows.map { $0["photoId"] as Int64 }
        }
        try clearVanishedCovers(db, stackIDs: Array(affected))
        return removed
    }

    private static func setManual(_ db: Database, _ stackIDs: [Int64]) throws {
        for chunk in chunks(stackIDs) {
            try db.execute(sql: "UPDATE photo_stack SET isManual = 1 WHERE id IN (\(marks(chunk.count)))", arguments: StatementArguments(chunk))
        }
    }

    /// Clears a cover that is no longer a member of its stack.
    private static func clearVanishedCovers(_ db: Database, stackIDs: [Int64]) throws {
        for chunk in chunks(stackIDs) {
            try db.execute(sql: """
                UPDATE photo_stack SET coverPhotoId = NULL WHERE id IN (\(marks(chunk.count))) AND coverPhotoId IS NOT NULL
                AND NOT EXISTS (SELECT 1 FROM photo_stack_member WHERE photoId = photo_stack.coverPhotoId AND stackId = photo_stack.id)
                """, arguments: StatementArguments(chunk))
        }
    }

    private static func recordExclusions(_ db: Database, _ photos: [Int64]) throws {
        for photo in photos {
            try db.execute(sql: "INSERT OR REPLACE INTO photo_stack_exclusion (photoId, createdAt) VALUES (?, ?)", arguments: [photo, Date()])
        }
    }

    private static func clearExclusions(_ db: Database, _ photos: [Int64]) throws {
        for chunk in chunks(photos) {
            try db.execute(sql: "DELETE FROM photo_stack_exclusion WHERE photoId IN (\(marks(chunk.count)))", arguments: StatementArguments(chunk))
        }
    }

    private static func excluded(_ db: Database, among photos: [Int64]) throws -> Set<Int64> {
        var result = Set<Int64>()
        for chunk in chunks(photos) {
            result.formUnion(try Int64.fetchAll(db, sql: "SELECT photoId FROM photo_stack_exclusion WHERE photoId IN (\(marks(chunk.count)))", arguments: StatementArguments(chunk)))
        }
        return result
    }

    private static func members(_ db: Database, ofStack id: Int64) throws -> [Int64] {
        try Int64.fetchAll(db, sql: "SELECT photoId FROM photo_stack_member WHERE stackId = ? ORDER BY photoId", arguments: [id])
    }

    private static func manualStackMembers(_ db: Database, among photos: [Int64]) throws -> Set<Int64> {
        var result = Set<Int64>()
        for chunk in chunks(photos) {
            result.formUnion(try Int64.fetchAll(db, sql: """
                SELECT m.photoId FROM photo_stack_member m JOIN photo_stack s ON s.id = m.stackId
                WHERE s.isManual = 1 AND m.photoId IN (\(marks(chunk.count)))
                """, arguments: StatementArguments(chunk)))
        }
        return result
    }

    /// The distinct, existing MASTER ids of `ids` (a copy resolves to its master), ascending.
    private static func masterIDs(_ db: Database, _ ids: [Int64]) throws -> [Int64] {
        Array(Set(try masterIDsPreservingOrder(db, ids))).sorted()
    }

    /// Like `masterIDs` but keeps the order of `ids` (duplicates possible; stale ids dropped).
    private static func masterIDsPreservingOrder(_ db: Database, _ ids: [Int64]) throws -> [Int64] {
        var masterOf: [Int64: Int64] = [:]
        for chunk in chunks(Array(Set(ids))) {
            for photo in try Photo.filter(chunk.contains(Photo.Columns.id)).fetchAll(db) {
                if let id = photo.id { masterOf[id] = photo.masterId ?? id }
            }
        }
        // A copy whose master row is gone cannot be stacked.
        let known = Set(try existing(db, Array(Set(masterOf.values))))
        return ids.compactMap { masterOf[$0] }.filter { known.contains($0) }
    }

    private static func existing(_ db: Database, _ ids: [Int64]) throws -> [Int64] {
        var result: [Int64] = []
        for chunk in chunks(ids) { result += try Int64.fetchAll(db, Photo.filter(chunk.contains(Photo.Columns.id)).select(Photo.Columns.id)) }
        return result
    }

    private static func chunks(_ ids: [Int64]) -> [[Int64]] {
        stride(from: 0, to: ids.count, by: 500).map { Array(ids[$0..<min($0 + 500, ids.count)]) }
    }

    private static func marks(_ count: Int) -> String { Array(repeating: "?", count: count).joined(separator: ",") }
}
