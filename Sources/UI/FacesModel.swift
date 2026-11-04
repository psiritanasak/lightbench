import Foundation

/// State for the People sheet: runs the cancellable face scan, regroups every stored face, and exposes people and their faces for
/// review and correction. Everything is on-device and catalog-only: it reads photo files and writes only catalog rows. It never
/// modifies a photo file or a sidecar.
@MainActor
final class FacesModel: ObservableObject {
    enum Selection: Hashable {
        case person(Int64)
        case unsorted
        /// Faces only the optional small-face pass found, not given to anyone yet. Never grouped automatically.
        case smallFaces
    }

    @Published private(set) var isWorking = false
    @Published private(set) var progress: FaceScanner.Progress?
    @Published private(set) var phase = ""
    @Published private(set) var summary: String?
    @Published var statusMessage: String?
    @Published private(set) var people: [PersonSummary] = []
    @Published private(set) var unsortedCount = 0
    @Published private(set) var smallFaceCount = 0
    /// The "Also find small faces (slower)" option; every change is written straight to `AppPreferences`.
    @Published var findSmallFaces: Bool = AppPreferences.shared.findSmallFaces {
        didSet { if findSmallFaces != oldValue { AppPreferences.shared.findSmallFaces = findSmallFaces } }
    }
    /// person id -> the best face crop (JPEG) for its tile.
    @Published private(set) var tileCrops: [Int64: Data] = [:]
    @Published var selection: Selection? {
        didSet { if selection != oldValue { selectedFaces = []; markedFaceIDs = []; Task { await reloadSelectedFaces() } } }
    }
    @Published private(set) var selectedFaces: [Face] = []
    /// Faces the user has ticked in the grid; an action then applies to all of them. Always a subset of `selectedFaces`.
    @Published private(set) var markedFaceIDs: Set<Int64> = []
    /// Whether the last assignment (`assign` / `assignToNewPerson`) can still be undone.
    @Published private(set) var canUndoAssignment = false
    /// A Select Similar comparison is running (tests wait on it to change the selection mid-flight).
    @Published private(set) var isSelectingSimilar = false
    /// Tests only: awaited while a Select Similar comparison counts as running, to hold it open deterministically.
    var selectSimilarGate: (() async -> Void)?
    private var lastAssignment: FaceAssignmentUndo?
    /// An assignment or undo is running: another one is ignored until it finishes (two overlapping ones could not both be undone correctly).
    private var assignmentBusy = false
    /// Bumped by every `forgetLastAssignment()`: an assignment that was still running when something forgot (a not-this-person, a merge, a
    /// delete, `clear()`, a scan) must not store its undo afterwards.
    private var undoEpoch = 0

    var database: CatalogDatabase?
    /// Called after the model changed people (so the Library's own people list and filter refresh).
    var onPeopleChanged: () -> Void = {}
    /// Injected in tests (no files, no Vision). `nil` = the real scanner, with the small-face option as set.
    var scannerEnvironment: FaceScanner.Environment?
    var effectiveScannerEnvironment: FaceScanner.Environment { scannerEnvironment ?? .live(includeSmall: findSmallFaces) }
    var thresholds = FaceGrouping.Thresholds()

    private var task: Task<Void, Never>?
    private var generation = 0

    // MARK: Loading

    /// Re-reads people, counts and tile crops from the catalog.
    func reload() async {
        guard let database else { return }
        do {
            let loaded = try await database.peopleSummaries()
            var crops: [Int64: Data] = [:]
            for person in loaded { if let crop = try await database.representativeCrop(forPersonID: person.id) { crops[person.id] = crop } }
            people = loaded
            tileCrops = crops
            unsortedCount = try await database.unassignedFaceCount()
            smallFaceCount = try await database.smallFaceCount()
            if case .person(let id)? = selection, !loaded.contains(where: { $0.id == id }) { selection = nil }
            await reloadSelectedFaces()
        } catch {
            statusMessage = "Couldn't read people: \(error.localizedDescription)"
        }
    }

