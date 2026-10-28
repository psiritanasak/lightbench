import Foundation

/// D82: on some first launches the Editor's `MTKView` never receives a draw after `setNeedsDisplay` (AppKit's display cycle simply does
/// not run for it), leaving the canvas blank until relaunch. This watchdog is told whenever a redraw is requested; shortly afterwards it
/// checks whether the renderer's draw counter moved and, if it did not and the view can draw, forces ONE draw.
///
/// - Checks are coalesced: at most one is outstanding, so slider drags and scroll storms add no timers.
/// - A request that arrives while a check is pending is remembered together with the draw count at that moment. The LAST request is
///   always covered: a forced draw renders the current state (covering all of them), a draw AFTER the late request covers it too, and
///   only when no draw followed it does the check re-arm once for it (no spurious extra draw after a normal burst).
/// - It never loops: nothing re-arms without a new request.
@MainActor
final class DrawWatchdog {
    typealias Schedule = (TimeInterval, @escaping @MainActor () -> Void) -> Void

    private let delay: TimeInterval
    private let schedule: Schedule
    private let drawCount: () -> Int
    private let canDraw: () -> Bool
    private let forceDraw: () -> Void

    private var isPending = false
    private var requestedWhilePending = false
    private var recordedCount = 0
    private var countAtLateRequest = 0

    init(
        delay: TimeInterval = 0.15,
        schedule: @escaping Schedule = DrawWatchdog.mainQueueSchedule,
        drawCount: @escaping () -> Int,
        canDraw: @escaping () -> Bool,
        forceDraw: @escaping () -> Void
    ) {
        self.delay = delay
        self.schedule = schedule
        self.drawCount = drawCount
        self.canDraw = canDraw
        self.forceDraw = forceDraw
    }

    nonisolated static func mainQueueSchedule(_ delay: TimeInterval, _ block: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated { block() }
        }
    }

    /// Call whenever a redraw has been asked for.
    func requested() {
        guard !isPending else {
            requestedWhilePending = true
            countAtLateRequest = drawCount()
            return
        }
        isPending = true
        recordedCount = drawCount()
        schedule(delay) { [weak self] in self?.check() }
    }

    private func check() {
        isPending = false
        let drewSinceRequest = drawCount() != recordedCount
        var forced = false
        if !drewSinceRequest, canDraw() {
            forced = true
            forceDraw()
        }
        let late = requestedWhilePending
        requestedWhilePending = false
        if late, !forced, drawCount() == countAtLateRequest { requested() }
    }
}
