import Foundation

/// State for the "Find Duplicates…" sheet: runs a cancellable `DuplicateScanner` pass, groups the result, and exposes the
/// groups for review. It never deletes or modifies a photo file; its only effect on the catalog is the Pick/Reject flag
/// (applied by `CatalogModel.setFlagStatus(_:forPhotoIDs:)`) and the fingerprint cache rows the scanner writes.
@MainActor
final class DuplicatesModel: ObservableObject {
    @Published private(set) var isScanning = false
    @Published private(set) var progress: DuplicateScanner.Progress?
    @Published private(set) var groups: [DuplicateGroup] = []
    @Published private(set) var photosByID: [Int64: Photo] = [:]
    @Published private(set) var hasScanned = false
    /// "N skipped" etc. — shown under the results.
    @Published private(set) var summary: String?
    @Published var statusMessage: String?
    @Published var includeSimilarShots = false {
        didSet { if includeSimilarShots != oldValue { regroup() } }
    }

    private var candidates: [DuplicateCandidate] = []
    private var scanTask: Task<Void, Never>?
    private var groupingGeneration = 0
    /// Identifies the current scan; results, progress and cancels from an OLDER scan (a sheet closed and reopened while it
    /// settled) are dropped instead of overwriting the new session.
    private var scanGeneration = 0

    /// Starts a scan (ignored while one is running). Photos are scanned in the order given.
    func scan(photos: [Photo], database: CatalogDatabase) {
        guard !isScanning else { return }
        guard !photos.isEmpty else { statusMessage = "There are no photos to scan."; return }
        isScanning = true
        scanGeneration += 1
        groupingGeneration += 1   // any in-flight regroup belongs to the PREVIOUS scope
        let generation = scanGeneration
        progress = DuplicateScanner.Progress(completed: 0, total: photos.count)
        statusMessage = nil
        summary = nil
        photosByID = Dictionary(photos.compactMap { photo in photo.id.map { ($0, photo) } }, uniquingKeysWith: { first, _ in first })
        let similar = includeSimilarShots
        scanTask = Task { [weak self] in
            let sink = ProgressSink(owner: self, generation: generation)
            let outcome: Result<DuplicateScanner.Result, Error>
            do {
                outcome = .success(try await DuplicateScanner.scan(photos: photos, database: database, progress: { value in sink.report(value) }))
            } catch {
                outcome = .failure(error)
            }
            let groups: [DuplicateGroup]
            if case .success(let result) = outcome {
                groups = await Task.detached(priority: .userInitiated) {
                    DuplicateGrouping.groups(from: result.candidates, includeSimilarShots: similar)
                }.value
            } else {
                groups = []
            }
            self?.finish(outcome, groups: groups, generation: generation)
        }
    }

    fileprivate func setProgress(_ value: DuplicateScanner.Progress, generation: Int) {
        if isScanning, generation == scanGeneration { progress = value }
    }

    /// Stops a running scan. Rows computed so far stay cached, so the next scan resumes; the groups found among the photos
    /// scanned so far are still shown (marked incomplete in the summary).
    func cancel() { scanTask?.cancel() }

    private func finish(_ outcome: Result<DuplicateScanner.Result, Error>, groups found: [DuplicateGroup], generation: Int) {
        guard generation == scanGeneration else { return }   // superseded by clear()/a newer scan
        isScanning = false
        progress = nil
        scanTask = nil
        hasScanned = true
        switch outcome {
        case .failure(let error):
            candidates = []
            groups = []
            statusMessage = "The scan failed: \(error.localizedDescription)"
        case .success(let result):
            candidates = result.candidates
            groups = found
            var parts = ["Scanned \(result.candidates.count) photo\(result.candidates.count == 1 ? "" : "s")."]
            if result.wasCancelled { parts.append("Cancelled — results cover only the photos scanned so far.") }
            if result.skipped > 0 { parts.append("\(result.skipped) skipped (file missing or unreadable).") }
            if result.withoutFeaturePrint > 0 { parts.append("\(result.withoutFeaturePrint) could not be compared by look (exact copies are still found).") }
            summary = parts.joined(separator: " ")
        }
    }

    /// Re-groups the cached candidates (the Similar-shots switch changed). Cheap, off the main thread.
    private func regroup() {
        guard !isScanning, !candidates.isEmpty else { return }
        groupingGeneration += 1
        let generation = groupingGeneration
        let snapshot = candidates
        let similar = includeSimilarShots
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                DuplicateGrouping.groups(from: snapshot, includeSimilarShots: similar)
            }.value
            guard let self, generation == self.groupingGeneration, !self.isScanning else { return }
            self.groups = result
        }
    }

    /// Re-reads each remembered photo's flag/rating from the Library's live copies, so an action never works from the
    /// snapshot taken at scan start (a Pick or un-reject made since is respected).
    func syncFlags(from livePhotos: [Photo]) {
        for photo in livePhotos {
            guard let id = photo.id, photosByID[id] != nil else { continue }
            photosByID[id]?.flagStatus = photo.flagStatus
            photosByID[id]?.rating = photo.rating
        }
    }

    /// Splits `ids` for a "reject" action: photos to reject (only photos this scan knows, currently unflagged) and how many
    /// were left alone because they are Picked. Already-rejected photos need nothing; ids the scan never saw are ignored
    /// (never rejected unseen). A Pick is never silently overwritten: U would set the flag to none, not back to Picked.
    func rejectable(_ ids: [Int64]) -> (reject: [Int64], leftPicked: Int) {
        var reject: [Int64] = [], picked = 0
        for id in ids {
            guard let photo = photosByID[id] else { continue }
            switch photo.flagStatus {
            case .none: reject.append(id)
            case .picked: picked += 1
            case .rejected: break
            }
        }
        return (reject, picked)
    }

    /// Marks `ids` rejected in the model's own copies, so the sheet shows the result without a re-scan.
    func noteRejected(_ ids: Set<Int64>) {
        for id in ids { photosByID[id]?.flagStatus = .rejected }
    }

    /// Forgets everything (a fresh sheet session) and drops any scan still settling: its results will not land. The dropped
    /// scan may still be winding down (reading files, writing cache rows) after `isScanning` reads false; that is only reachable
    /// as the sheet opens, and the open sheet (`duplicatesSheetPresented`) already blocks rename/paste/keywords.
    func clear() {
        scanTask?.cancel()
        scanTask = nil
        scanGeneration += 1
        groupingGeneration += 1
        isScanning = false
        progress = nil
        groups = []; candidates = []; photosByID = [:]; summary = nil; statusMessage = nil; hasScanned = false
    }
}

/// Hands scanner progress (reported from a background task) to the main-actor model without capturing it in a
/// `@Sendable` closure.
private final class ProgressSink: @unchecked Sendable {
    private weak var owner: DuplicatesModel?
    private let generation: Int
    init(owner: DuplicatesModel?, generation: Int) { self.owner = owner; self.generation = generation }
    func report(_ value: DuplicateScanner.Progress) {
        Task { @MainActor [owner, generation] in owner?.setProgress(value, generation: generation) }
    }
}
