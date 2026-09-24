import XCTest
@testable import PhotoApp

/// Pure logic — no file I/O, no `@MainActor`, no security-scoped bookmark
/// in sight — matching `CompareLayoutTests`' own precedent for testing a
/// `Sources/UI` helper type's pure math/decision logic directly.
final class PasteSettingsPlanTests: XCTestCase {
    private func photo(id: Int64, path: String) -> Photo {
        Photo(id: id, path: path, filename: (path as NSString).lastPathComponent, fileSize: nil, importedAt: Date())
    }

    // MARK: - make: splitting out the open photo

    func testMakeSplitsOutTheOpenPhotoByPath() {
        let open = photo(id: 1, path: "/photos/A/open.jpg")
        let other = photo(id: 2, path: "/photos/A/other.jpg")

        let plan = PasteSettingsPlan.make(targets: [open, other], openPhotoPath: open.path)

        XCTAssertEqual(plan.openPhoto, open)
        XCTAssertEqual(plan.byFolder.flatMap(\.photos), [other])
    }

    func testMakeLeavesOpenPhotoNilWhenOpenPathIsNotAmongTargets() {
        let a = photo(id: 1, path: "/photos/A/a.jpg")
        let b = photo(id: 2, path: "/photos/A/b.jpg")

        let plan = PasteSettingsPlan.make(targets: [a, b], openPhotoPath: "/photos/A/not-a-target.jpg")

        XCTAssertNil(plan.openPhoto)
        // Order within a group follows `targets`' own order (insertion
        // order into the per-folder bucket), so a plain array comparison
        // is exact here, not just a set-membership check.
        XCTAssertEqual(plan.byFolder.flatMap(\.photos), [a, b])
    }

    func testMakeLeavesOpenPhotoNilWhenOpenPhotoPathIsNil() {
        let a = photo(id: 1, path: "/photos/A/a.jpg")

        let plan = PasteSettingsPlan.make(targets: [a], openPhotoPath: nil)

        XCTAssertNil(plan.openPhoto)
        XCTAssertEqual(plan.byFolder.flatMap(\.photos), [a])
    }

    // MARK: - make: grouping by folder

    func testMakeGroupsTargetsByDirectParentFolder() {
        let a1 = photo(id: 1, path: "/photos/A/1.jpg")
        let a2 = photo(id: 2, path: "/photos/A/2.jpg")
        let b1 = photo(id: 3, path: "/photos/B/1.jpg")

        let plan = PasteSettingsPlan.make(targets: [a1, a2, b1], openPhotoPath: nil)

        XCTAssertEqual(plan.byFolder.count, 2)
        XCTAssertEqual(plan.byFolder.first { $0.folder == "/photos/A" }?.photos, [a1, a2])
        XCTAssertEqual(plan.byFolder.first { $0.folder == "/photos/B" }?.photos, [b1])
    }

    func testMakeGroupOrderIsDeterministicallySortedByFolder() {
        let z = photo(id: 1, path: "/photos/Z/z.jpg")
        let a = photo(id: 2, path: "/photos/A/a.jpg")
        let m = photo(id: 3, path: "/photos/M/m.jpg")

        let plan = PasteSettingsPlan.make(targets: [z, a, m], openPhotoPath: nil)

        XCTAssertEqual(plan.byFolder.map(\.folder), ["/photos/A", "/photos/M", "/photos/Z"])
    }

    // MARK: - Plan.allFolders

    func testAllFoldersIncludesTheOpenPhotosFolderOnlyOnce() {
        let open = photo(id: 1, path: "/photos/A/open.jpg")
        let other = photo(id: 2, path: "/photos/A/other.jpg")
        let elsewhere = photo(id: 3, path: "/photos/B/x.jpg")

        let plan = PasteSettingsPlan.make(targets: [open, other, elsewhere], openPhotoPath: open.path)

        // "/photos/A" appears once even though it's both the open photo's
        // own folder AND a byFolder group's folder.
        XCTAssertEqual(plan.allFolders.filter { $0 == "/photos/A" }.count, 1)
        XCTAssertTrue(plan.allFolders.contains("/photos/B"))
    }

