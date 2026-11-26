import SwiftUI

/// Small transient overlays the Editor lays over its image pane and control
/// sidebar. Each is a pure function of its inputs — no state, no access to
/// `ContentView`'s own — which is exactly why they were extracted out of it.

/// Small feedback badge while zoomed past fit — same solid `solidPanel`
/// styling the activity strip uses, so it reads as the
/// same family of transient overlay. Purely informational, matches
/// `zoomScale`'s own "1 = fit" convention (shown as 100%).
struct ZoomPercentageHUD: View {
    let zoomScale: CGFloat

    var body: some View {
        Text("\(Int((zoomScale * 100).rounded()))%")
            .font(.caption)
            .monospacedDigit()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .solidPanel(cornerRadius: 6)
            .padding(12)
            .allowsHitTesting(false)
    }
}

