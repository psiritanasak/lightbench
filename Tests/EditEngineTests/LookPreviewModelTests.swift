import CoreImage
import XCTest
@testable import PhotoApp

/// `LookPreviewModel` with injected `makeBase`/`render`: scheduling, keys, staleness and base sharing — no Core Image rendering.
@MainActor
final class LookPreviewModelTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _states: [EditState] = []
        private var _bases = 0
        private var _released = 0
        private var _mainThreadRenders = 0
        var renderDelay: TimeInterval = 0
        var failBase = false
        func record(_ s: EditState) {
            lock.lock(); _states.append(s); if Thread.isMainThread { _mainThreadRenders += 1 }; lock.unlock()
        }
        var mainThreadRenders: Int { lock.lock(); defer { lock.unlock() }; return _mainThreadRenders }
        func bumpBase() -> Bool { lock.lock(); _bases += 1; let f = failBase; lock.unlock(); return !f }
        func bumpRelease() { lock.lock(); _released += 1; lock.unlock() }
        var states: [EditState] { lock.lock(); defer { lock.unlock() }; return _states }
        var bases: Int { lock.lock(); defer { lock.unlock() }; return _bases }
        var released: Int { lock.lock(); defer { lock.unlock() }; return _released }
    }

    private let image = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 40, height: 30))

    /// A distinguishable preview: its width encodes the state's exposure, so a test can tell WHICH pass produced a published image.
    private nonisolated static func tiny(width: Int = 1) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: 1, bitsPerComponent: 8, bytesPerRow: 4 * width, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    private func makeModel(_ r: Recorder) -> LookPreviewModel {
        return LookPreviewModel(
            makeBase: { image in r.bumpBase() ? image : nil },
            render: { state, _ in
                if r.renderDelay > 0 { Thread.sleep(forTimeInterval: r.renderDelay) }
                r.record(state)
                return LookPreviewModelTests.tiny(width: 1 + Int((state.exposureEV * 100).rounded()))
            },
            releaseCaches: { r.bumpRelease() })
    }

    private func wait(_ what: String, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(condition(), "timed out waiting for: \(what)")
    }

    private var looksCount: Int { LookPreviewItem.looks(userLooks: []).count }
    private var stylesCount: Int { LookPreviewItem.styles().count }

    func testRefreshLooksRendersEveryCellOnceInOrderFromThePreviewState() async {
        let r = Recorder(); let m = makeModel(r)
        var state = EditState(); state.exposureEV = 0.5; state.masks = [Mask()]; state.retouchSpots = [RetouchSpot()]
        m.refreshLooks(state: state, image: image, imageRevision: 1, userLooks: [])
        await wait("looks") { m.looks.count == self.looksCount }
        XCTAssertEqual(r.states.count, looksCount)
        XCTAssertEqual(r.states.map(\.lookID), LookPreviewItem.looks(userLooks: []).map(\.id), "cells render in grid order, None first")
        XCTAssertTrue(r.states.allSatisfy { $0.masks.isEmpty && $0.retouchSpots.isEmpty && $0.exposureEV == 0.5 }, "local edits stripped, global kept")
        XCTAssertEqual(Set(m.looks.keys), Set(LookPreviewItem.looks(userLooks: []).map(\.id)))
        XCTAssertTrue(m.styles.isEmpty, "the Style grid is not touched")
        XCTAssertEqual(r.released, 1, "caches released once after the pass, not per cell")
    }

    /// Rendering a cell must never block the main thread.
    func testCellsRenderOffTheMainThread() async {
        let r = Recorder(); let m = makeModel(r)
        m.refreshLooks(state: EditState(), image: image, imageRevision: 1, userLooks: [])
        await wait("looks") { m.looks.count == self.looksCount }
        XCTAssertEqual(r.states.count, looksCount)
        XCTAssertEqual(r.mainThreadRenders, 0)
    }

    func testUnchangedKeyDoesNotRenderAgain() async {
        let r = Recorder(); let m = makeModel(r)
        let state = EditState()
        m.refreshLooks(state: state, image: image, imageRevision: 1, userLooks: [])
        await wait("first pass") { m.looks.count == self.looksCount }
        m.refreshLooks(state: state, image: image, imageRevision: 1, userLooks: [])
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(r.states.count, looksCount)
    }

    func testPickingALookRefreshesOnlyTheStyleGrid() async {
        let r = Recorder(); let m = makeModel(r)
        var state = EditState(); state.lookID = "builtin:a"
        m.refreshLooks(state: state, image: image, imageRevision: 1, userLooks: [])
        m.refreshStyles(state: state, image: image, imageRevision: 1)
        await wait("both grids") { m.looks.count == self.looksCount && m.styles.count == self.stylesCount }
        let before = r.states.count
        var picked = state; picked.lookID = "builtin:b"
        m.refreshLooks(state: picked, image: image, imageRevision: 1, userLooks: [])   // key ignores lookID: nothing to do
        m.refreshStyles(state: picked, image: image, imageRevision: 1)                  // styles stack on the new look: re-render
        await wait("styles re-rendered") { r.states.count == before + self.stylesCount }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(r.states.count, before + stylesCount)
        XCTAssertTrue(r.states.suffix(stylesCount).allSatisfy { $0.lookID == "builtin:b" })
    }

    func testPickingAStyleRefreshesOnlyTheLooksGrid() async {
        let r = Recorder(); let m = makeModel(r)
        var state = EditState(); state.styleID = "builtin:honey"
        m.refreshLooks(state: state, image: image, imageRevision: 1, userLooks: [])
        m.refreshStyles(state: state, image: image, imageRevision: 1)
        await wait("both grids") { m.looks.count == self.looksCount && m.styles.count == self.stylesCount }
        let before = r.states.count
        var picked = state; picked.styleID = "builtin:copper"
        m.refreshStyles(state: picked, image: image, imageRevision: 1)
        m.refreshLooks(state: picked, image: image, imageRevision: 1, userLooks: [])
        await wait("looks re-rendered") { r.states.count == before + self.looksCount }
        XCTAssertTrue(r.states.suffix(looksCount).allSatisfy { $0.styleID == "builtin:copper" })
    }

    func testASliderChangeRefreshesBothGridsAndALocalEditDoesNot() async {
        let r = Recorder(); let m = makeModel(r)
        let state = EditState()
        m.refreshLooks(state: state, image: image, imageRevision: 1, userLooks: [])
        m.refreshStyles(state: state, image: image, imageRevision: 1)
        await wait("both") { m.looks.count == self.looksCount && m.styles.count == self.stylesCount }
        let before = r.states.count
        var local = state; local.masks = [Mask()]
        m.refreshLooks(state: local, image: image, imageRevision: 1, userLooks: [])
        m.refreshStyles(state: local, image: image, imageRevision: 1)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(r.states.count, before, "local edits are not part of the key")
        var slider = state; slider.exposureEV = 0.4
        m.refreshLooks(state: slider, image: image, imageRevision: 1, userLooks: [])
        m.refreshStyles(state: slider, image: image, imageRevision: 1)
        await wait("both re-rendered") { r.states.count == before + self.looksCount + self.stylesCount }
    }

    func testANewerRefreshDropsTheOlderPassAndItsResults() async {
        let r = Recorder(); r.renderDelay = 0.03
        let m = makeModel(r)
        var a = EditState(); a.exposureEV = 0.1
        m.refreshLooks(state: a, image: image, imageRevision: 1, userLooks: [])
        await wait("first pass started") { !r.states.isEmpty }
        var b = EditState(); b.exposureEV = 0.9
        m.refreshLooks(state: b, image: image, imageRevision: 1, userLooks: [])
        await wait("second pass complete") { m.looks.count == self.looksCount && r.states.filter { $0.exposureEV == 0.9 }.count == self.looksCount }
        XCTAssertLessThan(r.states.filter { $0.exposureEV == 0.1 }.count, looksCount, "the older pass stopped early")
        XCTAssertTrue(m.looks.values.allSatisfy { $0.width == 91 }, "only the newest pass's images remain (width encodes exposure 0.9)")
        XCTAssertEqual(r.released, 1, "an abandoned pass never releases; only the completed one does")
    }

    /// A pass cancelled by a photo switch must not publish the render that was already in flight when it was cancelled.
    func testACancelledPassNeverPublishesItsInFlightRender() async {
        let r = Recorder(); r.renderDelay = 0.08
        let m = makeModel(r)
        var s0 = EditState(); s0.exposureEV = 0.3
        m.refreshLooks(state: s0, image: image, imageRevision: 1, userLooks: [])
        await wait("a render started") { !r.states.isEmpty }
        r.failBase = true                     // photo 2 never gets a base, so nothing legitimate can be published
        m.refreshLooks(state: s0, image: image, imageRevision: 2, userLooks: [])
        try? await Task.sleep(nanoseconds: 300_000_000)   // the old in-flight render finishes during this
        XCTAssertTrue(m.looks.isEmpty, "the cancelled pass's in-flight result must be discarded, not published")
    }

    func testPreviewsOfAnotherPhotoAreHiddenByTheRevisionAccessors() async {
        let r = Recorder(); let m = makeModel(r)
        m.refreshLooks(state: EditState(), image: image, imageRevision: 3, userLooks: [])
        m.refreshStyles(state: EditState(), image: image, imageRevision: 3)
        await wait("both") { m.looks.count == self.looksCount && m.styles.count == self.stylesCount }
        XCTAssertEqual(m.looks(forRevision: 3).count, looksCount)
        XCTAssertEqual(m.styles(forRevision: 3).count, stylesCount)
        XCTAssertTrue(m.looks(forRevision: 4).isEmpty, "a view whose document moved on must not show these")
        XCTAssertTrue(m.styles(forRevision: 4).isEmpty)
        XCTAssertEqual(m.revision, 3)
    }

    func testAPhotoSwitchClearsOldPreviewsAtOnceAndRebuildsTheBase() async {
        let r = Recorder(); let m = makeModel(r)
        let state = EditState()
        m.refreshLooks(state: state, image: image, imageRevision: 1, userLooks: [])
        await wait("photo 1 previews") { m.looks.count == self.looksCount }
        XCTAssertEqual(r.bases, 1)
        r.renderDelay = 0.03
        m.refreshLooks(state: state, image: image, imageRevision: 2, userLooks: [])
        XCTAssertTrue(m.looks.isEmpty, "the previous photo's previews must not linger")
        await wait("photo 2 previews") { m.looks.count == self.looksCount }
        XCTAssertEqual(r.bases, 2, "a new revision rebuilds the base")
    }

    func testTheBaseIsBuiltOncePerRevisionAndSharedByBothGrids() async {
        let r = Recorder(); let m = makeModel(r)
        var s = EditState()
        m.refreshLooks(state: s, image: image, imageRevision: 5, userLooks: [])
        m.refreshStyles(state: s, image: image, imageRevision: 5)
        await wait("both") { m.looks.count == self.looksCount && m.styles.count == self.stylesCount }
        s.exposureEV = 0.3
        m.refreshLooks(state: s, image: image, imageRevision: 5, userLooks: [])
        m.refreshStyles(state: s, image: image, imageRevision: 5)
        await wait("re-render") { r.states.count == 2 * (self.looksCount + self.stylesCount) }
        XCTAssertEqual(r.bases, 1)
    }

    func testNoImageClearsEverythingAndRendersNothing() async {
        let r = Recorder(); let m = makeModel(r)
        m.refreshLooks(state: EditState(), image: image, imageRevision: 1, userLooks: [])
        await wait("previews") { m.looks.count == self.looksCount }
        let before = r.states.count
        m.refreshLooks(state: EditState(), image: nil, imageRevision: 2, userLooks: [])
        m.refreshStyles(state: EditState(), image: nil, imageRevision: 2)
        XCTAssertTrue(m.looks.isEmpty); XCTAssertTrue(m.styles.isEmpty)
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(r.states.count, before)
    }

    func testAFailedBaseBuildPublishesNothingAndTheNextRefreshRetries() async {
        let r = Recorder(); r.failBase = true
        let m = makeModel(r)
        m.refreshLooks(state: EditState(), image: image, imageRevision: 1, userLooks: [])
        await wait("base attempted") { r.bases == 1 }
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertTrue(m.looks.isEmpty); XCTAssertTrue(r.states.isEmpty)
        r.failBase = false
        m.refreshLooks(state: EditState(), image: image, imageRevision: 1, userLooks: [])   // same key: must retry, not be skipped
        await wait("retry renders") { m.looks.count == self.looksCount }
        XCTAssertEqual(r.bases, 2)
    }

    func testAnImportedLookAddsACellAndRefreshesTheLooksGrid() async {
        let r = Recorder(); let m = makeModel(r)
        m.refreshLooks(state: EditState(), image: image, imageRevision: 1, userLooks: [])
        await wait("builtins") { m.looks.count == self.looksCount }
        let user = LookLibrary.UserLook(id: "user:abc", name: "Mine", cube: BuiltInLooks.cube(id: BuiltInLooks.all[0].id)!)
        m.refreshLooks(state: EditState(), image: image, imageRevision: 1, userLooks: [user])
        await wait("user look cell") { m.looks["user:abc"] != nil }
        XCTAssertEqual(m.looks.count, looksCount + 1)
    }

    func testTheGridFillsImmediatelyButAnUpdateIsDebounced() {
        XCTAssertEqual(LookPreviewModel.refreshDelayNanoseconds(hasPreviewsForThisPhoto: false), 0)
        XCTAssertGreaterThan(LookPreviewModel.refreshDelayNanoseconds(hasPreviewsForThisPhoto: true), 0)
    }
}
