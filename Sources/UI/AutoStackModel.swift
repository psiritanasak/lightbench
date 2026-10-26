import Foundation

/// State for the "Auto Stack…" sheet: gathers the camera data and feature prints of the photos the Library shows, plans the stacks OFF
/// the main thread (`StackPlanner`), shows a PREVIEW, and writes nothing until `apply`. Manual stacks and photos the user unstacked are
/// never touched (the database enforces it; the preview leaves them out too so it never promises more than Apply delivers).
///
/// What a run may change (its SCOPE = `StackPlan.plannedIDs`): only photos it could really examine. Photos without a capture date (they
/// are never stacked by time) and photos whose file could not be read (offline volume, no access) are left out of the scope, so their
/// existing automatic stacks are kept instead of being dissolved by a run that never looked at them.
///
/// Apply writes only a plan the user PREVIEWED: the plan remembers the gap it was made for, and `canApply` is false while the gap on
/// screen differs from it or a re-plan is pending.
///
/// The scan reuses `DuplicateScanner` for the cached, cancellable feature prints. Stacking needs prints only, so its `hash` step is
/// a no-op here. The scanner environment, the planner and the database write are injectable, so tests never touch Vision, files or a clock.
@MainActor
final class AutoStackModel: ObservableObject {
    /// The longest gap the sheet offers; the planner's own default is 3.
    nonisolated static let gapRange: ClosedRange<Double> = 1...10
    nonisolated static let defaultGap: Double = 3

    struct Preview: Equatable {
        var stackCount: Int
        var photoCount: Int
        /// Photos left out of this run by the planner's candidate cap.
        var deferred: Int
        /// Existing AUTOMATIC stacks Apply will take photos out of (they are replaced by the new ones).
        var replacedStacks: Int
        /// Existing automatic stacks left completely alone because not all their photos were examined (a filter, a folder boundary, the
        /// per-run cap, an undated / unreadable / print-less member).
        var keptStacks: Int = 0
    }

    /// Replaceable collaborators (tests).
    struct Seams {
        var environment: DuplicateScanner.Environment
        /// MUST be called off the main thread by the model; tests record where it ran.
        var plan: @Sendable ([StackCandidate], StackPlanner.Params) -> StackPlan
        /// Fingerprint cache writer; `nil` = the real database.
        var persist: (@Sendable ([PhotoFingerprint]) async throws -> Void)?
        /// The database write of Apply.
        var apply: @Sendable (CatalogDatabase, StackPlan) async throws -> Int

        /// Stat + feature print only: the stacking never needs a content hash.
        static let live = Seams(
            environment: DuplicateScanner.Environment(
                stat: DuplicateScanner.Environment.live.stat,
                hash: { _ in nil },
                featurePrint: DuplicateScanner.Environment.live.featurePrint
            ),
            plan: { StackPlanner.plan($0, params: $1) },
            persist: nil,
            apply: { database, plan in try await database.replaceAutomaticStacks(inScope: plan.plannedIDs, with: plan.proposals) }
        )
    }

    @Published private(set) var isScanning = false
    @Published private(set) var isApplying = false
    /// A re-plan for a changed gap is running; Apply waits for it.
    @Published private(set) var isReplanning = false
    @Published private(set) var progress: DuplicateScanner.Progress?
    @Published private(set) var preview: Preview?
    @Published private(set) var scopeCount = 0
    /// The photos the Library shows (originals), counted ONCE when the sheet opens or a scan starts, not on every redraw.
    @Published var shownCount = 0
    /// Photos the shown set holds that this run could not look at: no capture date / file not readable. Their stacks are kept.
    @Published private(set) var undatedCount = 0
    @Published private(set) var unreadableCount = 0
    /// Photos left out of the scope because the user unstacked them earlier / a manual stack holds them.
    @Published private(set) var skippedUnstacked = 0
    @Published private(set) var skippedManual = 0
    @Published var statusMessage: String?
    @Published var maxGapSeconds: Double = AutoStackModel.defaultGap {
        didSet {
            let clamped = min(max(maxGapSeconds, Self.gapRange.lowerBound), Self.gapRange.upperBound)
            if clamped != maxGapSeconds { maxGapSeconds = clamped; return }
            if maxGapSeconds != oldValue { replan() }
        }
    }

