import SwiftUI

/// The Place Spots layer: draws EVERY spot as a thin circle (the selected one is drawn, with its handles, by
/// `RetouchOverlayView` on top of this) and, while the tool is ARMED, captures the pointer over the whole pane:
///  - press on an existing spot -> select it (no new spot);
///  - press elsewhere inside the picture and release -> a new spot at the press point; a drag sizes it (its circle follows the
///    pointer) and a plain click uses the remembered radius. The spot is created ONCE, on release, so one gesture is one undo step.
/// Presses outside the picture do nothing. Identity geometry only (the caller gates that — see `RetouchSpot`).
/// All the maths is `RetouchOverlayGeometry` (unit-tested); this view only wires gestures to it. `.accessibilityHidden(true)` is
/// defensible only because every action here has a sidebar equivalent (Add Spot button, the spot rows, the detail sliders).
struct RetouchSpotsOverlay: View {
    /// Where the picture is DISPLAYED, in pane coordinates: the fit rect at fit size, the zoomed rect when zoomed (callers pass
    /// `ZoomPanGeometry.displayedRect`). The name is historical; every `RetouchOverlayGeometry` call takes it as the picture's rect.
    let fitRect: CGRect
    /// The pane's size: the layer clips itself to it (a zoomed picture's circles would otherwise draw over the tab bar and sidebar)
    /// and accepts presses only on the visible part of the picture.
    let paneSize: CGSize
    let spots: [RetouchSpot]
    let selectedID: UUID?
    let isArmed: Bool
    /// The radius a plain click gives a new spot (the last one the user sized).
    let defaultRadius: Double
    let onSelect: (UUID) -> Void
    /// `(normalized position, radius, wasDragSized)`.
    let onPlace: ((x: Double, y: Double), Double, Bool) -> Void

    /// The press in progress. A `@GestureState`, not `@State`: it resets itself if the gesture is CANCELLED (Escape disarming mid-drag, a
    /// window or app switch), where `onEnded` never runs and a plain `@State` would leave a stale preview ring and a wrong drag origin.
    private struct Press: Equatable { var start: CGPoint; var current: CGPoint }
    @GestureState private var press: Press?
    /// The picture rect at the START of the current press (`RetouchOverlayGeometry.recordPress`), to drop a placement or selection
    /// if the view zoomed/panned mid-press. A plain `@State`: a cancelled gesture can leave it stale, and it is replaced when the next
    /// press starts at a different point.
    @State private var pressRecord: RetouchOverlayGeometry.PressRecord?

    var body: some View {
        ZStack {
            ForEach(spots.filter { $0.id != selectedID && $0.isFinite }) { spot in
                ring(at: RetouchOverlayGeometry.centerPoint(of: spot, in: fitRect),
                     radius: max(RetouchOverlayGeometry.radiusPoints(of: spot, in: fitRect), 4), color: .white.opacity(0.85))
                    .allowsHitTesting(false)
            }
            if isArmed, let preview = creationPreview {
                ring(at: preview.center, radius: max(preview.radius, 4), color: .yellow)
                    .allowsHitTesting(false)
            }
            if isArmed {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(placeGesture)
            }
        }
        // Clip to the PANE, anchored top-left inside whatever the parent offers (the pane size can lag a resize by one update; a plain
        // fixed frame would be CENTRED in a mismatched parent and shift every ring).
        .frame(width: paneSize.width, height: paneSize.height)
        .clipped()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityHidden(true)
        // A press cancelled by disarming (Escape mid-press) never reaches `onEnded`; drop its record so the next press cannot inherit it.
        .onChange(of: isArmed) { _, _ in pressRecord = nil }
    }

    /// The circle a new spot would get if the pointer were released now (nil unless a press on empty picture is in progress).
    private var creationPreview: (center: CGPoint, radius: CGFloat)? {
        guard let press, case let start = press.start, case let current = press.current,
              RetouchOverlayGeometry.acceptsPress(at: start, pictureRect: fitRect, paneSize: paneSize),
              RetouchOverlayGeometry.hitTest(point: start, spots: spots, fitRect: fitRect) == nil,
              let r = RetouchOverlayGeometry.newSpotRadius(fromCenter: start, dragPoint: current, fitRect: fitRect, defaultRadius: defaultRadius)
        else { return nil }
        return (start, CGFloat(r) * RetouchOverlayGeometry.minSide(fitRect))
    }

    private func ring(at point: CGPoint, radius: CGFloat, color: Color) -> some View {
        ZStack {
            Circle().stroke(Color.black.opacity(0.5), lineWidth: 3)
            Circle().stroke(color, lineWidth: 1.2)
        }
        .frame(width: radius * 2, height: radius * 2)
        .position(point)
    }

    private var placeGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .updating($press) { value, state, _ in
                state = Press(start: value.startLocation, current: value.location)
            }
            .onChanged { value in
                pressRecord = RetouchOverlayGeometry.recordPress(pressRecord, startLocation: value.startLocation, currentRect: fitRect)
            }
            .onEnded { value in
                let recorded = pressRecord?.rect
                defer { pressRecord = nil }
                // Stale coordinates (the view zoomed/panned during the press): neither select nor place.
                guard RetouchOverlayGeometry.isPlacementStillValid(pressRect: recorded, currentRect: fitRect) else { return }
                let start = value.startLocation, end = value.location
                if let hit = RetouchOverlayGeometry.hitTest(point: start, spots: spots, fitRect: fitRect) {
                    onSelect(hit)
                    return
                }
                guard RetouchOverlayGeometry.acceptsPress(at: start, pictureRect: fitRect, paneSize: paneSize),
                      let position = RetouchOverlayGeometry.normalizedPoint(from: start, in: fitRect),
                      let radius = RetouchOverlayGeometry.newSpotRadius(
                          fromCenter: start, dragPoint: end, fitRect: fitRect, defaultRadius: defaultRadius)
                else { return }
                let sized = hypot(end.x - start.x, end.y - start.y) >= RetouchOverlayGeometry.minimumSizingDrag
                onPlace(position, radius, sized)
            }
    }
}
