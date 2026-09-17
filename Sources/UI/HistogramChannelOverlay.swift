/// Which series `HistogramBars` draws on top of its always-present
/// luminance base layer. Replaces that view's old `showChannels: Bool`
/// (Curves v2 slice 3) — a plain bool could only mean "all three RGB
/// channels together or none," which stopped being enough once the tone
/// curve editor needed to show exactly ONE channel's histogram while that
/// channel's curve is being edited (`ToneCurveChannel.histogramOverlay`).
///
/// No `.none` case, deliberately — `Optional<HistogramChannelOverlay>.none`
/// at a call site would read as ambiguous with a hypothetical `.none` case
/// of this type itself; `.luminanceOnly` says the same thing unambiguously.
/// Not `CaseIterable`/`Identifiable`: nothing ever presents this enum in a
/// picker — it is only ever derived from `HistogramDisplayMode` or
/// `ToneCurveChannel`, never chosen directly.
enum HistogramChannelOverlay {
    case luminanceOnly
    case allChannels
    case red
    case green
    case blue
}