    var seams = Seams.live
    /// How many photos one run examines (the NEWEST by id): applied HERE, before planning, so the scope and the proposals agree.
    var candidateCap = StackPlanner.Params().maximumCandidatesPerRun
    var isWorking: Bool { isScanning || isApplying }
    /// The gap the adopted plan was made for.
    private(set) var plannedGap: Double?
    /// Apply is offered only for the plan the user is looking at: the gap on screen is the plan's gap and no re-plan is pending.
    var canApply: Bool {
        !isWorking && !isReplanning && plan != nil && plannedGap == maxGapSeconds && (preview?.stackCount ?? 0) > 0
    }

    private var scanTask: Task<Void, Never>?
    private var candidates: [StackCandidate] = []
    private var plan: StackPlan?
    /// The automatic stacks that existed when the scan started (members), for the "replaces N" count.
    private var automaticStacks: [Set<Int64>] = []
    /// Photos left out of this run by `candidateCap`.
    private var cappedCount = 0
    private var keptStackCount = 0
    private var generation = 0
    private var planGeneration = 0

    // MARK: Scan and plan

    /// Starts the scan of `photos` (the Library's shown photos; copies are left out). Ignored while a scan or an apply runs.
    func begin(photos: [Photo], metadata: [Int64: PhotoMetadata], database: CatalogDatabase) {
        guard !isWorking else { return }
        let masters = photos.filter { !$0.isVirtualCopy && $0.id != nil }
        guard !masters.isEmpty else { statusMessage = "There are no photos to stack."; return }
        generation += 1
        let run = generation
        isScanning = true
        isReplanning = false
        preview = nil
        plan = nil
        plannedGap = nil
        statusMessage = nil
        progress = DuplicateScanner.Progress(completed: 0, total: masters.count)
        let seams = self.seams
        let gap = maxGapSeconds // the gap the user saw when pressing Scan; a later change is planned again in `finish`
        let cap = candidateCap
        shownCount = masters.count
        scanTask = Task { [weak self] in
            // What an automatic run may not touch: manual stacks and photos the user unstacked.
            let state = await Self.stackState(database)
            let usable = masters.filter { photo in
                photo.id.map { !state.manual.contains($0) && !state.unstacked.contains($0) } ?? false
            }
            // A photo without a usable capture date can never be stacked by time: it is not scanned and not in the scope.
            let dated = usable.filter { photo in photo.id.flatMap { metadata[$0]?.captureDate }.map(\.isFinite) ?? false }
            let sink = ProgressSink(owner: self, generation: run)
            var scanned: DuplicateScanner.Result?
            var failure: Error?
            do {
                scanned = try await DuplicateScanner.scan(
                    photos: dated, database: database, environment: seams.environment, persist: seams.persist,
                    progress: { sink.report($0) }
                )
            } catch {
                failure = error
            }
            // A photo the scanner could not stat (offline, missing, no access) was not examined: out of the scope too.
            let examined = Set((scanned?.candidates ?? []).map(\.id))
            let readable = dated.filter { $0.id.map(examined.contains) ?? false }
            let all = Self.candidates(photos: readable, metadata: metadata, scan: scanned)
            // The scope is what a run FULLY examined: an existing automatic stack with any member not examined is left alone entirely.
            let shownIDs = Set(masters.compactMap(\.id))
            let scoped = Self.examinedScope(candidates: all, automatic: state.automatic, shownIDs: shownIDs, cap: cap)
            let built = scoped.candidates
            var cancelled = scanned?.wasCancelled == true || Task.isCancelled
            var planned: StackPlan?
            if failure == nil && !cancelled {
                planned = await Task.detached(priority: .userInitiated) { seams.plan(built, StackPlanner.Params(maxGapSeconds: gap, maximumCandidatesPerRun: max(cap, built.count))) }.value
                // Cancelled (or the sheet closed) while the plan was being built: no preview may appear.
                if Task.isCancelled { cancelled = true; planned = nil }
            }
            self?.finish(
                run: run, candidates: built, plan: planned, gap: gap, scopeCount: masters.count,
                kept: scoped.keptStacks, capped: scoped.capped, cancelled: cancelled,
                undated: usable.count - dated.count, unreadable: dated.count - readable.count,
                skippedManual: masters.filter { $0.id.map(state.manual.contains) ?? false }.count,
                skippedUnstacked: masters.filter { $0.id.map { state.unstacked.contains($0) && !state.manual.contains($0) } ?? false }.count,
                automatic: state.automatic, scan: scanned, failure: failure
            )
        }
    }

    func cancel() { scanTask?.cancel() }

