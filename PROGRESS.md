# Progress

## Current phase
Phase 1 — Foundation: Xcode project, open + display an image in a Metal-backed view.

## Done
- Repo initialized, CLAUDE.md workflow rules in place.
- Xcode project scaffolded via XcodeGen (`project.yml`); `.xcodeproj` is generated,
  gitignored, regenerate with `xcodegen generate`.
- Rendering: `MetalImageView` (MTKView, on-demand redraw) + `ImageRenderer`
  (CIContext-based draw, aspect-fit + centered, CI-to-Metal y-flip) +
  `AspectFit` math with unit tests.
- UI: `ContentView` + `ImageDocumentModel` — Open… via NSOpenPanel, read-only file
  access, EXIF orientation applied, decode-failure alert.
- Reviewer agent ran twice on the diff (FIX FIRST → fixes applied → APPROVE).
- Xcode 26.6 installed; `xcodebuild -scheme PhotoApp build` → BUILD SUCCEEDED;
  `xcodebuild -scheme PhotoApp test` → all 6 `AspectFitTests` pass (required one
  fix: `GENERATE_INFOPLIST_FILE: YES` on the PhotoAppTests target in project.yml).
  `PhotoApp.app` launches and stays running with no crash.
- 6 commits total on `master`.

## In progress / blocked
- **Blocked on the user**: the manual golden-path check (Open… a JPEG/PNG,
  confirm upright orientation + centering, resize the window and confirm re-fit,
  confirm the source file's mtime is unchanged) cannot be done from here — this
  session has no Screen Recording or Accessibility permission, so the native
  app's UI can't be screenshotted or driven. Asked the user to do this pass
  manually and report back.

## Exact next step
1. User manually verifies the golden path (see above) and reports back.
2. If it looks correct: Phase 1 is complete. Do not start Phase 2 (edit engine)
   until the user confirms, per the "one feature per session" / roadmap-order rule.
3. If something's off: fix, re-run the reviewer agent on the diff, get APPROVE,
   commit, re-verify.

## Open reviewer issues
None outstanding — last reviewer verdict was APPROVE.
