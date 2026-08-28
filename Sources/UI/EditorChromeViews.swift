import SwiftUI

/// Small transient overlays the Editor lays over its image pane and control
/// sidebar. Each is a pure function of its inputs — no state, no access to
/// `ContentView`'s own — which is exactly why they were extracted out of it.

/// Small feedback badge while zoomed past fit — same `.regularMaterial`
/// HUD styling `ExportProgressHUD` already uses, so it reads as the
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
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .padding(12)
            .allowsHitTesting(false)
    }
}

struct ExportProgressHUD: View {
    let progress: ExportProgress

    var body: some View {
        VStack(spacing: 6) {
            Text("Exporting \(progress.completed) of \(progress.total)…")
                .font(.caption)
            ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                .frame(width: 220)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(.bottom, 16)
    }
}

/// Stand-in body for an `EditorTab` that has no implementation yet (Filters,
/// Clean Up) — the tab bar mirrors Apple Photos' fixed tab set, so those tabs
/// exist in the UI before their features do.
struct PlaceholderTab: View {
    let message: String

    var body: some View {
        Text(message)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 40)
    }
}
