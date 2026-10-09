import Foundation

/// State for the People sheet: runs the cancellable face scan, regroups every stored face, and exposes people and their faces for
/// review and correction. Everything is on-device and catalog-only: it reads photo files and writes only catalog rows. It never
/// modifies a photo file or a sidecar.
@MainActor
final class FacesModel: ObservableObject {
    enum Selection: Hashable {
        case person(Int64)
        case unsorted
    }

    @Published private(set) var isWorking = false
    @Published private(set) var progress: FaceScanner.Progress?
    @Published private(set) var phase = ""
    @Published private(set) var summary: String?
    @Published var statusMessage: String?
    @Published private(set) var people: [PersonSummary] = []
    @Published private(set) var unsortedCount = 0
    /// person id -> the best face crop (JPEG) for its tile.
    @Published private(set) var tileCrops: [Int64: Data] = [:]
    @Published var selection: Selection? {
        didSet { if selection != oldValue { selectedFaces = []; Task { await reloadSelectedFaces() } } }
    }
    @Published private(set) var selectedFaces: [Face] = []

    var database: CatalogDatabase?
    /// Called after the model changed people (so the Library's own people list and filter refresh).
    var onPeopleChanged: () -> Void = {}
    /// Injected in tests (no files, no Vision).
    var scannerEnvironment = FaceScanner.Environment.live
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
            case nil: loaded = []
            }
        } catch {
            loaded = []
        }
        if selection == requested { selectedFaces = loaded }
    }

    // MARK: Scan + group

    /// Finds faces in `photos` (skipping the ones already scanned and unchanged), then regroups all stored faces. Ignored while
    /// running. A cancel keeps what was found and still groups it.
    func scanAndGroup(photos: [Photo], database: CatalogDatabase) {
        guard !isWorking else { return }
        guard !photos.isEmpty else { statusMessage = "There are no photos to scan."; return }
        isWorking = true
        generation += 1
        let mine = generation
        progress = FaceScanner.Progress(completed: 0, total: photos.count)
        phase = "Looking for faces…"
        statusMessage = nil
        summary = nil
        let environment = scannerEnvironment
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
        await perform { _ = try await $0.mergePeople(source: source, into: target) }
    }

    func setHidden(_ id: Int64, _ hidden: Bool) async { await perform { try await $0.setPersonHidden(id: id, hidden: hidden) } }

    func delete(_ id: Int64) async {
        await perform { try await $0.deletePerson(id: id) }
        if selection == .person(id) { selection = nil }
    }

    func notThisPerson(_ faceID: Int64, from personID: Int64) async { await perform { try await $0.excludeFace(faceID, fromPerson: personID) } }

    func assign(_ faceIDs: [Int64], to personID: Int64?) async { await perform { try await $0.assignFaces(faceIDs, to: personID) } }

    /// "New person" for faces the grouping left alone: creates an unnamed person and puts the faces in it (confirmed).
    func assignToNewPerson(_ faceIDs: [Int64]) async {
        await perform { database in
            let person = try await database.createPerson()
            try await database.assignFaces(faceIDs, to: person.id)
        }
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
