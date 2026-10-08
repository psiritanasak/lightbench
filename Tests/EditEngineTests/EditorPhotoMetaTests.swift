import XCTest
@testable import PhotoApp

@MainActor
final class EditorPhotoMetaTests: XCTestCase {
    private func photo(_ path: String, rating: Int = 0, flag: FlagStatus = .none, label: ColorLabel = .none) -> Photo {
        Photo(id: 1, path: path, filename: "x", fileSize: nil, importedAt: Date(timeIntervalSince1970: 0),
              rating: rating, flagStatus: flag, colorLabel: label)
    }

    private final class Calls {
        var ratings: [Int] = []
        var flags: [FlagStatus] = []
        var labels: [ColorLabel] = []
    }

    private func make(_ rows: [String: Photo], calls: Calls = Calls(),
                      resolve: EditorPhotoMeta.Resolver? = nil) -> EditorPhotoMeta {
        EditorPhotoMeta(
            resolve: resolve ?? { rows[$0] },
            setRating: { r, _ in calls.ratings.append(r) },
            setFlagStatus: { s, _ in calls.flags.append(s) },
            setColorLabel: { l, _ in calls.labels.append(l) })
    }

    func testResolvesCataloguedPhoto() async {
        let meta = make(["/a.jpg": photo("/a.jpg", rating: 3)])
        await meta.sync(path: "/a.jpg", isLoading: false)?.value
        XCTAssertEqual(meta.photo?.rating, 3)
    }

    func testUncataloguedPhotoHasNoRowAndActionsAreNoOps() async {
        let calls = Calls()
        let meta = make([:], calls: calls)
        await meta.sync(path: "/none.jpg", isLoading: false)?.value
        XCTAssertNil(meta.photo)
        XCTAssertFalse(meta.apply(.rating(4)))
        meta.setRating(4); meta.setFlag(.picked); meta.setLabel(.red)
        XCTAssertTrue(calls.ratings.isEmpty && calls.flags.isEmpty && calls.labels.isEmpty)
    }

    func testLookupFailureLeavesNoRow() async {
        struct Boom: Error {}
        let meta = make([:], resolve: { _ in throw Boom() })
        await meta.sync(path: "/a.jpg", isLoading: false)?.value
        XCTAssertNil(meta.photo)
    }

    func testLoadingClearsRowAndDoesNotLookUp() async {
        let meta = make(["/a.jpg": photo("/a.jpg")])
        await meta.sync(path: "/a.jpg", isLoading: false)?.value
        XCTAssertNotNil(meta.photo)
        XCTAssertNil(meta.sync(path: "/a.jpg", isLoading: true))
        XCTAssertNil(meta.photo, "mid-load the URL still names the outgoing photo")
        XCTAssertFalse(meta.apply(.rating(5)))
    }

    func testNilPathClears() async {
        let meta = make(["/a.jpg": photo("/a.jpg")])
        await meta.sync(path: "/a.jpg", isLoading: false)?.value
        meta.sync(path: nil, isLoading: false)
        XCTAssertNil(meta.photo)
    }

    func testStaleLookupIsDropped() async {
        // The first lookup for /a is slow and finishes AFTER the user moved to /b.
        var releaseA: CheckedContinuation<Void, Never>?
        let meta = make([:], resolve: { path in
            if path == "/a.jpg" { await withCheckedContinuation { releaseA = $0 } }
            return Photo(id: path == "/a.jpg" ? 1 : 2, path: path, filename: "x", fileSize: nil,
                         importedAt: Date(timeIntervalSince1970: 0))
        })
        let first = meta.sync(path: "/a.jpg", isLoading: false)
        for _ in 0..<1000 where releaseA == nil { await Task.yield() }
        guard releaseA != nil else { return XCTFail("the first lookup never started") }
        await meta.sync(path: "/b.jpg", isLoading: false)?.value
        XCTAssertEqual(meta.photo?.path, "/b.jpg")
        releaseA?.resume()
        await first?.value
        XCTAssertEqual(meta.photo?.path, "/b.jpg", "a stale result must not replace the newer photo")
    }