    private func reloadSelectedFaces() async {
        guard let database else { selectedFaces = []; return }
        // A slower, older load must not land under a newer selection (the grid's menu would act on the wrong person's faces).
        let requested = selection
        var loaded: [Face] = []
        do {
            switch requested {
            case .person(let id)?: loaded = try await database.faces(forPersonID: id)
            case .unsorted?: loaded = try await database.unassignedFaces()
            case .smallFaces?: loaded = try await database.smallFaces()
            case nil: loaded = []
            }
        } catch {
            loaded = []
        }
        if selection == requested {
            selectedFaces = loaded
            // A face that left the list (assigned away, a rescan) must not stay marked: an action would act on it unseen.
            markedFaceIDs.formIntersection(Set(loaded.compactMap(\.id)))
        }
    }

    // MARK: Marking

    func toggleMark(_ faceID: Int64) {
        guard selectedFaces.contains(where: { $0.id == faceID }) else { return }
        if markedFaceIDs.contains(faceID) { markedFaceIDs.remove(faceID) } else { markedFaceIDs.insert(faceID) }
    }

    func markAllShown() { markedFaceIDs = Set(selectedFaces.compactMap(\.id)) }

    /// Ticks every SHOWN face that looks like a ticked one (nearest ticked face within the strength's limit). It only ticks: nothing is
    /// assigned, so a wrong match costs one click. Faces beyond the shown 200 are not searched. Needs at least one ticked face; a result for
    /// a selection that changed meanwhile is dropped.
    func selectSimilar(strength: FaceSimilarityStrength) async {
        let references = selectedFaces.filter { $0.id.map(markedFaceIDs.contains) ?? false }.map(\.featurePrint)
        guard !references.isEmpty else { return }
        let requested = selection
        let candidates = selectedFaces.compactMap { face in face.id.map { FaceSimilarity.Candidate(id: $0, featurePrint: face.featurePrint) } }
        let limit = strength.limit
        isSelectingSimilar = true
        defer { isSelectingSimilar = false }
        await selectSimilarGate?()
        let result = await Task.detached(priority: .userInitiated) {
            FaceSimilarity.similar(references: references, candidates: candidates, limit: limit)
        }.value
        guard selection == requested else { return }
        let shown = Set(selectedFaces.compactMap(\.id))
        let before = markedFaceIDs
        markedFaceIDs.formUnion(result.matches.filter(shown.contains))
        let added = markedFaceIDs.count - before.count
        if result.referencesWithoutPrint == references.count {
            statusMessage = "The selected faces have no face print to compare. Scan them again with “Also find small faces” on."
        } else if added > 0 {
            statusMessage = "Selected \(added) similar face\(added == 1 ? "" : "s")." + (result.withoutPrint > 0 ? " \(result.withoutPrint) could not be compared (no face print)." : "")
        } else {
            statusMessage = "No other similar faces among the \(shown.count) shown." + (result.withoutPrint > 0 ? " \(result.withoutPrint) could not be compared (no face print)." : "")
        }
    }

    func clearMarks() { markedFaceIDs = [] }

    /// The marked faces in the order the grid shows them.
    var markedInShownOrder: [Int64] { selectedFaces.compactMap(\.id).filter { markedFaceIDs.contains($0) } }

    /// The faces an action on `faceID` applies to (see `FaceMarking.targets`).
    func targets(for faceID: Int64) -> [Int64] {
        FaceMarking.targets(clicked: faceID, marked: markedFaceIDs, shownOrder: selectedFaces.compactMap(\.id))
    }

    // MARK: Scan + group

