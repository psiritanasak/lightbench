# Progress

## Current phase
Phase 1 — Foundation: Xcode project, open + display an image in a Metal-backed view.

## Done
- Repo initialized, CLAUDE.md workflow rules in place (including quota/safe-pause
  discipline and this PROGRESS.md file).
- Xcode project scaffolded via XcodeGen (`project.yml`); `.xcodeproj` is generated,
  gitignored, regenerate with `xcodegen generate`.
- Rendering: `MetalImageView` (MTKView, on-demand redraw) + `ImageRenderer`
  (CIContext-based draw, aspect-fit + centered) + `AspectFit` math with unit tests.
- UI: `ContentView` + `ImageDocumentModel` — Open… via NSOpenPanel, read-only file
  access, EXIF orientation applied, decode-failure alert.
- Xcode 26.6 installed; `xcodebuild -scheme PhotoApp build` → BUILD SUCCEEDED;
  `xcodebuild -scheme PhotoApp test` → all 6 `AspectFitTests` pass.
- **Golden path manually verified by the user in the live running app**: opened a
  real photo (portrait JPEG, EXIF orientation 1), displays upright, readable,
  correctly centered. This took an extra round: an earlier vertical-flip fix
  (added on the strength of an offline MTLTexture test) actually caused a 180°
  rotated display in the *live* MTKView drawable; removing it fixed it. Root-caused
  by testing the user's real file end-to-end rather than trusting the offline test.
  See `Sources/Rendering/ImageRenderer.swift` for the (scoped, empirical) comment
  explaining this — flagged as a re-verify-later risk for Phase 5 export and Phase 7
  tiled rendering, which will target offscreen textures, the same destination shape
  that misled the original test.
- Reviewer agent ran on every substantive diff (multiple FIX FIRST → fix → APPROVE
  cycles). All commits are reviewer-approved.
- 8 commits total on `master`.

## In progress / blocked
Nothing blocked. Still outstanding before fully closing Phase 1 (nice-to-have,
not required): manually check window-resize re-fit behavior and confirm opened
file mtimes are unchanged (non-destructive invariant) — the non-destructive
invariant is already confirmed by code review (read-only APIs only), and resize
re-fit math is unit-tested, so this is low-risk but not yet eyeballed live.

## Exact next step
Phase 1 core goal (open + display an image in a Metal-backed view) is done and
verified in the live app. Do not start Phase 2 (edit engine) without the user's
go-ahead, per the "one feature per session" / roadmap-order rule — check with
them first.

## Open reviewer issues
None outstanding — last reviewer verdict was APPROVE (commit ab49d2e).
