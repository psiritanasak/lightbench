# Progress

## Current phase
Phase 2 — Edit engine: exposure done; contrast, white balance, curves, HSL,
crop not yet started (build one feature per session, per roadmap order).

## Done
### Phase 1 — Foundation (complete, verified live)
- Repo initialized, CLAUDE.md workflow rules in place (quota/safe-pause
  discipline, this PROGRESS.md file).
- Xcode project scaffolded via XcodeGen (`project.yml`); `.xcodeproj` is
  generated, gitignored, regenerate with `xcodegen generate`.
- Rendering: `MetalImageView` (MTKView, on-demand redraw) + `ImageRenderer`
  (CIContext-based draw, aspect-fit + centered) + `AspectFit` math with unit
  tests.
- UI: `ContentView` + `ImageDocumentModel` — Open… via NSOpenPanel, read-only
  file access, EXIF orientation applied, decode-failure alert.
- Golden path manually verified live: real photo opens upright, readable,
  centered. (One round-trip bug along the way: a vertical-flip "fix" validated
  only against an offline MTLTexture test actually caused 180° rotation in the
  *live* MTKView drawable; removing it fixed it — see the comment in
  `Sources/Rendering/ImageRenderer.swift` for the scoped, empirical explanation
  and the flagged re-verify-later risk for Phase 5 export / Phase 7 tiled
  rendering, which will target offscreen textures like the misleading test did.)

### Phase 2, Feature 1 — Exposure adjustment (complete, verified live)
- `Sources/EditEngine/EditState.swift` (new) — `Codable`/`Equatable`, one field
  `exposureEV: Double = 0`.
- `Sources/EditEngine/EditPipeline.swift` (new) — `EditPipeline.apply(_:to:)`
  applies exposure via Core Image's built-in `CIExposureAdjust`; comment marks
  where WB/contrast/curves/HSL/crop slot in later (not stubbed out yet).
- `Sources/Rendering/ImageRenderer.swift` — `CIContext` now explicitly sets
  `workingColorSpace` (extended-range linear sRGB) + `workingFormat` (`RGBAh`),
  satisfying CLAUDE.md's "linear light in a defined working color space"
  instead of relying on framework defaults; output stays sRGB, applied only at
  final render. `draw(in:)` applies the edit pipeline and uses the *edited*
  image's extent throughout (forward-compatible with the future crop stage).
- `Sources/UI/ImageDocumentModel.swift` / `ContentView.swift` — exposure slider
  (bottom bar, −5…+5 EV, live readout, Reset button, disabled with no image);
  edit state resets per photo on load.
- `Tests/EditEngineTests/EditPipelineTests.swift` (new, 9 tests) — linear-light
  math verified by rendering through a `CIContext` pinned to the same working
  space: identity, ×2/×0.5/×4 at whole EVs, √2 gain at +0.5 EV (proves genuine
  `2^ev` math, not a lookup table), alpha preservation, and a highlight-headroom
  case (0.6 + EV 1 → 1.2, not clamped) proving extended range is really in
  effect.
- All 15 tests pass (6 AspectFit + 9 EditPipeline); build succeeds; reviewer
  APPROVE on the full diff (3 commits: color-math foundation, renderer wiring,
  UI slider); user manually confirmed live in the running app — slider
  brightens/darkens correctly, resets at 0, Reset button works, disabled state
  correct.
- 11 commits total on `master`.

## In progress / blocked
Nothing blocked. Nice-to-have not yet eyeballed (low risk, not required to
close Phase 1): window-resize re-fit behavior, opened-file mtime check.

## Exact next step
**Paused mid-planning for Phase 2, Feature 2 (contrast) — nothing implemented
yet, no code changes this round.** A full plan (with empirical color-science
findings already worked out) is saved at
`/Users/praween/.claude/plans/purring-mapping-pizza.md`. To resume:

1. Read that plan file first.
2. Enter Plan Mode, present that plan (or refresh it if stale) via
   `ExitPlanMode`, get the user's go-ahead, then implement.

Summary of what the plan already resolved, so it doesn't need re-deriving:
contrast can't just use `CIColorControls` directly in this app's linear
working space — empirically verified that a linear-domain pivot (0.5) crushes
photographic middle gray (linear ≈0.214) to black at contrast factor 2.0. The
correct approach is a **perceptual sandwich**: encode linear→sRGB gamma
(`CILinearToSRGBToneCurve`) → `CIColorControls(contrast:)` → decode back to
linear (`CISRGBToneCurveToLinear`), applied after exposure. This is a
*documented deviation* from CLAUDE.md's default linear-light rule (which
CLAUDE.md explicitly permits). The tone-curve filters are exact inverses and
don't clamp >1, so exposure's highlight headroom survives. The plan makes this
encode/decode boundary reusable in `EditPipeline` — curves and HSL (the two
features after this one) must be added *inside* the same sandwich, not given
their own, since they have the identical "must be perceptual" property. Full
worked test values and file-by-file changes are in the plan file.

Do not start any other Phase 2 sub-feature (WB, curves, HSL, crop) instead of
contrast without checking with the user, per "one feature per session."

## Open reviewer issues
None outstanding — last reviewer verdict was APPROVE (exposure feature, Phase
2 Feature 1). Contrast (Feature 2) has not been reviewed — it hasn't been
implemented yet.