    /// Finds faces in `photos` (skipping the ones already scanned and unchanged), then regroups all stored faces. Ignored while
    /// running. A cancel keeps what was found and still groups it.
    func scanAndGroup(photos: [Photo], database: CatalogDatabase) {
        guard !isWorking else { return }
        guard !photos.isEmpty else { statusMessage = "There are no photos to scan."; return }
        isWorking = true
        forgetLastAssignment()   // a scan regroups faces: a snapshot taken before it could undo the regrouping too
        generation += 1
        let mine = generation
        progress = FaceScanner.Progress(completed: 0, total: photos.count)
        phase = "Looking for faces…"
        statusMessage = nil
        summary = nil
        let environment = effectiveScannerEnvironment
        let thresholds = thresholds
        task = Task { [weak self] in
            let sink = FaceProgressSink(owner: self, generation: mine)
            var scan: FaceScanner.Result?
            var failure: String?
            do {
                scan = try await FaceScanner.scan(photos: photos, database: database, environment: environment, progress: { sink.report($0) })
            } catch {
                failure = "The scan failed: \(error.localizedDescription)"
            }
            var applied: CatalogDatabase.GroupingApplied?
            if failure == nil {
                await MainActor.run { if let self, self.generation == mine { self.phase = "Grouping faces…" } }
                do {
                    // The plan is computed off the main thread and applied from a task that is NOT cancelled (a cancelled GRDB write throws).
                    applied = try await Task.detached(priority: .userInitiated) {
                        let faces = try await database.allFacesForGrouping()
                        let exclusions = try await database.faceExclusions()
                        let plan = FaceGrouping.plan(faces: faces, exclusions: exclusions, thresholds: thresholds)
                        return try await database.applyGroupingPlan(plan)
                    }.value
                } catch {
                    failure = "Grouping failed: \(error.localizedDescription)"
                }
            }
            await self?.finish(scan: scan, applied: applied, failure: failure, generation: mine)
        }
    }

    fileprivate func setProgress(_ value: FaceScanner.Progress, generation: Int) {
        if isWorking, generation == self.generation { progress = value }
    }

    func cancel() { task?.cancel() }

    private func finish(scan: FaceScanner.Result?, applied: CatalogDatabase.GroupingApplied?, failure: String?, generation: Int) async {
        guard generation == self.generation else { return }
        forgetLastAssignment()   // grouping was just applied: an assignment made while the scan ran must not be undone over it
        isWorking = false
        progress = nil
        phase = ""
        task = nil
        if let failure { statusMessage = failure }
        if let scan {
            var parts = ["Looked at \(scan.scanned - scan.alreadyCurrent) new or changed photo\(scan.scanned - scan.alreadyCurrent == 1 ? "" : "s") (\(scan.alreadyCurrent) already done), found \(scan.facesFound) face\(scan.facesFound == 1 ? "" : "s")."]
            if let applied, applied.newPeople > 0 { parts.append("\(applied.newPeople) new \(applied.newPeople == 1 ? "person" : "people").") }
            if scan.wasCancelled { parts.append("Cancelled — faces found so far were kept.") }
            if scan.skipped > 0 { parts.append("\(scan.skipped) skipped (file missing or unreadable).") }
            if scan.undecodable > 0 { parts.append("\(scan.undecodable) could not be read — most often the app has no access to their folder (import it again) or the file is not an image.") }
            summary = parts.joined(separator: " ")
        }
        await reload()
        onPeopleChanged()
    }

    /// Forgets the review state for a fresh sheet session (does not touch stored faces). A scan that is still running (or winding
    /// down after Done) is NOT forgotten: its task, generation and `isWorking` stay, so a second scan cannot overlap it, rename stays
    /// blocked, and its `finish` still reloads and tells the Library. The reopened sheet simply shows its progress.
    func clear() {
        if !isWorking {
            progress = nil
            phase = ""
            summary = nil
        }
        statusMessage = nil
        selection = nil
        selectedFaces = []
        markedFaceIDs = []
        forgetLastAssignment()
    }

    // MARK: Corrections (each one reloads and tells the Library)

    private func perform(_ work: (CatalogDatabase) async throws -> Void) async {
        guard let database else { return }
        do { try await work(database) } catch { statusMessage = "That didn't work: \(error.localizedDescription)" }
        await reload()
        onPeopleChanged()
    }

