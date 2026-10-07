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

/// Same `.regularMaterial` HUD family as `ExportProgressHUD` — an
/// indeterminate spinner, not a percentage bar, since `PhotoEnhancer
/// .enhance` is one atomic async call with no incremental progress signal
/// to report (unlike Export's own per-photo batch loop).
struct EnhancingHUD: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Enhancing…")
                .font(.caption)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(.bottom, 16)
    }
}

/// Stand-in body for an `EditorTab` that has no implementation yet (Clean Up) — the tab
/// bar started as a mirror of Apple Photos' tab set, so that tab exists in the UI before its feature does.
struct PlaceholderTab: View {
    let message: String

    var body: some View {
        Text(message)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 40)
    }
}
