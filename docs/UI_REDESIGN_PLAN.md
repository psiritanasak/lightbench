# Lightbench UI/UX redesign plan (2026-11-10)

Status: PROPOSAL. Nothing here is built. The user has not yet approved the
direction or the open decisions in section 5.

How this was made: a read of the UI source (`Sources/UI`, `Sources/App`) on
2026-11-10, plus the earlier live notes in IMPROVEMENTS.md D58, then a short
screenshot pass the same day (slice R0 below: twelve window captures of a
throwaway build). "Today" statements come from the code unless R0 says it was
seen; file:line references were correct on 2026-11-10 and will drift.

## 1. How to use this plan (Opus / Sonnet)

- One slice = one session = one feature, per CLAUDE.md. Run `/clear` between slices.
- Opus (Plan Mode): read the slice, read the files it names, write the
  detailed plan. Sonnet: implement. The `reviewer` agent (Opus) reviews
  `git diff HEAD` before every commit; commit only on APPROVE.
- Slices are ordered. A later slice may assume the earlier ones in its own
  track; the tracks (A Library, B Editor, C shared) are independent of each
  other except where "Needs" says so.
- The working tree has UNCOMMITTED work on the justified-rows grid
  (`Sources/Catalog/JustifiedRows.swift`, `LibraryGridView.swift`, migration
  020). Finish, review and commit that first; do not start slice A1 on top of
  an unreviewed diff in the same file.
- Rules that every slice keeps:
  - No slice changes `EditState`, the pipeline, the catalog schema or any file
    operation. This is a UI plan. If a slice seems to need one of those, stop
    and ask.
  - Pure logic goes in a small testable type (the pattern of `SidebarRows`,
    `CellChrome`, `LibraryFilterState`, `EditorRailActionRules`); the view
    stays thin. `ContentView.swift` is already at the type-checker's limit:
    add new UI as its own view / `ViewModifier` file, not inline.
  - Keep the look rules `ThemeTests` enforces (no materials, no system accent,
    selection is never blue, colour only where it carries meaning).
  - A new keyboard shortcut needs its row in `KeyboardShortcutCatalog`
    (`KeyboardShortcutCatalogTests` fails otherwise).
  - Screen automation needs the user's permission each time (see memory). A
    slice's "Live check" list is for the user, or for an automated pass the
    user has allowed, on scratch photos only.

## 2. What is wrong today (the short diagnosis)

The feature set is at Lightroom level; the way to reach the features is not.
Five problems, most important first.

1. **The Library grid does not behave like a Mac photo grid.** One click on a
   thumbnail opens the Editor (`LibraryGridView.swift:1065`). Selecting is
   only possible through a 22 pt checkbox that is dimmed until hover. There is
   no ⇧-click, ⌘-click, ⌘A or Delete, no right-click menu on a cell (per-photo
   actions sit behind a `folder.badge.plus` button), and no drag onto a
   collection.
2. **Commands are hard to find.** The Photo menu has 25 items for two
   different modes. Auto Stack, Find Duplicates, Recently Deleted, Move
   Rejected to Trash and Backup exist only in the menu bar. The toolbar's
   selection menu (15 items, destructive ones mixed in) only exists while
   something is selected, yet an empty state tells the user to use it
   (`EmptyStates.swift:79`). There is no shortcut for Library ↔ Editor, for
   the rail tabs, or for before/after.
