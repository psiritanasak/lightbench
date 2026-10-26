import Foundation

/// What the planner needs to know about one photo (a MASTER: virtual copies follow their master and are never candidates).
struct StackCandidate: Equatable, Sendable {
    var id: Int64
    /// Camera wall clock as UTC-digit seconds (`PhotoMetadata.captureDate`); nil or non-finite = never stacked by time.
    var captureDate: Double?
    var featurePrint: [Float]?
    // Rank info, exactly what `DuplicateGrouping.isBetter` reads (the cover is the best member).
    var rating: Int = 0
    var flag: FlagStatus = .none
    var fileSize: Int64 = 0
    var importedAt: Date = Date(timeIntervalSince1970: 0)
    /// Lowercased file name without its extension, and the containing folder: a RAW+JPG pair is the same base name in one folder.
    var baseName: String = ""
    var folder: String = ""

    fileprivate var duplicateCandidate: DuplicateCandidate {
        DuplicateCandidate(id: id, rating: rating, flag: flag, fileSize: fileSize, importedAt: importedAt, contentHash: nil, featurePrint: featurePrint)
    }
}

/// One planned stack: `memberIDs` best first, so the first member is the cover.
struct StackProposal: Equatable, Sendable {
    var memberIDs: [Int64]
    /// The cover (the best member); nil only for an empty proposal, which the planner never produces.
    var coverID: Int64? { memberIDs.first }
}

struct StackPlan: Equatable, Sendable {
    var proposals: [StackProposal] = []
    /// EXACTLY the candidate ids this plan considered (after the caps), ascending. Pass THIS as the scope of
    /// `CatalogDatabase.replaceAutomaticStacks(inScope:with:)`: photos deferred by a cap are not in it, so they keep their existing
    /// automatic stacks instead of being unstacked by a run that never looked at them.
    var plannedIDs: [Int64] = []
    /// Candidates left out of this run because of `maximumCandidatesPerRun`.
    var deferred = 0
    var coveredPhotoCount: Int { proposals.reduce(0) { $0 + $1.memberIDs.count } }
}

/// Pure planner for Auto Stack. No I/O: prints and dates arrive as values, so everything is deterministic and unit-testable.
///
/// 1. A RAW+JPG pair is ONE unit that always stacks together: the same base name in the same folder AND both capture dates known
///    and within `pairGapSeconds` of the bucket's FIRST member (no chaining: files at 0/3/6 s are not one unit). Photos without a
///    capture date are never paired; every other photo is a unit of one.
/// 2. Units with a capture date are walked in (earliest date, smallest id) order. A unit joins the current burst when its gap to the
///    LATEST date of the previous unit is within `maxGapSeconds` (within `maxGapWithoutPrintSeconds` when either side has no usable
///    print; the smaller of the two limits applies) AND, when it has a print, it is within `similarityLimit` of EVERY earlier print in
///    the burst (complete linkage: A~B and B~C never pull C in beside a dissimilar A). Otherwise it starts a new burst. A unit
///    without a capture date, or with a non-finite one, is never put in a burst.
/// 3. Bursts and pairs with two or more photos become proposals; the cover is the best member by `DuplicateGrouping.isBetter`.
///
/// The defaults are by-eye conventions from the duplicate-detection spike (one trip, one JPEG), not validated on bracketed HDR,
/// panorama or portrait series. The result depends only on the SET of candidates (ids break every tie; of two candidates with the
/// same id the one with the earliest capture date, then the smaller file size, import date, name, folder wins).
///
/// THREADING: call this off the main thread (`Task.detached`). The work is linear in the number of candidates apart from the
/// complete-linkage check, which compares a unit with every print already in its burst (each comparison is a 768-float distance), so a
/// burst costs the square of its size; `maximumBurstUnits` and `maximumCandidatesPerRun` bound it, and I have not timed it.
enum StackPlanner {
    struct Params: Equatable, Sendable {
        var maxGapSeconds: Double = 3
        /// Gap allowed when a print is missing on either side (lower confidence: time alone). The smaller of this and `maxGapSeconds` applies.
        var maxGapWithoutPrintSeconds: Double = 1
        /// How close two same-named files of one folder must be in time to count as one shot (a RAW+JPG pair).
        var pairGapSeconds: Double = 1
        var similarityLimit: Float = DuplicateGrouping.similarShotsDistance
        /// Complete linkage is quadratic per burst: a burst never grows beyond this (the next unit starts a new burst).
        var maximumBurstUnits = 200
        /// At most this many candidates are planned per run: the NEWEST (highest ids), so old photos cannot starve new ones.
        var maximumCandidatesPerRun = 20_000
    }

    private struct Unit {
        var members: [StackCandidate]
        var minID: Int64
        var firstDate: Double?
        var lastDate: Double?
        var print: [Float]?
    }

