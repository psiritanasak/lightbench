import Foundation

/// The Editor's image-pane "armed" interaction state — WB eyedropper,
/// Red-Eye placement, brush painting, and the Color Range/Point Color
/// eyedroppers. Exactly one can be armed at a time; before this type
/// existed, that invariant was kept by hand: 6 sites in `AdjustTabView`
/// each armed their own mode and individually reset the other 5's state
/// (2 bools + 3 optional UUIDs), 2 more (`select(_:)`/`selectPointColor`)
/// disarmed all 5 on a plain selection, and several more in `ContentView`
/// (Escape, photo switch, tab switch, entering Compare, each one-shot
/// commit) each cleared some subset by hand too. IMPROVEMENTS.md's D14
/// entry logged a shared enum as overdue once the 6th arm site went in.
/// One stored value makes "two modes armed at once" unrepresentable
/// instead of merely avoided.
///
/// Deliberately does NOT cover mask/point-color SELECTION
/// (`AdjustPanelState.selectedMaskID`/`selectedPointColorID`), despite
/// IMPROVEMENTS.md's own D14 sketch including an `editingMask(UUID)` case —
/// selection survives tab switches and legitimately coexists with an armed
/// mode today (brush painting always has its mask selected; arming Point
/// Color does not clear a selected radial mask). Folding selection in
/// would change that behavior, not just rename it — a deliberate, narrower
/// departure from that sketch, not an oversight.
///
/// `paintingBrush`/`pickingColorRange`/`pickingPointColor` carry their
/// mask/instance `UUID`, not just a bare case — a falling-edge cleanup
/// (discarding a never-painted/never-picked mask or instance) needs to name
/// the mask that was JUST disarmed, which a payload-free case couldn't
/// supply once the caller has already moved `self` to a different value.
enum EditorInteractionMode: Equatable {
    case none
    case pickingWhiteBalance
    case placingRedEye
    case paintingBrush(maskID: UUID)
    case pickingColorRange(maskID: UUID)
    case pickingPointColor(pointColorID: UUID)
    /// Click-on-image subject picking: stays armed so several subjects can be toggled (like Red-Eye placement).
    case pickingSubject(maskID: UUID)

    /// Read-only projections matching the 5 stored properties this type
    /// replaces, by name and type — every existing read site (`canZoom`,
    /// the overlay gates, the crosshair tint switch, `.onChange` handlers)
    /// keeps reading exactly these names/shapes, unchanged.
    var isPickingWhiteBalance: Bool {
        self == .pickingWhiteBalance
    }

    var isPlacingRedEyeCorrections: Bool {
        self == .placingRedEye
    }

    var brushPaintingMaskID: UUID? {
        if case .paintingBrush(let maskID) = self { return maskID }
        return nil
    }

    var colorPickingMaskID: UUID? {
        if case .pickingColorRange(let maskID) = self { return maskID }
        return nil
    }

    var subjectPickingMaskID: UUID? {
        if case .pickingSubject(let maskID) = self { return maskID }
        return nil
    }

    var pointColorPickingID: UUID? {
        if case .pickingPointColor(let pointColorID) = self { return pointColorID }
        return nil
    }

    /// The WB/Red-Eye buttons' own shape: a bool toggle, but expressed
    /// against the whole enum so arming either one is exactly "this mode,
    /// or `.none` if it's already armed" — matching `isPickingWhiteBalance.
    /// toggle()`/`isPlacingRedEyeCorrections.toggle()`'s old behavior
    /// exactly (including switching directly from a DIFFERENT armed mode
    /// straight to this one, not toggling relative to that other mode).
    mutating func toggle(_ mode: EditorInteractionMode) {
        self = (self == mode) ? .none : mode
    }

    /// Disarms only if `mode` (case AND payload) is exactly what's armed —
    /// a no-op otherwise, so a stale/already-superseded disarm call (e.g. a
    /// deleted mask that was never the one currently armed) can't clobber
    /// whatever else is now armed. Mirrors every "only if id == mask.id"
    /// guard the old `brushPaintingMaskID == id` / `colorPickingMaskID ==
    /// id` checks already had at their own call sites.
    mutating func disarm(_ mode: EditorInteractionMode) {
        if self == mode {
            self = .none
        }
    }

    /// Disarms brush painting or Color Range picking for ANY mask id,
    /// leaving WB/Red-Eye/Point-Color untouched — the Masks-section-
    /// collapse and "mask no longer exists" (Undo/Revert/Apply-Preset)
    /// cleanup shape, which never knows or cares which specific mask was
    /// armed, only that mask-editing itself has ended.
    mutating func disarmMaskModes() {
        switch self {
        case .paintingBrush, .pickingColorRange, .pickingSubject:
            self = .none
        case .none, .pickingWhiteBalance, .placingRedEye, .pickingPointColor:
            break
        }
    }

    /// The `disarmMaskModes()` analogue for Point Color picking — the
    /// Point-Color-section-collapse and "instance no longer selected"
    /// cleanup shape.
    mutating func disarmPointColorPick() {
        if case .pickingPointColor = self {
            self = .none
        }
    }
}
