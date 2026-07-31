# Progress

## Current phase
Phase 2 — Edit engine: exposure and contrast done; white balance, curves, HSL,
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
- `Sources/EditEngine/EditState.swift` — `Codable`/`Equatable`, `exposureEV`.
- `Sources/EditEngine/EditPipeline.swift` — applies exposure via Core Image's
  built-in `CIExposureAdjust`.
- `Sources/Rendering/ImageRenderer.swift` — `CIContext` explicitly sets
  `workingColorSpace` (extended-range linear sRGB) + `workingFormat` (`RGBAh`),
  satisfying CLAUDE.md's "linear light in a defined working color space"
  instead of relying on framework defaults; output stays sRGB, applied only at
  final render. `draw(in:)` applies the edit pipeline and uses the *edited*
  image's extent throughout (forward-compatible with crop).
- `Sources/UI/ImageDocumentModel.swift` / `ContentView.swift` — exposure slider
  (bottom bar, −5…+5 EV, live readout, Reset button, disabled with no image);
  edit state resets per photo on load.
- Linear-light math verified by rendering through a `CIContext` pinned to the
  same working space: identity, ×2/×0.5/×4, √2 gain at +0.5 EV, alpha
  preservation, highlight-headroom preserved (not clamped).
- Reviewer-approved; user manually confirmed live in the running app.

### Phase 2, Feature 2 — Contrast adjustment (complete, verified live)
- `Sources/EditEngine/EditState.swift` — added `contrast: Double = 0`
  (-1...1, maps to `CIColorControls` factor `1 + contrast`).
- `Sources/EditEngine/EditPipeline.swift` — contrast is applied in the
  **perceptual sRGB-gamma domain, not linear light** — a documented deviation
  from CLAUDE.md's default rule (which CLAUDE.md permits when documented).
  Rationale: a linear-domain pivot at 0.5 sits at ~0.735 perceptual
  brightness, so it crushes photographic middle gray (linear ≈0.214) toward
  black at typical contrast factors — empirically verified against real
  `CIColorControls` behavior before implementing, not just theorized.
  Implementation: `CIColorControls` sandwiched between
  `CILinearToSRGBToneCurve` (encode) and `CISRGBToneCurveToLinear` (decode),
  applied after exposure. The tone-curve filters are exact inverses and don't
  clamp values >1, so exposure's highlight headroom survives the round-trip.
  This encode/decode boundary (`applyPerceptualAdjustments`) is a **shared
  sandwich** — curves and HSL (next up) must be added *inside* it, not given
  their own, since they have the identical perceptual-domain requirement.
- `Sources/UI/ContentView.swift` — second slider (bottom bar, -1...1, live %
  readout, Reset button), same pattern as exposure.
- `Tests/EditEngineTests/EditPipelineTests.swift` — 8 new contrast tests;
  values independently re-derived (not just re-checked) by the reviewer from
  the stated sRGB transfer functions and confirmed correct to ~2e-6.
- All 22 tests pass (6 AspectFit + 16 EditPipeline); build succeeds; reviewer
  APPROVE (2 commits: color-math + tests, then UI); user manually confirmed
  live — visible tonal separation change, no shadow-crushing, composes
  correctly with exposure, Reset works, disabled state correct.
- 13 commits total on `master`.

## In progress / blocked
Nothing blocked. Nice-to-have not yet eyeballed (low risk, not required):
window-resize re-fit behavior, opened-file mtime check.

## Exact next step
Both exposure and contrast are done and verified. Do not start the next Phase
2 sub-feature (white balance, curves, HSL, or crop) without checking with the
user first, per "one feature per session."

**Important architectural note for curves/HSL sessions**: the perceptual
sandwich (`applyPerceptualAdjustments` in `Sources/EditEngine/EditPipeline.swift`)
already exists for contrast — curves and HSL must extend the same sandwich's
guard condition and run *inside* it (between the existing encode/decode
calls), not build their own. Also: the curves session must independently
re-verify highlight-headroom survival with whatever curve filter it uses —
`CIToneCurve` (the likely candidate) clamps to [0,1] control points, unlike
the unclamped tone-curve filters used for contrast, so this can't be assumed
to carry over; may need a custom kernel per CLAUDE.md's Stack section.

## Open reviewer issues
None outstanding — last reviewer verdict was APPROVE (contrast feature, Phase
2 Feature 2).