    /// Forgets everything (a fresh sheet session) and drops a scan still settling: its result will not land. REFUSED while an Apply is
    /// writing: the write is not cancellable, and the Library refresh that follows it must always happen.
    func clear() {
        guard !isApplying else { return }
        scanTask?.cancel()
        scanTask = nil
        generation += 1
        planGeneration += 1
        isScanning = false
        isReplanning = false
        progress = nil
        preview = nil
        plan = nil
        plannedGap = nil
        candidates = []
        automaticStacks = []
        cappedCount = 0
        keptStackCount = 0
        scopeCount = 0
        undatedCount = 0
        unreadableCount = 0
        skippedManual = 0
        skippedUnstacked = 0
        statusMessage = nil
        maxGapSeconds = Self.defaultGap
    }

    fileprivate func setProgress(_ value: DuplicateScanner.Progress, generation run: Int) {
        if isScanning, run == generation { progress = value }
    }

    private func finish(
        run: Int, candidates built: [StackCandidate], plan planned: StackPlan?, gap: Double, scopeCount count: Int,
        kept: Int, capped: Int, cancelled: Bool,
        undated: Int, unreadable: Int, skippedManual manual: Int, skippedUnstacked unstacked: Int,
        automatic: [Set<Int64>], scan: DuplicateScanner.Result?, failure: Error?
    ) {
        guard run == generation else { return }
        isScanning = false
        progress = nil
        scanTask = nil
        scopeCount = count
        undatedCount = undated
        unreadableCount = unreadable
        skippedManual = manual
        skippedUnstacked = unstacked
        candidates = built
        automaticStacks = automatic
        keptStackCount = kept
        cappedCount = capped
        if let failure {
            statusMessage = "The scan failed: \(failure.localizedDescription)"
            return
        }
        if cancelled {
            statusMessage = "Cancelled. Nothing was changed."
            return
        }
        guard let planned else { return }
        adopt(planned, gap: gap)
        if let scan, scan.withoutFeaturePrint > 0 {
            statusMessage = "\(scan.withoutFeaturePrint) photo\(scan.withoutFeaturePrint == 1 ? "" : "s") could not be compared by look (most often the app has no access to their folder, or the file is not an image); those stack only when taken within a second of a neighbour."
        }
        // The stepper moved while the scan or the first plan ran: plan again for what is on screen, never drop the change.
        if maxGapSeconds != gap { replan() }
    }

    private func adopt(_ planned: StackPlan, gap: Double) {
        plan = planned
        plannedGap = gap
        let scope = Set(planned.plannedIDs)
        let replaced = automaticStacks.filter { !$0.isDisjoint(with: scope) }.count
        preview = Preview(
            stackCount: planned.proposals.count, photoCount: planned.coveredPhotoCount, deferred: planned.deferred + cappedCount,
            replacedStacks: replaced, keptStacks: keptStackCount
        )
    }

