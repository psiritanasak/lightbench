import Foundation

/// One cell of the Looks tab's thumbnail grid: a Look or a Style preset ("" = None) and what clicking it does to an
/// `EditState`. A cell's preview is exactly what clicking it would produce — the current edits with ONLY that look (or style
/// preset) chosen — so `applying(to:)` reproduces the state change of `LooksTabView.selectLook` / `ImageDocumentModel.selectStyle`,
/// including their None-cell resets (a cleared look resets `lookIntensity` to 1; a cleared style resets `styleStrength` to 1
/// only while the pad is centred), so a click handler may commit it without leaving a phantom edit behind. Pure: no Core Image,
/// no UI.
struct LookPreviewItem: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable { case look, style }

    let kind: Kind
    /// The look/style id as stored in `EditState`; "" is the None cell.
    let id: String
    let name: String

    /// An imported (user `.cube`) look: a non-empty look id that is not `builtin:` — the same split `LookLibrary.cube(for:)` uses.
    var isImportedLook: Bool { kind == .look && !id.isEmpty && !id.hasPrefix("builtin:") }

    /// `state` with this cell's look/style chosen.
    func applying(to state: EditState) -> EditState {
        var s = state
        switch kind {
        case .look:
            s.lookID = id
            if id.isEmpty { s.lookIntensity = 1 }
        case .style:
            s.styleID = id
            if id.isEmpty, StyleMath.isIdentity(id: "", tone: s.styleTone, color: s.styleColor) { s.styleStrength = 1 }
        }
        return s
    }

    /// None, the built-in looks in library order, then the imported ones.
    static func looks(userLooks: [LookLibrary.UserLook]) -> [LookPreviewItem] {
        [LookPreviewItem(kind: .look, id: "", name: "None")]
            + BuiltInLooks.all.map { LookPreviewItem(kind: .look, id: $0.id, name: $0.name) }
            + userLooks.map { LookPreviewItem(kind: .look, id: $0.id, name: $0.name) }
    }

    /// None, then every style preset in library order (Undertone family first, then Mood).
    static func styles() -> [LookPreviewItem] {
        [LookPreviewItem(kind: .style, id: "", name: "None")]
            + StyleLibrary.all.map { LookPreviewItem(kind: .style, id: $0.id, name: $0.name) }
    }

    // MARK: - What a preview renders and when it is stale

    /// The state previews are rendered from: the current edits WITHOUT the local ones (masks, retouch spots, red-eye points).
    /// Those are expensive at small size, never change what a Look or Style looks like, and brush masks would thrash the live
    /// editor's single-entry stroke cache. Every global edit (exposure, tone, curves, crop/geometry, B&W, grain, …) stays, so a
    /// preview has the framing and tone the user sees.
    static func previewState(from state: EditState) -> EditState {
        var s = state
        s.masks = []
        s.retouchSpots = []
        s.redEyePoints = []
        return s
    }

    /// The Looks grid is stale exactly when this changes: previews depend on everything EXCEPT which look is currently chosen
    /// (each cell swaps its own look in). The current Style and Look intensity ARE part of it.
    ///
    /// NOTE for the model: the grid keys include the RAW decode-time fields (`rawExposureEV`, `boostAmount`, …), which
    /// `EditPipeline.apply` does NOT apply — they live in the decoded source. A key change caused by a
    /// `requiresRawRedecode` field must therefore also rebuild the base from the re-decoded image (`ImageDocumentModel`
    /// replaces `currentImage`), or the grid re-renders with stale pixels.
    static func looksGridKey(for state: EditState) -> EditState {
        var s = previewState(from: state)
        s.lookID = ""
        return s
    }

    /// The Style grid is stale exactly when this changes: everything except which style PRESET is chosen (the pad, strength,
    /// texture and the current Look are part of it).
    static func stylesGridKey(for state: EditState) -> EditState {
        var s = previewState(from: state)
        s.styleID = ""
        return s
    }
}
