import CoreGraphics

/// The small decisions that tie the Remove tool to zoom/pan, kept pure so they are unit-tested (the views just ask).
/// While the Place Spots tool is armed or a spot is selected, plain dragging belongs to the tool, so panning is a HELD-SPACE
/// gesture (Space = temporary hand tool, as in Photoshop/Lightroom); arrow keys always pan, scroll always zooms.
enum RetouchZoomRules {
    /// The Remove tool is "active" — it owns plain pointer drags on the photo: the Retouch tab is showing, the Crop tab is not showing,
    /// and the tool is armed or a spot is selected.
    static func isToolActive(retouchTabShowing: Bool, isCropping: Bool, geometryAtIdentity: Bool, isArmed: Bool, hasSelectedSpot: Bool) -> Bool {
        retouchTabShowing && !isCropping && geometryAtIdentity && (isArmed || hasSelectedSpot)
    }

    /// Whether the Space key is taken as the hand tool: only while the tool is active (anywhere else Space keeps its normal meaning).
    static func spaceIsHandTool(toolActive: Bool) -> Bool { toolActive }

    /// `isSpaceHeld` after something changed: it can only stay true while the tool is active AND the image pane has keyboard focus. A
    /// lost key-up (focus moved, the tool ended, a tab/photo/Compare switch) therefore cannot leave the pan layer stuck on.
    static func spaceHeldAfterChange(spaceHeld: Bool, toolActive: Bool, paneFocused: Bool) -> Bool {
        spaceHeld && toolActive && paneFocused
    }

    /// Whether the single-image drag-to-pan layer is mounted: the usual rule (zoomed in, not Split) — except that while the Remove tool
    /// is active it is mounted ONLY while Space is held, so it never steals placement or handle drags.
    static func mountsPanLayer(canZoom: Bool, zoomScale: CGFloat, compareIsSplit: Bool, toolActive: Bool, spaceHeld: Bool) -> Bool {
        canZoom && zoomScale > 1 && !compareIsSplit && (!toolActive || spaceHeld)
    }
}
