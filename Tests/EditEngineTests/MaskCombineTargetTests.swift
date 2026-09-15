import XCTest
@testable import PhotoApp

/// Verifies `MaskCombineTarget.targets(excluding:in:)` — the one pure
/// helper Phase 7 slice 6's Session B UI adds. The rest of that slice is
/// SwiftUI interaction glue with no unit-test precedent in this codebase
/// (per its own "geometry/pure helpers get tests, gesture/picker
/// composition gets live verification" convention) — this file exists
/// because "the picker's numbering must exactly match
/// `AdjustTabView.maskListRows`' own numbering" is a real cross-file
/// invariant with a real, specific failure mode (see the "does not
/// renumber" test below), not a UI-only concern.
final class MaskCombineTargetTests: XCTestCase {
    private func mask(kind: MaskKind = .radial) -> Mask {
        var mask = Mask()
        mask.kind = kind
        return mask
    }

    func testNumberingMatchesGlobalIndexAcrossMixedKinds() {
        let a = mask(kind: .radial)
        let b = mask(kind: .linear)
        let c = mask(kind: .brush)
        let targets = MaskCombineTarget.targets(excluding: a.id, in: [a, b, c])

        XCTAssertEqual(targets.map(\.label), [
            "Mask 2 — Linear",
            "Mask 3 — Brush",
        ])
    }

    func testExcludedMaskIsAbsentEveryOtherMaskIsPresent() {
        let a = mask()
        let b = mask()
        let c = mask()
        let targets = MaskCombineTarget.targets(excluding: b.id, in: [a, b, c])

        XCTAssertEqual(targets.map(\.id), [a.id, c.id])
    }

    /// The specific bug a naive `filter`-then-`enumerate` would introduce:
    /// excluding Mask 2 of 3 must still label the third mask "Mask 3", not
    /// "Mask 2" — numbering comes from the FULL array's own index, before
    /// the excluded mask is dropped from the result.
    func testNumberingDoesNotRenumberAroundTheExclusion() {
        let a = mask()
        let b = mask()
        let c = mask()
        let targets = MaskCombineTarget.targets(excluding: b.id, in: [a, b, c])

        XCTAssertEqual(targets.map(\.label), ["Mask 1 — Radial", "Mask 3 — Radial"])
    }

    func testEmptyArrayReturnsEmpty() {
        XCTAssertEqual(MaskCombineTarget.targets(excluding: UUID(), in: []), [])
    }

    func testSingleMaskArrayExcludingItselfReturnsEmpty() {
        let a = mask()
        XCTAssertEqual(MaskCombineTarget.targets(excluding: a.id, in: [a]), [])
    }

    /// An id not present in the array (e.g. a stale/already-deleted
    /// caller) is not an error case for this pure function — it simply
    /// excludes nothing, returning every mask.
    func testUnresolvableExcludedIDReturnsEveryMask() {
        let a = mask()
        let b = mask()
        let targets = MaskCombineTarget.targets(excluding: UUID(), in: [a, b])

        XCTAssertEqual(targets.map(\.id), [a.id, b.id])
    }

    func testLabelsCarryTheKindName() {
        let a = mask(kind: .luminanceRange)
        let b = mask(kind: .colorRange)
        let targets = MaskCombineTarget.targets(excluding: UUID(), in: [a, b])

        XCTAssertEqual(targets.map(\.label), [
            "Mask 1 — Luminance Range",
            "Mask 2 — Color Range",
        ])
    }
}