3. **Routine results interrupt the user.** There are 30 `.alert(` sites. Many
   report success or "nothing to do" (Export finished, Paste summary, "already
   level", Imported look) and need an OK click. Export has no Cancel; a folder
   import shows no progress.
4. **The Edit panel is a column of closed titles.** Every section starts
   collapsed; up to 10 sections and 46-59 sliders in one scroll; a header does
   not show whether its section holds edits and has no reset or on/off; the
   scroll bar is hidden. There are two histograms, and the pinned one's
   channel mode is set by a picker inside the closed Light section. Double-
   click does not reset a slider. "Reset Adjustments" also resets Red-eye
   (another tab) and skips RAW and Point Color.
5. **The parts do not match.** Nine sheets use seven widths, two paddings and
   four different close-button conventions (Export has no Return/Esc at all).
   Section headings differ per tab. The theme has colour tokens but no type,
   spacing or radius tokens: 19 hard-coded font sizes, 102 literal paddings,
   37 literal corner radii, 18 raw `.red`.

## 3. The direction

Keep the dark, flat, neutral look that shipped in October. This is not a
restyle; it is about behaviour and structure.

- **Library = select, then act.** Click selects, double-click opens. The same
  actions are in a right-click menu, a selection bar and the menu bar, with
  the same names everywhere.
- **Editor = see state at a glance.** Open sections, edit dots, per-section
  reset, one histogram.
- **Quiet feedback.** A toast for "done" and "nothing to do"; an alert only
  for an error the user must read or a decision.
- **One kit.** One sheet layout, one section header, one set of type / spacing
  / radius tokens, enforced by tests like the colours already are.

Not in this plan, on purpose: merging Library and Editor into one view (D58
item 6; consider only after tracks A and B), a list view, a navigator
minimap, light mode, new edit features.

## 4. Slices

Each slice: **Today** (what the code does), **Change**, **Files**, **Tests**,
**Live check**, **Watch out**.

### R0. Baseline screenshots: DONE 2026-11-10 (partly)

Release build of the working tree (it includes the uncommitted justified-rows
work) under the throwaway bundle id `com.photoapp.PhotoApp.uibaseline`, 24
synthetic JPEGs, window-only captures at 1440x860 and 900x600. Container
deleted afterwards; the real catalog and prefs were not touched. Twelve
screenshots are in the session scratchpad (temporary; copy them somewhere
durable before C3 needs them for a before/after comparison).

Captured: Editor with no photo, Library, Library with 3 selected, Editor
Edit / Looks / Masks / Crop, Export sheet, Cull loupe, Library and Editor at
900 pt. NOT captured: Retouch, Red-eye, the other eight sheets, Cull Compare
and Survey, menus, the justified layout, any hover state, a RAW photo.

What the screenshots confirm:
- Point 1: one click on a thumbnail opened the Editor. A selected cell shows
  only its small checkmark; the photo itself is not highlighted (the white
  ring in the capture is keyboard focus, not selection).
- Point 2: the Library toolbar is five or six unlabelled icons; the selection
  menu is a bare checkmark with no count.
- Point 3: importing the scratch folder ended in a modal "Photo Catalog /
  Imported 24 photos. / OK" alert.
- Point 4: the Edit panel opens as eight closed titles and about half the
  panel empty, with "Reset Adjustments" in the middle of the window. Every
  slider row shows its reset arrow even at the default value.
- Point 5: the Export sheet is the narrow one, with two long help paragraphs
  inline.

New findings (not in section 2; each is assigned to a slice below):
- **N1 The app opened in the Editor with "No photo open"** after a folder
  was opened with it, with the import alert on top. A launch that imports
  should land in the Library. → A1 (small, or its own fix).
- **N2 Surfaces are not all solid.** The Library grid area, the title bar
  above the Editor canvas and the Export sheet show a green-grey tint (the
  desktop showing through, by the look of it), while the sidebars are the
  solid `Theme.panel`. The Editor canvas is pure black next to the 0.11
  panel. The October "solid surfaces" pass did not reach these. → C3 (add
  `Theme.canvas` / a solid window and sheet background; decide black vs
  panel-grey for the canvas).
- **N3 At 900 pt the filter bar truncates** to "Oldes…", "Any R…", "All
  Fla…", "All La…", "All Ke…" and the search field shrinks to ten characters.
  A5 is needed, not optional.
- **N4 At 900 pt the empty sidebar takes 260 of 900 pt.** → A4: a collapse
  toggle for the sidebar, and a narrower default.
- **N5 At 600 pt height the rail's lower actions (History, Compare,
  Filmstrip, Enhance) are below the fold** with no scroll indicator. → B4:
  shortcuts and View-menu items for them make this harmless; also consider
  moving Undo / Redo to the title bar.
- **N6 Cull has a ~50 pt empty band above its top bar** and no window
  buttons (the toolbar is hidden). → B5 or its own small slice.
- **N7 "New Collection…" and "Save Current Filters…" read as list rows**, the
  second one greyed. → A4 (already planned as "+" buttons).
