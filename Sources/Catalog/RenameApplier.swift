import Foundation

/// Runs a batch rename (and its Undo) across BOTH halves — the files on disk
/// (`RenameEngine`) and the catalog rows + rename log (`CatalogDatabase`) —
/// so that a failure in either half leaves neither changed.
///
/// Order matters: FILES first, then the catalog. If the catalog transaction
/// then fails, the files are moved back (a second engine pass); if THAT also
/// fails the error says so, because the catalog still holds the old paths
/// while some files sit under new names. The reverse order would leave rows
/// pointing at files that don't exist yet.
///
/// Blocking file I/O: call from a detached task, never the main actor.
enum RenameApplier {
    struct Failure: Error, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// Applies `moves`, returning how many photos were renamed. All-or-nothing.
    static func apply(
        _ moves: [RenameMove],
        database: CatalogDatabase,
        move: RenameEngine.MoveFunction = RenameEngine.exclusiveMove
    ) async throws -> Int {
        guard !moves.isEmpty else { return 0 }
        try RenameEngine.apply(moves, move: move)
        do {
            _ = try await database.renamePhotos(moves)
            return moves.count
        } catch {
            try rollBackFiles(moves, original: error, move: move, catalogListsNewNames: false)
            throw Failure(message: "The catalog couldn't be updated (\(describe(error))). The files were put back — nothing was renamed.")
        }
    }

    /// Undoes the most recent batch: refuses up front if the catalog no longer
    /// matches the log; otherwise moves the files back, then reverts the rows
    /// and deletes the log. Returns how many photos were restored.
    static func undoLast(
        database: CatalogDatabase,
        move: RenameEngine.MoveFunction = RenameEngine.exclusiveMove,
        afterFilesMoved: () async throws -> Void = {}
    ) async throws -> Int {
        guard let log = try await database.lastRenameLog() else { throw RenameCatalogError.noLoggedRename }
        try await database.validateUndo(of: log)
        let inverse = log.moves.map(\.inverse)
        do {
            try RenameEngine.apply(inverse, move: move)
        } catch {
            throw Failure(message: "Couldn't undo the rename: \(describe(error))")
        }
        do {
            // `afterFilesMoved` is a test seam: it runs between the two halves so a test can make the
            // catalog step fail AFTER the files have really moved back.
            try await afterFilesMoved()
            try await database.revertRenameBatch(log)
            return log.moves.count
        } catch {
            try rollBackFiles(inverse, original: error, move: move, catalogListsNewNames: true)
            throw Failure(message: "The catalog couldn't be updated (\(describe(error))). The files were put back under their new names, so the rename is still applied and can be undone again.")
        }
    }

    /// Re-applies the inverse of `moves` to put every file back; if that too
    /// fails, throws a message that says exactly what state things are in.
    /// `catalogListsNewNames` says which way round the catalog is: after a failed
    /// APPLY it still lists the OLD names (files are stuck under the new ones); after
    /// a failed UNDO it still lists the NEW names (files are stuck under the old ones).
    private static func rollBackFiles(
        _ moves: [RenameMove], original: Error, move: RenameEngine.MoveFunction, catalogListsNewNames: Bool
    ) throws {
        do {
            try RenameEngine.apply(moves.map(\.inverse), move: move)
        } catch {
            let state = catalogListsNewNames
                ? "The catalog still lists the NEW names, but the files are back under their OLD names"
                : "The catalog still lists the OLD names, but the files are under their NEW names"
            throw Failure(message: "The catalog couldn't be updated (\(describe(original))) AND the files couldn't be put back (\(describe(error))). \(state), so use Locate… to re-link any photo shown as missing.")
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}