    /// Re-plans the scanned photos for the gap on screen. Cheap, off the main thread; a result for an older gap or session is dropped.
    /// Apply is unavailable until it lands (`isReplanning`).
    private func replan() {
        guard !isScanning, !isApplying, !candidates.isEmpty, preview != nil else { return }
        planGeneration += 1
        let token = planGeneration
        let run = generation
        let snapshot = candidates
        let gap = maxGapSeconds
        let planner = seams.plan
        isReplanning = true
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { planner(snapshot, StackPlanner.Params(maxGapSeconds: gap)) }.value
            guard let self, token == self.planGeneration, run == self.generation, !self.isScanning, !self.isApplying else { return }
            self.adopt(result, gap: gap)
            self.isReplanning = false
        }
    }

    // MARK: Apply

    /// Writes the previewed stacks (replacing the previous AUTOMATIC stacks among the planned photos), then ALWAYS calls `completion`
    /// (the Library refresh), also when the write failed. `isApplying` stays true until the completion has finished, so every busy flag
    /// holds for the whole write and refresh. Returns the number of stacks created, or nil when nothing was applied.
    @discardableResult
    func apply(database: CatalogDatabase, completion: @MainActor () async -> Void = {}) async -> Int? {
        guard !isWorking, let plan else { return nil }
        guard canApply else {
            statusMessage = "The gap changed: wait for the preview to update, then press Apply."
            return nil
        }
        isApplying = true
        var created: Int?
        do {
            created = try await seams.apply(database, plan)
            self.plan = nil
            plannedGap = nil
            preview = nil
            candidates = []
            statusMessage = created == 0
                ? "No stacks were created."
                : "Created \(created ?? 0) stack\(created == 1 ? "" : "s"). Manual stacks and unstacked photos were left alone. Expanded stacks collapse after a run (the stacks are recreated)."
        } catch {
            statusMessage = "Couldn't apply the stacks: \(error.localizedDescription)"
        }
        await completion()
        isApplying = false
        return created
    }

    /// Forgets which photos the user unstacked, in the WHOLE library (not only the photos shown), so a later run may stack them again.
    func forgetUnstacked(database: CatalogDatabase) async {
        do {
            try await database.clearStackExclusions()
            skippedUnstacked = 0
            statusMessage = "Forgot every unstacked photo in the whole library: the next Auto Stack run may stack them again."
        } catch {
            statusMessage = "Couldn't forget the unstacked photos: \(error.localizedDescription)"
        }
    }

    // MARK: Building the planner input

    nonisolated private static func stackState(_ database: CatalogDatabase) async -> (manual: Set<Int64>, unstacked: Set<Int64>, automatic: [Set<Int64>]) {
        let stacks = (try? await database.allStacks()) ?? []
        let manual = Set(stacks.filter(\.isManual).flatMap(\.memberIDs))
        let automatic = stacks.filter { !$0.isManual }.map { Set($0.memberIDs) }
        let unstacked = (try? await database.stackExclusions()) ?? []
        return (manual, unstacked, automatic)
    }

    /// The part of `candidates` this run FULLY examined, as the set the planner and Apply may touch.
    ///
    /// 1. The cap: only the newest `cap` candidates by id (the planner's own rule), applied here so the scope and the proposals agree.
    /// 2. A candidate counts as examined when it has a feature print, or when it is in NO existing automatic stack (a photo without a print
    ///    stays a time-only candidate only then; one that IS in an automatic stack cannot be judged).
    /// 3. An existing automatic stack with any member not examined (hidden by a filter, outside the shown folder, capped, undated, unreadable,
    ///    print-less) is left COMPLETELY alone: its examined members are removed from the candidates too, so `replaceAutomaticStacks` can never
    ///    detach them. `keptStacks` counts only those that touch the shown photos.
    nonisolated static func examinedScope(
        candidates: [StackCandidate], automatic: [Set<Int64>], shownIDs: Set<Int64>, cap: Int
    ) -> (candidates: [StackCandidate], keptStacks: Int, capped: Int) {
        let sorted = candidates.sorted { $0.id < $1.id }
        let capped = max(0, sorted.count - cap)
        let capCandidates = Array(sorted.suffix(max(cap, 0)))
        let inAutomatic = Set(automatic.flatMap { $0 })
        var examined = Set(capCandidates.filter { $0.featurePrint != nil || !inAutomatic.contains($0.id) }.map(\.id))
        var kept = 0
        for members in automatic where !members.isSubset(of: examined) {
            if !members.isDisjoint(with: shownIDs) { kept += 1 }
            examined.subtract(members)
        }
        return (capCandidates.filter { examined.contains($0.id) }, kept, capped)
    }

    /// Planner candidates for `photos`: rank info from the photo, time from the cached camera data, print from the scan.
    nonisolated static func candidates(photos: [Photo], metadata: [Int64: PhotoMetadata], scan: DuplicateScanner.Result?) -> [StackCandidate] {
        let scanned = Dictionary(uniqueKeysWithValues: (scan?.candidates ?? []).map { ($0.id, $0) })
        return photos.compactMap { photo in
            guard let id = photo.id else { return nil }
            let url = URL(fileURLWithPath: photo.path)
            return StackCandidate(
                id: id, captureDate: metadata[id]?.captureDate, featurePrint: scanned[id]?.featurePrint,
                rating: photo.rating, flag: photo.flagStatus, fileSize: scanned[id]?.fileSize ?? photo.fileSize ?? 0,
                importedAt: photo.importedAt,
                baseName: url.deletingPathExtension().lastPathComponent.lowercased(),
                folder: url.deletingLastPathComponent().path
            )
        }
    }
}

/// Hands scanner progress (reported from a background task) to the main-actor model without capturing it in a `@Sendable` closure.
private final class ProgressSink: @unchecked Sendable {
    private weak var owner: AutoStackModel?
    private let generation: Int
    init(owner: AutoStackModel?, generation: Int) { self.owner = owner; self.generation = generation }
    func report(_ value: DuplicateScanner.Progress) {
        Task { @MainActor [owner, generation] in owner?.setProgress(value, generation: generation) }
    }
}