- **N8 A click on the section title "Light" did not open it; a click on the
  chevron did.** Seen once with a synthetic click, so check by hand; if true
  the whole header row must toggle. → B1.
- Looks, Masks and Crop look tidy at this size; the Masks tab is seven text
  buttons and an otherwise empty panel (B5).

### Track A: Library

#### A1. Click selects, double-click opens
- **DONE 2026-11-10** (CLAUDE.md "Library grid layouts + selection", IMPROVEMENTS.md D90). Decisions taken: D-1 yes; Space opens the
  Editor; plain arrows move the selection too (user, 2026-11-10); rating / flag / label keys act on the focused cell only. The click count
  is read from `NSApp.currentEvent` in one tap gesture (no delay seen; not timed). N1 (launch lands in the Editor) was NOT done here.
  The live check also fixed scroll-to in both layouts. The text below is the original brief.
- **Today**: `.onTapGesture(perform: onTap)` on the whole cell opens the
  Editor; `selectedPhotoIDs` changes only through the checkbox; keys in
  `LibraryGridView.swift:432-460`.
- **Change**:
  - Click = select only this photo (and focus it). ⌘-click = toggle. ⇧-click
    = range from the anchor in `displayedPhotos` order. Click on empty grid
    space = clear.
  - Double-click or Return = open in the Editor. Space = open too (decision
    D-2 may change this).
  - ⌘A = select all shown; ⌘D or Esc = clear; ⇧+arrows extend the selection.
  - A selected cell gets `Theme.selectedOutline` + `selectedFill` behind it.
    The checkbox stays (it is the touch-free way to add to a selection) but is
    no longer the only way.
  - A collapsed stack selects as it does today through its checkbox (the
    cover stands for the stack); keep that rule, do not invent a new one.
- **Files**: new pure `GridSelection` (in `Sources/Catalog` next to
  `LibraryFilterSort`, or `Sources/UI`): input = ordered ids, current set,
  anchor, the click + modifiers; output = new set + anchor. `LibraryGridView`
  wiring; `CatalogModel.selectedPhotoIDs` stays the store.
- **Tests**: `GridSelectionTests` (plain / ⌘ / ⇧ / ⇧ after ⌘ / anchor gone
  after a filter change / select-all / stack cover). A source-pin test that
  the cell no longer opens on a single tap.
- **Live check**: all of the above by hand; double-click speed feels right
  (SwiftUI delays a single tap when a double-tap recogniser is attached:
  measure it; if the delay is visible use an AppKit click-count handler
  instead and say so).
- **Watch out**: Export, Trash, Rename, Keywords and Cull read the selection;
  their meaning must not change. Keys 0-5 / P X U act on the FOCUSED cell
  today. Decide in the plan whether they act on the whole selection once
  click selects (Lightroom: the active photo only, unless auto-sync). Default:
  keep "focused cell only" and state it in the shortcut window.

#### A2. Right-click menu and a selection bar
- **Needs**: A1.
- **Today**: per-cell `Menu` behind `folder.badge.plus`
  (`LibraryGridView.swift:914-1030`); toolbar "n Selected" menu with 15 items
  (`ContentView.swift:1860-1963`).
- **Change**:
  - One `PhotoActionMenu` description (pure data: groups of items with title,
    enabled rule, destructive flag) used by BOTH the cell's `.contextMenu` and
    the menu bar, so names can no longer differ ("Merge to HDR (n)…" vs
    "Merge Photos to HDR…" today). Right-click on an unselected cell acts on
    that cell; on a selected cell, on the selection (the rule `FaceMarking.
    targets` already uses).
  - Groups, in order: Open in Editor · Rating / Flag / Label · Add to
    Collection ▸ · Keywords… / Info… · Copy / Paste Settings · Stack ▸ ·
    Virtual Copy · Merge ▸ · Metadata (XMP) ▸ · Rename… / Locate… · Remove
    from Library / Move to Trash… (last, separated).
  - Replace the toolbar selection menu with a **selection bar**: a 36 pt bar
    (`Theme.Metrics.barHeight`) that slides in above the size-slider bar
    while 2+ photos are selected: "n selected", then Rate / Flag / Label,
    Add to Collection, Keywords, Export, and a "More" menu (the same
    `PhotoActionMenu`), Clear on the right.
  - The cell's `folder.badge.plus` button becomes an ellipsis that opens the
    same menu.
