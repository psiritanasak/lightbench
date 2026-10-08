import SwiftUI

/// A transparent click-drag-to-pan surface for the Editor's zoom feature.
/// Present only while zoomed past fit AND no other click-drag tool (crop
/// handles, WB eyedropper, red-eye placement, Compare's Split divider) is
/// armed — see `ContentView.canZoom`/the call site's own gating — or, while the
/// Remove tool is active (it owns plain drags), only with Space held, grabbing
/// drags over the whole pane (`grabRect`). Not shown at all in Compare's Split
/// mode: the divider already owns click-drag there (see `ContentView`'s own note
/// on this).
struct PanOverlay: View {
    let fitRect: CGRect
    /// Where the drag is ACCEPTED. `nil` = the fit rect (the usual behaviour). The Remove tool's Space-pan passes the whole pane, so a
    /// zoomed picture can be dragged from anywhere over it — the delta is still normalised by `fitRect`, the unit `panOffset` uses.
    var grabRect: CGRect?
    @Binding var zoomScale: CGFloat
    @Binding var panOffset: CGSize

    /// Snapshot of `panOffset` at the start of the CURRENT drag, so
    /// `onChanged` always computes from a fixed baseline plus the
    /// gesture's cumulative `translation` — the same start-snapshot shape
    /// `CropOverlayView`/`CompareDividerOverlay`'s grab strip already use,
    /// rather than compounding deltas frame to frame.
    @State private var startPan: CGSize?
    @State private var isHovering = false

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(width: (grabRect ?? fitRect).width, height: (grabRect ?? fitRect).height)
            .position(x: (grabRect ?? fitRect).midX, y: (grabRect ?? fitRect).midY)
            .onHover { inside in
                // Balanced: a push is only ever popped once, and the layer's own disappearance pops it too (the Space-pan layer
                // is unmounted when Space is released, usually with the pointer still over it).
                if inside, !isHovering { NSCursor.openHand.push(); isHovering = true }
                if !inside, isHovering { NSCursor.pop(); isHovering = false }
            }
            .onDisappear {
                if isHovering { NSCursor.pop(); isHovering = false }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .local)
                    .onChanged { value in
                        if startPan == nil { startPan = panOffset }
                        let base = startPan ?? panOffset
                        // translation ÷ fitRect size == a fit-rect-normalized
                        // delta, the SAME unit `panOffset` is already stored
                        // in — matches `CompareDividerOverlay`'s own
                        // translation-to-fraction conversion.
                        let dx = fitRect.width > 0 ? value.translation.width / fitRect.width : 0
                        let dy = fitRect.height > 0 ? value.translation.height / fitRect.height : 0
                        panOffset = ZoomPanGeometry.clampedPan(
                            CGSize(width: base.width + dx, height: base.height + dy), zoom: zoomScale
                        )
                    }
                    .onEnded { _ in startPan = nil }
            )
            .gesture(
                TapGesture(count: 2).onEnded {
                    zoomScale = ZoomPanGeometry.minZoom
                    panOffset = .zero
                }
            )
            // D6 (IMPROVEMENTS.md): this `Color.clear` drag-capture surface
            // itself is still mouse-only and vends no meaningful
            // accessibility content of its own, so it stays hidden. D8
            // (IMPROVEMENTS.md) has since shipped a keyboard equivalent —
            // `ContentView.handleImagePaneKeyPress`'s arrow-keys-pan/`"0"`-
            // resets path, reusing the SAME `ZoomPanGeometry.clampedPan`
            // this drag gesture calls — so panning/zoom-reset is no longer
            // mouse-only overall, just this one capture layer.
            .accessibilityHidden(true)
    }
}
