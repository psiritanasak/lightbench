# Photo Editor (Lightroom-style) — Project Memory

## What this project is
A native macOS photo editor with a library/catalog, in the spirit of Lightroom.
Non-destructive editing is the core invariant: **original files are never modified**.
Edits are stored as parameter sets and rendered live on the GPU.

## Stack
- Swift + SwiftUI (AppKit interop where needed)
- Metal / Core Image for the GPU edit pipeline (custom kernels for curves, HSL, WB)
- SQLite via GRDB for the catalog (photos, edits, collections, ratings)
- LibRaw via C++ interop for RAW decoding (Phase 6 — do not start early)
- Xcode project is generated from `project.yml` via XcodeGen (`brew install xcodegen`,
  then `xcodegen generate`); the `.xcodeproj` itself is gitignored and regenerable.
- Build/test from CLI: `xcodegen generate && xcodebuild -scheme PhotoApp build` /
  `xcodebuild -scheme PhotoApp test` (scheme: PhotoApp)

## Architecture principles
- Non-destructive: edit state = ordered list of adjustment params, serialized to the DB
  (and optionally XMP-style sidecars). Replaying the same params must be deterministic.
- Edit pipeline order is fixed: decode → WB → exposure → contrast → curves → HSL → crop → output transform.
- All image math in linear light in a defined working color space; convert to display/sRGB only at output. Document any deviation.
- DB access never blocks the main thread. Thumbnails generate on a background queue.
- Keep modules separated: Catalog / EditEngine / Rendering / UI. No UI imports in EditEngine.

## Roadmap (build strictly in this order)
1. Foundation: Xcode project, open + display an image in a Metal-backed view
2. Edit engine: exposure, contrast, white balance, curves, HSL, crop
3. Non-destructive pipeline: param serialization, edit history, undo
4. Library: import, catalog DB, thumbnail grid, ratings/flags, collections
5. Presets + export: save/apply presets, batch export (resize, quality, format)
6. RAW support: LibRaw bridge, demosaic, camera profiles
7. Polish: tiled rendering for large images, perf, edge cases

One feature per session. Do not start a later phase while an earlier one has open issues.

## Workflow rules (important)
- Model is `opusplan`: ALWAYS enter Plan Mode before starting a new feature so the
  plan is produced by the stronger model. Keep plans scoped to ONE feature.
- After completing a feature and BEFORE any git commit, invoke the `reviewer` agent
  on the diff (`git diff HEAD`).
- If the reviewer verdict is FIX FIRST: fix every listed issue, then re-run the
  reviewer. Only commit on APPROVE.
- Never commit shader or color-math changes without a reviewer pass.
- Write unit tests for all edit math (curves interpolation, WB scaling, color
  conversions) — these are cheap to test and expensive to debug visually.
- Commit small and often, one logical change per commit, imperative commit messages.
- Build and run tests via xcodebuild after every significant change; fix failures
  before moving on.

## Conventions
- Swift: SwiftLint defaults, no force-unwraps outside tests, `// MARK:` sections.
- Shaders live in `Sources/Rendering/Shaders/`, one kernel per file, commented with
  the math they implement and its source/reference.
- DB migrations are append-only, in `Sources/Catalog/Migrations/`.