- **Files**: new `PhotoActionMenu.swift` (model) + `LibrarySelectionBar.swift`;
  `LibraryGridView`, `ContentView` toolbar, `PhotoAppApp` commands.
- **Tests**: menu model (every item has one definition; enabled rules for
  empty / single / multi / missing / stack / busy); a source test that the
  toolbar no longer builds its own item list. Fix `EmptyStates.swift:79`'s
  text.
- **Watch out**: the busy gates (`fileToolBusy`, `toolSheetIsBusy`,
  `RenameBusyState`) must be read from the SAME rules the menu bar uses
  today. Move, do not rewrite, them.

#### A3. Menu bar and shortcuts
- **Today**: Photo menu, 25 items; File has Backup / Copy Photos; no View
  menu; no Library ↔ Editor shortcut.
- **Change**:
  - **View**: Library (⌘1), Editor (⌘2), Cull (⌥⌘C, moved here), then
    Filmstrip, Before/After (`\`), Compare ▸, Square Grid / Justified Rows,
    Show Photos in Subfolders. G = Library and E = Editor as bare keys when no
    text field has focus (decision D-3).
  - **Photo**: only per-photo actions (rating/flag/label submenus, keywords,
    info, copy/paste settings, rotate, virtual copy, stack ▸, Revert to
    Original, which has no menu item today).
  - **Library** (new): Find Duplicates…, Auto Stack…, People…, Merge ▸, XMP
    ▸, Rename Files…, Move Rejected to Trash…, Recently Deleted….
  - **File**: Import ▸, Export… (⇧⌘E), Back Up / Restore.
  - Editor tabs: ⌥1…⌥6 or bare letters (decision D-3).
  - Items that cannot apply in the current mode are hidden where the menu is
    mode-specific (Library menu in the Editor: disabled as a whole).
- **Files**: `PhotoAppApp.swift`, `AboutAndHelp.swift`,
  `KeyboardShortcutCatalog.swift`.
- **Tests**: the catalog test already pins shortcuts; add one that no
  shortcut is used twice.
- **Watch out**: `CullWiringTests` pins which commands are off while culling.

#### A4. Sidebar: counts, inline rename, drag to collection
- **Today**: counts on folders only; New / Rename / Save Smart use an alert
  with a text field (`CollectionSidebarView.swift:90-172`); no drag.
- **Change**: counts on All Photos, collections and smart collections (the
  model computes them once, as `folderPhotoCounts` does); rename in place in
  the row (Return commits, Esc cancels) and "New Collection" creates a row
  already in rename; drag selected thumbnails onto a collection row to add
  them (row highlights as a drop target); a "+" at the right of the
  COLLECTIONS and SMART COLLECTIONS headers replaces the action rows.
- **Files**: `SidebarRows.swift`, `CollectionSidebarView.swift`,
  `CatalogModel`, `LibraryGridView` (drag source).
- **Tests**: `SidebarRows` count + rename-state model; drop target rule (not
  onto smart collections or folders).
- **Watch out**: smart-collection counts cost a query per collection: measure
  on a 600-photo catalog before shipping, and compute off the main thread.
  Dragging must not start the double-click or the ⇧-range.

#### A5. Filter bar
- **Today**: 6-7 fixed-width pop-ups + search in one row; a hint line that
  appears below and pushes the grid (`LibraryFilterBar.swift`).
- **Change**: search field first and wide; Sort moves to the right end next
  to the grid-layout buttons (it is not a filter); filters stay as chips but
  the row wraps with `ViewThatFits` into "Filters ▾ (n)" when the window is
  narrow; the scan / "can't read" line becomes a fixed-height status slot so
  the grid never jumps.
- **Tests**: `LibraryFilterState` already covers the logic; add the narrow-
  layout choice as a pure function of width.
- R0 showed the bar truncating at 900 pt (N3): this slice is needed.

#### A6. Info panel (optional, decision D-4)
- A right-hand panel in the Library (toggle ⌘I) for the focused photo:
  preview, file name, capture data (`photo_metadata`), rating / flag / label,
  title / caption, keywords. Edits use the existing sheet models. The Edit
  Info sheet stays for multi-photo edits.
- First step toward "one space" (D58 item 6): the Library gains the right-
  hand column the Editor has.

### Track B: Editor

#### B1. Section header: edit dot, reset, on/off
- **Today**: `AdjustSectionContainer` (`AdjustTabView.swift:1972-1987`) is a
  `DisclosureGroup` with a title only.
- **Change**: a custom header row: chevron, title, a small `Theme.markOn` dot
  when the section differs from its defaults, and on hover a reset button
  (`arrow.uturn.backward`, one undo step named "Reset Light" etc.). Decision
  D-5: also an eye toggle that shows the photo with that section's fields at
  identity while held (a preview only; never written to the sidecar).
- **Files**: new pure `AdjustSection` enum in EditEngine: for each section,
  `isEdited(EditState)` and `resetting(EditState)`. Build both from ONE field
  list per section, and add a test that every `EditState` field that the Edit
  tab shows belongs to exactly one section (use `EditStateDiff`'s Mirror walk
  so a new field fails the test instead of being forgotten).
- **Also fix here**: "Reset Adjustments" = the union of the Edit-tab sections
  (so it stops touching Red-eye, and the plan must state what it does with
  RAW and Point Color; default: includes Point Color, leaves the RAW section
  to its own reset, because `rawDecoderVersionPin` must survive).
- **Tests**: per-section edited/reset; the coverage test above; mutation-check
  one field.
- **Watch out**: Curve and Color Grading already have their own per-channel /
  per-range resets; keep them, the header reset clears the whole section.

#### B2. Panel defaults and the histogram
- **Today**: all sections collapsed; scroll bar hidden; two histograms; the
  pinned header's channel mode comes from the Levels picker inside Light.
- **Change**: Light and Color open on first run (stored state wins after
  that); ⌥-click on a header = solo (open this, close the others); show the
  scroll bar; ONE histogram: the pinned header gets the Luminance / RGB
  switch (click the histogram to cycle, or a small picker), and the Levels
  block reuses that header instead of drawing a second one (the Levels
  handles can be drawn under the pinned histogram while Light is open:
  decide in the plan, it is the harder half; minimum = move the picker).
- **Watch out**: CLAUDE.md says the pinned histogram excludes Levels while the
  Levels one is the Levels input. If both cannot be one view, keep two but
  give each its own, visible, mode control.

#### B3. Slider row
- **Today**: `EditControlRows.swift:41-110`: label, readout, reset icon;
  click the readout to type; no double-click reset.
- **Change**: double-click on the label or the track resets (one undo step);
  the readout shows a faint field outline on hover so typing is discoverable;
  the reset icon appears only on hover or when the value is not default
  (less noise in a 46-slider panel); ⌥-drag = fine (÷4).
- **Tests**: `ThinSlider` gesture maths (fine drag); reset rule.
- **Watch out**: a double-click must not also move the thumb to the click
  point first (two undo steps / a flash). The tone curve deliberately rejects
  double-click (`ToneCurveEditorView.swift:242-246`): leave it.

#### B4. Before/after and Editor shortcuts
- `\` toggles the unedited photo while held or toggled (uses the existing
  `comparisonOriginal()`); Y = Side by Side; the rail tabs get their keys
  (A3 decides which); ⌘⇧R = Revert. A "Before" chip on the canvas while it
  is showing the original.
- Small; can be folded into A3 if both are planned together.

#### B5. Masks, Retouch, Crop panels use the same parts
- **Today**: heading styles differ per tab; mask "add" buttons are a ragged
  text grid (2/2/2/1); mask detail is one long list under caption headers;
  Crop has a `.headline` between dividers.
- **Change**: every tab uses B1's header component for its groups. Masks: a
  4-column grid of icon + caption tiles for the 7 kinds (the row icons
  already exist), a mask list with an eye per mask if `Mask` already has an
  enabled flag (if it does not, no eye: this plan adds no `EditState`
  fields), detail split into collapsible Adjustments / Shape / Combine.
  Crop: groups Auto, Straighten & Perspective, Rotate & Flip, Aspect, Insets.
  Long help paragraphs (Style ×3, Retouch, Depth) move behind a "?" popover,
  leaving one line.
- **Tests**: `ThemeTests`-style source lint: no `DisclosureGroup` outside the
  shared header file.

### Track C: shared kit

#### C1. Toasts and progress
- **Session 1 DONE 2026-11-11** (CLAUDE.md "Toasts and activity strip", IMPROVEMENTS.md D91; live-checked 2026-11-11 on a throwaway build:
  toast, hover pause, Show in Finder, strip, Cancel, sheet pause, Enhance, an error alert and Cull keys all passed). Shipped: the kit
  (`Feedback`, `FeedbackClassifier`, `FeedbackInbox`, `ToastTimeline`, `ToastCenter`, `ToastView`, `feedbackAlert`), Paste Settings /
  Enhance / Export converted, one activity strip for Export and Enhance, Export Cancel. Decisions taken: a result with anything not
  written is ALWAYS an alert (no "toast with Details"); a toast is not drawn above a sheet, its clock pauses instead; a user-stopped
  export is a warning toast stating the count. **Session 2 DONE 2026-11-13** (commits 3bdf7e3 to c49670b, not pushed): every result site converted (catalog results, Rename,
  the Editor tools, Import Look, Lightroom, Merge, XMP, Trash, Catalog Backup, Copy Photos, and the last three window alerts),
  an import activity row, the five dialog HUDs folded into the strip, and a fix so a failed paste onto the open photo is
  reported. `ContentView` has no raw alert left. Not live-checked yet apart from the Library toast placement (IMPROVEMENTS.md D92).
- **Today**: 30 `.alert(`; success and "nothing to do" messages are modal.
  `ExportProgressHUD` has no Cancel; folder import has no progress UI.
- **Change**:
  - `ToastCenter` (an `ObservableObject` in the environment) + `ToastView`:
    a `solidPanel` chip at the bottom centre, 4 s, hover pauses, optional one
    action ("Show in Finder", "Undo"), VoiceOver announcement, queue of one
    (a new toast replaces the old).
  - A pure `Feedback` classifier: each message a model produces is `.done`,
    `.nothingToDo`, `.warning` or `.error`. Toast for the first two (and
    warnings without a decision); alert stays for errors and confirmations.
    Convert: Export, Enhance, Paste Settings, Rename result, Import Look,
    Auto Straighten / Upright / Auto Crop "already…", Spot "no source",
    import / stack summaries from the "Photo Catalog" alert, XMP / Backup /
    Copy Photos results.
  - Models stop producing one string for both cases: return a small result
    type (`ExportModel`, `EnhanceModel`, `PasteSettingsModel`, the
    `importStatusMessage` sites in `CatalogModel`).
  - One **activity** strip for long jobs (import, export, enhance, scans):
    text, bar, Cancel where the engine supports it. Export cancel = stop
    after the current photo (the plan must read `PhotoExporter` first; if a
    clean stop is not cheap, ship the strip without Cancel and log it).
- **Tests**: classifier table; toast queue/timeout with an injected clock; a
  source test that counts `.alert(` and lists the allowed ones.
- **Watch out**: a result that reports skipped or failed items (Paste "1
  skipped", Trash partial, XMP unparseable) is NOT a success toast: it stays
  an alert, or a toast with a "Details" action. The user must never lose the
  information that something was not written.

#### C2. One sheet layout
- **Today**: widths 380 / 460 / 460 / 560 / 580 / 640 / 640 / 780; padding
  `.padding()` or 20; titles hand-made; close button is "Done" prominent,
  "Done" flat or "Cancel"; Export has no default/cancel action; Auto Stack
  puts Apply before Done; errors in `.red` or amber.
- **Change**: a `SheetScaffold(title:, size: .small 460 / .medium 580 /
  .large 780) { content } footer: { ... }`: title row, 20 pt padding, a
  pinned footer with status text on the left and buttons on the right in
  macOS order (Cancel, then the primary; "Done" alone is flat + Esc AND
  Return). Rules: a sheet that applies live has Done only; a sheet that
  commits has Cancel + a verb. Add `Theme.error` (red) and use `Theme.warning`
  only for cautions. Export becomes `.medium` with its options grouped
  (File, Image, Metadata, Watermark) and gets Return / Esc.
- **Files**: new `SheetScaffold.swift`; the nine sheet views; `Theme.swift`.
- **Tests**: lint: every `*SheetView` uses `SheetScaffold`; no `.red` in
  `Sources/UI` outside the reject flag and delete icons (list them).
- One sheet per commit, so a visual problem is easy to bisect.

#### C3. Type, spacing and radius tokens
- **Today**: none; 19 `.font(.system(size:`, 102 literal paddings, 37 literal
  radii.
- **Change**: `Theme.Font` (title, section, body, caption, micro, mono),
  `Theme.Space` (xs 4, s 8, m 12, l 16, xl 20), `Theme.Radius` (s 4, m 6,
  l 10), `Theme.Metrics` for rail / filmstrip / grid values that are literals
  today; sweep `Sources/UI`; extend `ThemeTests` to ban the literals (with a
  short allow-list for geometry code such as overlays and the curve editor).
- **Rule for the sweep**: map each literal to the NEAREST token only when
  the difference is at most 2 pt; otherwise keep it as a named metric. This
  slice must not visibly change any layout; compare with R0's screenshots.
- Do this LAST in its track or FIRST before A/B work, never in the middle:
  it touches every UI file and will conflict with any open branch. Default:
  last.
- Also here: delete the dead `EditorTab.cleanUp` case; share the flag /
  label / star controls between `CullView` and `EditorRatingBar`.

## 5. Decisions the user must make (defaults in brackets)

- **D-1** Single click selects, double-click opens. [yes: it is the base of
  track A; without it A1/A2 are dropped]
- **D-2** Space in the grid: open in the Editor, or a quick full-window
  preview that Space closes again. [open in the Editor; a preview is a later
  slice]
- **D-3** Bare-letter shortcuts (G Library, E Editor, `\` before/after, tab
  letters) versus only ⌘/⌥ chords. [bare letters, as in Lightroom; they are
  ignored while a text field has focus]
- **D-4** Library info panel (A6). [later, after A1-A4]
- **D-5** Per-section eye (bypass preview) in B1. [dot + reset only first;
  the eye as its own slice]
- **D-6** Order. [R0, A1, C1, B1, A2, B2, B3, A3 + B4, C2, A4, B5, A5, C3]

## 6. Order and size

| # | Slice | Size | Risk | Why here |
|---|---|---|---|---|
| 0 | R0 baseline | done | | see its results |
| 1 | A1 click selects | done 2026-11-10 | | see the slice |
| 2 | C1 toasts + progress | L | medium (many call sites) | removes the most interruptions |
| 3 | B1 section header | M | low | makes the Edit panel readable |
| 4 | A2 right-click + selection bar | L | medium (busy gates) | needs A1 |
| 5 | B2 panel defaults + histogram | S-M | low | |
| 6 | B3 slider row | S | low | |
| 7 | A3 + B4 menus and shortcuts | M | low | after A2 so names come from one model |
| 8 | C2 sheet scaffold | M | low | |
| 9 | A4 sidebar | M | medium (drag vs click) | |
| 10 | B5 tool panels | M | low | |
| 11 | A5 filter bar | S | low | R0 showed truncation at 900 pt |
| 12 | C3 tokens | L (mechanical) | low, wide | last, touches everything |

C1 and C2 can each be split over two sessions (the kit, then the call sites)
if a session runs long. Tracks A and B touch different files (except
`ContentView.swift`), so A-slices and B-slices can run in parallel worktrees
the way D74 / D86 were built.

## 7. What is not verified

- R0 covered 12 views only; menus, most sheets, hover states, Retouch, Red-eye and the justified grid were not looked at.
- "Reset Adjustments skips RAW and Point Color" and "import shows no
  progress" are readings of the code by an exploring agent; the planning
  session for B1 / C1 must confirm them before relying on them.
- Whether `Mask` has an enabled flag (B5), whether `PhotoExporter` can stop
  cleanly (C1) and the cost of smart-collection counts (A4) are unknown.
- SwiftUI's single-tap delay next to a double-tap recogniser (A1) is a known
  framework behaviour, not measured in this app.