    static func plan(_ input: [StackCandidate], params: Params = Params()) -> StackPlan {
        var candidates = uniqueByID(input)
        var plan = StackPlan()
        if candidates.count > params.maximumCandidatesPerRun {
            plan.deferred = candidates.count - params.maximumCandidatesPerRun
            candidates = Array(candidates.suffix(params.maximumCandidatesPerRun))
        }
        plan.plannedIDs = candidates.map(\.id)

        var proposals: [StackProposal] = []
        var dated: [Unit] = []
        for unit in makeUnits(candidates, params: params) {
            if unit.firstDate == nil {
                if unit.members.count > 1 { proposals.append(proposal(for: unit.members)) }
            } else {
                dated.append(unit)
            }
        }
        dated.sort { ($0.firstDate ?? 0, $0.minID) < ($1.firstDate ?? 0, $1.minID) }

        var burst: [Unit] = []
        func flush() {
            let members = burst.flatMap(\.members)
            if members.count > 1 { proposals.append(proposal(for: members)) }
            burst = []
        }
        for unit in dated {
            if let previous = burst.last, !joins(unit, burst: burst, previous: previous, params: params) { flush() }
            burst.append(unit)
        }
        flush()

        plan.proposals = proposals.sorted { ($0.memberIDs.min() ?? 0) < ($1.memberIDs.min() ?? 0) }
        return plan
    }

    // MARK: - Input

    /// One candidate per id, ascending by id. Of several with the same id the winner does not depend on input order.
    private static func uniqueByID(_ input: [StackCandidate]) -> [StackCandidate] {
        func key(_ c: StackCandidate) -> (Int64, Double, Int64, Double, String, String) {
            (c.id, date(c) ?? .infinity, c.fileSize, c.importedAt.timeIntervalSince1970, c.baseName, c.folder)
        }
        var best: [Int64: StackCandidate] = [:]
        for candidate in input {
            if let current = best[candidate.id], !(key(candidate) < key(current)) { continue }
            best[candidate.id] = candidate
        }
        return best.values.sorted { $0.id < $1.id }
    }

    // MARK: - Units

    private static func makeUnits(_ candidates: [StackCandidate], params: Params) -> [Unit] {
        struct Key: Hashable { var folder: String; var baseName: String }
        var buckets: [Key: [StackCandidate]] = [:]
        var groups: [[StackCandidate]] = []
        for candidate in candidates {
            if candidate.baseName.isEmpty || date(candidate) == nil { groups.append([candidate]) } else {
                buckets[Key(folder: candidate.folder, baseName: candidate.baseName), default: []].append(candidate)
            }
        }
        for bucket in buckets.values {
            // Compare each file with the FIRST of its unit, never with the previous one (no chaining).
            let sorted = bucket.sorted { (date($0) ?? 0, $0.id) < (date($1) ?? 0, $1.id) }
            var current: [StackCandidate] = []
            for candidate in sorted {
                if let anchor = current.first, let a = date(anchor), let b = date(candidate), abs(b - a) > params.pairGapSeconds {
                    groups.append(current)
                    current = []
                }
                current.append(candidate)
            }
            if !current.isEmpty { groups.append(current) }
        }
        return groups.map { members in
            let dates = members.compactMap(date)
            let best = members.sorted { DuplicateGrouping.isBetter($0.duplicateCandidate, than: $1.duplicateCandidate) }
            return Unit(
                members: members, minID: members.map(\.id).min() ?? 0, firstDate: dates.min(), lastDate: dates.max(),
                print: best.first(where: { $0.featurePrint != nil })?.featurePrint
            )
        }
    }

    private static func date(_ candidate: StackCandidate) -> Double? {
        guard let value = candidate.captureDate, value.isFinite else { return nil }
        return value
    }

    // MARK: - Bursts

    private static func joins(_ unit: Unit, burst: [Unit], previous: Unit, params: Params) -> Bool {
        guard burst.count < params.maximumBurstUnits, let date = unit.firstDate, let previousDate = previous.lastDate else { return false }
        let gap = date - previousDate
        let hasPrints = unit.print != nil && previous.print != nil
        guard gap <= (hasPrints ? params.maxGapSeconds : min(params.maxGapSeconds, params.maxGapWithoutPrintSeconds)) else { return false }
        guard let print = unit.print else { return true }
        return burst.allSatisfy { member in
            guard let other = member.print else { return true }
            guard other.count == print.count else { return false } // a different print format is never "similar"
            return FeaturePrintVector.distance(print, other) <= params.similarityLimit
        }
    }

    private static func proposal(for members: [StackCandidate]) -> StackProposal {
        let ordered = members.sorted { DuplicateGrouping.isBetter($0.duplicateCandidate, than: $1.duplicateCandidate) }
        return StackProposal(memberIDs: ordered.map(\.id))
    }
}