    func testAllFoldersOmitsTheOpenPhotosFolderWhenThereIsNoOpenPhoto() {
        let a = photo(id: 1, path: "/photos/A/a.jpg")
        let plan = PasteSettingsPlan.make(targets: [a], openPhotoPath: nil)
        XCTAssertEqual(plan.allFolders, ["/photos/A"])
    }

    // MARK: - decide

    func testDecideOnAMissingSidecarWithAnIdentityShapedMergeIsUnchanged() {
        // Copying an untouched photo's (identity) look onto an untouched
        // target (.missing, i.e. no sidecar) must not create a phantom
        // sidecar.
        let decision = PasteSettingsPlan.decide(source: .identity, existing: .missing)
        XCTAssertEqual(decision, .unchanged)
    }

    func testDecideOnAMissingSidecarWithANonIdentityMergeWrites() {
        var source = EditState.identity
        source.exposureEV = 1.0

        let decision = PasteSettingsPlan.decide(source: source, existing: .missing)

        guard case .write(let merged) = decision else {
            return XCTFail("expected .write")
        }
        XCTAssertEqual(merged.exposureEV, 1.0)
    }

    func testDecideOnADecodedSidecarThatWouldNotChangeIsUnchanged() {
        var existing = EditState.identity
        existing.exposureEV = 1.0
        // Pasting the SAME source the target already effectively has
        // (after the merge) must be a true no-op — e.g. pasting a photo's
        // own copied settings back onto itself.
        var source = EditState.identity
        source.exposureEV = 1.0

        let decision = PasteSettingsPlan.decide(source: source, existing: .decoded(existing))
        XCTAssertEqual(decision, .unchanged)
    }

    func testDecideOnADecodedSidecarThatWouldChangeWrites() {
        var existing = EditState.identity
        existing.exposureEV = 0.0
        var source = EditState.identity
        source.exposureEV = 2.0

        let decision = PasteSettingsPlan.decide(source: source, existing: .decoded(existing))

        guard case .write(let merged) = decision else {
            return XCTFail("expected .write")
        }
        XCTAssertEqual(merged.exposureEV, 2.0)
    }

    func testDecideOnAnUndecodableSidecarNeverWrites() {
        // The core data-loss guard: an existing sidecar this process
        // couldn't parse must NEVER be silently overwritten, regardless of
        // what the source would otherwise produce.
        var source = EditState.identity
        source.exposureEV = 3.0

        let decision = PasteSettingsPlan.decide(source: source, existing: .undecodable)
        XCTAssertEqual(decision, .undecodable)
    }

    /// Integration-style: confirms a target's own crop/masks/
    /// `rawDecoderVersionPin` survive a paste untouched — the full field
    /// partition itself stays covered by `EditStatePresetTests.swift`
    /// (which this reuses `applyingPreset(onto:)` from unchanged); this
    /// just pins that `decide`'s own merge preserves that partition too,
    /// not just the tone/color fields exercised above.
    func testDecideDoesNotTouchGeometryMasksOrRawDecoderPinOnTheTarget() {
        var existing = EditState.identity
        existing.cropInsetLeft = 0.1
        existing.masks = [Mask(centerX: 0.5, centerY: 0.5, radiusX: 0.2, radiusY: 0.2, exposureEV: 0.5)]
        existing.rawDecoderVersionPin = "pinned-version"

        var source = EditState.identity
        source.exposureEV = 1.0

        guard case .write(let merged) = PasteSettingsPlan.decide(source: source, existing: .decoded(existing)) else {
            return XCTFail("expected .write")
        }
        XCTAssertEqual(merged.cropInsetLeft, existing.cropInsetLeft)
        XCTAssertEqual(merged.masks, existing.masks)
        XCTAssertEqual(merged.rawDecoderVersionPin, existing.rawDecoderVersionPin)
        XCTAssertEqual(merged.exposureEV, 1.0)
    }
}