    /// Names a person. A name another person already has is reported (the caller can offer to merge).
    func rename(_ id: Int64, to name: String) async -> PersonRenameResult? {
        guard let database else { return nil }
        var result: PersonRenameResult?
        do { result = try await database.renamePerson(id: id, to: name) } catch { statusMessage = "That didn't work: \(error.localizedDescription)" }
        await reload()
        onPeopleChanged()
        return result
    }

    func merge(_ source: Int64, into target: Int64) async {
        // Move the selection to the target BEFORE the reload (which drops a selection on a person that no longer exists).
        if selection == .person(source) { selection = .person(target) }
        forgetLastAssignment()
        await perform { _ = try await $0.mergePeople(source: source, into: target) }
    }

    func setHidden(_ id: Int64, _ hidden: Bool) async { await perform { try await $0.setPersonHidden(id: id, hidden: hidden) } }

    func delete(_ id: Int64) async {
        forgetLastAssignment()
        await perform { try await $0.deletePerson(id: id) }
        if selection == .person(id) { selection = nil }
    }

    func notThisPerson(_ faceID: Int64, from personID: Int64) async { await notThisPerson([faceID], from: personID) }

    /// "Not this person" for several faces at once (one reload). It becomes the last action, so an earlier assignment can no longer be
    /// undone over it (`forgetLastAssignment`); it is not undoable itself.
    func notThisPerson(_ faceIDs: [Int64], from personID: Int64) async {
        forgetLastAssignment()
        markedFaceIDs.subtract(faceIDs)
        await perform { database in for id in faceIDs { try await database.excludeFace(id, fromPerson: personID) } }
    }

    func assign(_ faceIDs: [Int64], to personID: Int64?) async {
        await assignmentPerform(faceIDs) { try await $0.assignFacesRecordingUndo(faceIDs, to: personID) }
    }

    /// "New person" for faces the grouping left alone: creates an unnamed person and puts the faces in it (confirmed).
    func assignToNewPerson(_ faceIDs: [Int64]) async {
        await assignmentPerform(faceIDs) { try await $0.assignFacesRecordingUndo(faceIDs, to: nil, toNewPerson: true) }
    }

    /// Runs an assignment (its undo information is read in the same transaction) and remembers it for `undoLastAssignment`. A failed
    /// assignment keeps the previous undo state; one that arrives while another is running is ignored. The marks are cleared (the faces
    /// move away).
    private func assignmentPerform(_ faceIDs: [Int64], _ work: (CatalogDatabase) async throws -> FaceAssignmentUndo) async {
        guard let database, !assignmentBusy else { return }
        assignmentBusy = true
        defer { assignmentBusy = false }
        let epoch = undoEpoch
        do {
            let undo = try await work(database)
            if epoch == undoEpoch { lastAssignment = undo; canUndoAssignment = true }
        } catch {
            statusMessage = "That didn't work: \(error.localizedDescription)"
        }
        markedFaceIDs.subtract(faceIDs)
        await reload()
        onPeopleChanged()
    }

    /// Puts the faces of the last `assign` / `assignToNewPerson` back (their person, their confirmation and the "not this person" marks
    /// the assignment removed) and removes an unnamed person the assignment created, if it is still empty. One level; cleared by the next assignment, a
    /// "not this person", a scan, a merge, a delete and `clear()`.
    func undoLastAssignment() async {
        guard let undo = lastAssignment, !assignmentBusy else { return }
        assignmentBusy = true
        defer { assignmentBusy = false }
        forgetLastAssignment()
        await perform { database in
            try await database.restoreFaceAssignments(undo)
        }
    }

    private func forgetLastAssignment() {
        undoEpoch += 1
        lastAssignment = nil
        canUndoAssignment = false
    }
}

/// Hands scanner progress (reported from a background task) to the main-actor model without capturing it in a `@Sendable` closure.
private final class FaceProgressSink: @unchecked Sendable {
    private weak var owner: FacesModel?
    private let generation: Int
    init(owner: FacesModel?, generation: Int) { self.owner = owner; self.generation = generation }
    func report(_ value: FaceScanner.Progress) {
        Task { @MainActor [owner, generation] in owner?.setProgress(value, generation: generation) }
    }
}
