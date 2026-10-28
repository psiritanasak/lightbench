import XCTest
@testable import PhotoApp

/// D82: the Editor's Metal view must always draw. `DrawWatchdog` forces one draw when a redraw was requested but the display cycle never
/// produced one. Logic tests use a manual scheduler; source pins check the wiring that unit tests cannot reach (the view is private).
@MainActor
final class DrawWatchdogTests: XCTestCase {
    @MainActor private final class Harness {
        var pending: [() -> Void] = []
        var draws = 0
        var forced = 0
        var canDraw = true
        lazy var watchdog = DrawWatchdog(
            delay: 0.15,
            schedule: { [unowned self] _, block in self.pending.append { MainActor.assumeIsolated { block() } } },
            drawCount: { [unowned self] in self.draws },
            canDraw: { [unowned self] in self.canDraw },
            forceDraw: { [unowned self] in self.forced += 1; self.draws += 1 }
        )
        /// Fires every currently scheduled check once (checks scheduled by a firing check wait for the next call).
        func fire() {
            let batch = pending
            pending = []
            batch.forEach { $0() }
        }
    }

    func testRequestWithoutDrawForcesExactlyOnce() {
        let h = Harness()
        h.watchdog.requested()
        XCTAssertEqual(h.pending.count, 1)
        h.fire()
        XCTAssertEqual(h.forced, 1)
        XCTAssertTrue(h.pending.isEmpty)
    }

    func testDrawBeforeCheckMeansNoForce() {
        let h = Harness()
        h.watchdog.requested()
        h.draws += 1
        h.fire()
        XCTAssertEqual(h.forced, 0)
    }

    func testBurstIsCoalescedIntoOnePendingCheckAndOneForce() {
        let h = Harness()
        for _ in 0..<100 { h.watchdog.requested() }
        XCTAssertEqual(h.pending.count, 1)
        h.fire()
        XCTAssertEqual(h.forced, 1)
        // The forced draw covered every request in the burst: nothing left to check.
        XCTAssertTrue(h.pending.isEmpty)
        h.fire()
        XCTAssertEqual(h.forced, 1)
    }

    func testRequestWhilePendingIsStillCoveredAfterTheCheckFires() {
        let h = Harness()
        h.watchdog.requested()
        h.draws += 1 // a draw serves the first request
        h.watchdog.requested() // arrives while the check is pending
        XCTAssertEqual(h.pending.count, 1)
        h.fire()
        XCTAssertEqual(h.forced, 0)
        XCTAssertEqual(h.pending.count, 1, "the late request must get its own check")
        h.fire()
        XCTAssertEqual(h.forced, 1, "and that check forces a draw when none happened")
    }

    func testDrawAfterTheLateRequestCoversItNoRearmNoForce() {
        let h = Harness()
        h.watchdog.requested()
        h.draws += 1
        h.watchdog.requested()
        h.draws += 1 // draw after the late request
        h.fire()
        XCTAssertEqual(h.forced, 0)
        XCTAssertTrue(h.pending.isEmpty)
    }

    func testCanDrawFalseNeverForces() {
        let h = Harness()
        h.canDraw = false
        h.watchdog.requested()
        h.fire()
        XCTAssertEqual(h.forced, 0)
        XCTAssertTrue(h.pending.isEmpty, "never loops while the view cannot draw")
    }

    func testForcedDrawDoesNotRefire() {
        let h = Harness()
        h.watchdog.requested()
        h.fire()
        h.fire()
        h.fire()
        XCTAssertEqual(h.forced, 1)
        XCTAssertTrue(h.pending.isEmpty)
    }

    func testLaterRequestAfterAForceWorksAgain() {
        let h = Harness()
        h.watchdog.requested()
        h.fire()
        XCTAssertEqual(h.forced, 1)
        h.watchdog.requested()
        XCTAssertEqual(h.pending.count, 1)
        h.fire()
        XCTAssertEqual(h.forced, 2)
    }

    // MARK: - Source pins

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testDrawCountIsIncrementedBeforeDrawInsGuards() throws {
        let text = try source("Sources/Rendering/ImageRenderer.swift")
        let start = try XCTUnwrap(text.range(of: "func draw(in view: MTKView) {"))
        let body = text[start.upperBound...]
        let inc = try XCTUnwrap(body.range(of: "drawCount += 1"))
        let guardRange = try XCTUnwrap(body.range(of: "guard let image"))
        XCTAssertLessThan(inc.lowerBound, guardRange.lowerBound)
    }

    func testRendererInternalRedrawsNotifyTheWatchdog() throws {
        let text = try source("Sources/Rendering/ImageRenderer.swift")
        XCTAssertEqual(text.components(separatedBy: "self.onInternalRedraw?()").count - 1, 2)
    }

    func testViewWiresTheWatchdogInUpdateAndSetFrameSize() throws {
        let text = try source("Sources/Rendering/MetalImageView.swift")
        let update = try XCTUnwrap(text.range(of: "func updateNSView"))
        let updateEnd = try XCTUnwrap(text.range(of: "func makeCoordinator"))
        let afterUpdate = text[update.upperBound..<updateEnd.lowerBound]
        let setNeeds = try XCTUnwrap(afterUpdate.range(of: "nsView.setNeedsDisplay(nsView.bounds)"))
        let requested = try XCTUnwrap(afterUpdate.range(of: "requested()"))
        XCTAssertLessThan(setNeeds.lowerBound, requested.lowerBound)
        let guardEnd = try XCTUnwrap(afterUpdate.range(of: "return\n        }"))
        XCTAssertLessThan(guardEnd.lowerBound, requested.lowerBound, "only the changed-state branch requests a check")

        let frame = try XCTUnwrap(text.range(of: "override func setFrameSize"))
        let frameBody = text[frame.upperBound...].prefix(300)
        XCTAssertTrue(frameBody.contains("watchdog.requested()"))
        XCTAssertTrue(text.contains("canDraw"))
        XCTAssertTrue(text.contains("window.isVisible") && text.contains("isMiniaturized"))
        XCTAssertTrue(text.contains("isHiddenOrHasHiddenAncestor"))
        XCTAssertTrue(text.contains("self.bounds.width > 0 && self.bounds.height > 0"))
        XCTAssertFalse(text.contains("occlusionState.contains"), "the occlusion bit read 8192 in the failing launch")
        XCTAssertTrue(text.contains("renderer.onInternalRedraw"))
        XCTAssertFalse(text.contains("d82log"), "no probe logging in production")
    }
}
