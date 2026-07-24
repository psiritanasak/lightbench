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
  All 4 commits made on `master`.

## In progress / blocked
- **Blocked on the user**: full Xcode is not installed on this machine (only
  Command Line Tools), so `xcodebuild build` / `xcodebuild test` cannot run.
  User is installing Xcode via the App Store now.
- As a stand-in, `swiftc -typecheck` against the macOS SDK was run on all Swift
  sources and passed clean — this is not a substitute for a real build/test/run.

## Exact next step
Once Xcode is installed and `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`
succeeds:
1. `xcodegen generate`
2. `xcodebuild -scheme PhotoApp build`
3. `xcodebuild -scheme PhotoApp test` — confirm `AspectFitTests` pass
4. Run the app manually: Open… a JPEG and a PNG (including a portrait photo),
   confirm correct orientation/centering, resize the window, confirm re-fit with
   no distortion. Confirm the opened file's mtime is unchanged (non-destructive
   invariant).
5. Only after all of the above pass: Phase 1 is complete. Do not start Phase 2
   (edit engine) until then, per the "one feature per session" / roadmap-order rule.

## Open reviewer issues
None outstanding — last reviewer verdict was APPROVE.