    func testChangingPathDropsOldRowImmediately() async {
        let meta = make(["/a.jpg": photo("/a.jpg")], resolve: nil)
        await meta.sync(path: "/a.jpg", isLoading: false)?.value
        let task = meta.sync(path: "/b.jpg", isLoading: false)
        XCTAssertNil(meta.photo, "must not keep acting on /a while /b resolves")
        await task?.value
    }

    func testRatingIsClampedAndForwarded() async {
        let calls = Calls()
        let meta = make(["/a.jpg": photo("/a.jpg", rating: 2)], calls: calls)
        await meta.sync(path: "/a.jpg", isLoading: false)?.value
        meta.setRating(9)
        XCTAssertEqual(meta.photo?.rating, 5)
        meta.setRating(-3)
        XCTAssertEqual(meta.photo?.rating, 0)
        XCTAssertEqual(calls.ratings, [5, 0])
    }

    func testKeyCommandsToggleLikeTheGrid() async {
        let calls = Calls()
        let meta = make(["/a.jpg": photo("/a.jpg")], calls: calls)
        await meta.sync(path: "/a.jpg", isLoading: false)?.value
        XCTAssertTrue(meta.apply(.flag(nil)))
        XCTAssertEqual(meta.photo?.flagStatus, .picked)
        XCTAssertTrue(meta.apply(.flag(nil)))
        XCTAssertEqual(meta.photo?.flagStatus, FlagStatus.none)
        meta.apply(.flag(.rejected))
        meta.apply(.flag(nil))
        XCTAssertEqual(meta.photo?.flagStatus, FlagStatus.none, "toggle from Rejected clears")
        meta.apply(.label(.red))
        XCTAssertEqual(meta.photo?.colorLabel, .red)
        meta.apply(.label(.red))
        XCTAssertEqual(meta.photo?.colorLabel, ColorLabel.none)
        meta.apply(.label(.blue))
        meta.apply(.label(.green))
        XCTAssertEqual(meta.photo?.colorLabel, .green)
        XCTAssertEqual(calls.flags, [.picked, .none, .rejected, .none])
        XCTAssertEqual(calls.labels, [.red, .none, .blue, .green])
    }

    func testRatingKeySetsExactValue() async {
        let calls = Calls()
        let meta = make(["/a.jpg": photo("/a.jpg", rating: 3)], calls: calls)
        await meta.sync(path: "/a.jpg", isLoading: false)?.value
        meta.apply(.rating(3))   // like the grid, a key sets (does not toggle off)
        XCTAssertEqual(meta.photo?.rating, 3)
        XCTAssertEqual(calls.ratings, [3])
    }

    /// A same-path re-lookup that is still running must not blank the bar (no flicker), and a change made meanwhile must
    /// survive the lookup finishing with the PRE-change row.
    func testSamePathResyncKeepsRowAndAChangeMadeMeanwhileSurvives() async {
        var release: CheckedContinuation<Void, Never>?
        var slow = false
        let old = photo("/a.jpg", rating: 1)
        let meta = make([:], resolve: { _ in
            if slow { await withCheckedContinuation { release = $0 } }
            return old
        })
        await meta.sync(path: "/a.jpg", isLoading: false)?.value
        slow = true
        let task = meta.sync(path: "/a.jpg", isLoading: false)
        for _ in 0..<1000 where release == nil { await Task.yield() }
        guard release != nil else { return XCTFail("the re-lookup never started") }
        XCTAssertNotNil(meta.photo, "a same-path re-sync must not blank the bar")
        meta.setRating(4)
        release?.resume()
        await task?.value
        XCTAssertEqual(meta.photo?.rating, 4, "a lookup that read the pre-change row must not undo the change")
    }
}
