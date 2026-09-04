import Foundation

/// Detects "a sustained slider drag is in progress" for IMPROVEMENTS.md P2,
/// purely from a COUNT of consecutive `editState` changes observed across
/// draws — not from wall-clock inter-arrival time between them.
///
/// An earlier design compared timestamps between successive `editState`
/// changes and only engaged the proxy if they arrived within a short window
/// of each other. That fails exactly in the case this feature exists to fix:
/// `ImageRenderer.draw(in:)` is synchronous, so the observed interval between
/// two changes is bounded below by how long the PREVIOUS frame took to
/// render — and the measured justification for this feature is frames taking
/// 184.7-279.0ms. At that cost, consecutive changes are that far apart, and
/// any short window would never fire — the proxy would engage only on the
/// photos that didn't need it. Counting changes instead is timing-independent
/// by construction: it doesn't matter whether frames take 4ms or 400ms, the
/// 2nd observed change in a burst always flips `isInteracting` on.
///
/// The counter is reset by a trailing-edge silence timer
/// (`ImageRenderer.scheduleSettleRedraw`, ~0.25s of no further `editState`
/// change), not by this type itself — `ProxyInteraction` has no clock of its
/// own, keeping it pure and directly testable.
struct ProxyInteraction: Equatable {
    private(set) var observedEditChanges: Int = 0
    private(set) var lastFrameUsedProxy: Bool = false

    /// True from the 2nd observed `editState` change in a burst until
    /// `settle()` is called. A single discrete change (undo/redo, a typed
    /// numeric value, a toggle, applying a preset) stays at count 1 and so
    /// never engages the proxy — matching the confirmed design that a
    /// one-off edit always renders full-res immediately.
    var isInteracting: Bool { observedEditChanges >= 2 }

    /// Call whenever a draw observes `editState` differing from the
    /// previously-drawn value.
    mutating func noteEditStateChanged() {
        observedEditChanges += 1
    }

    /// Call once per draw with whether that frame's pipeline input was the
    /// proxy (vs. full-res), so `settle()` can tell whether a trailing
    /// full-resolution redraw is actually needed.
    mutating func recordFrame(usedProxy: Bool) {
        lastFrameUsedProxy = usedProxy
    }

    /// Called when the trailing-edge silence timer fires. Returns whether a
    /// full-resolution redraw is actually needed — i.e. whether the most
    /// recent frame used the proxy. Without this guard, a burst that never
    /// actually engaged the proxy (a small photo, or one already at full
    /// res) would still pay one extra full-res redraw after every drag — a
    /// straight regression against today's behavior. Always resets the
    /// counter, regardless of the return value.
    mutating func settle() -> Bool {
        defer {
            observedEditChanges = 0
            lastFrameUsedProxy = false
        }
        return lastFrameUsedProxy
    }

    /// Full reset — called when the source image itself changes (a new
    /// photo, or a RAW re-decode), so a stale burst/settle-timer state from
    /// the previous photo can never leak into the new one.
    mutating func reset() {
        observedEditChanges = 0
        lastFrameUsedProxy = false
    }
}
