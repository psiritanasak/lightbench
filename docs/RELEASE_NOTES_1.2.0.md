# Lightbench 1.2.0

Everything in 1.1.0, plus the items below. Your original files are still never modified, and nothing is uploaded.

Requires macOS 14 or later. The app is built for Apple silicon and Intel; it has only been tested on an Apple silicon Mac.

## Installing this build (unsigned)
This download is **not notarized**, so macOS blocks the first launch.
1. Unzip and drag `Lightbench.app` to Applications (replace the old one when updating; your library and edits stay where they are).
2. Open it once and dismiss the warning.
3. Open System Settings ▸ Privacy & Security, scroll down and click **Open Anyway**, then confirm. (macOS 14: Control-click the app ▸ Open instead. Or run `xattr -dr com.apple.quarantine /Applications/Lightbench.app`.)
4. If macOS asks whether Lightbench may access data from other apps, choose Allow.

Before the catalog is upgraded to this version, the app writes a backup into `Application Support/PhotoApp/Backups/`. This version adds catalog tables for photo info and stacks.

## What's new

**Library**
- **Photo info**: editable title, caption, creator and copyright (⌘I in the Library, or the Info button in the Editor). Searchable, optionally written into exported files and `.xmp` sidecars. Stored in the catalog only.
- **Auto Stack** (Photo ▸ Auto Stack…): bursts and near-identical shots collapse into stacks in the grid. Stack or unstack by hand, choose a cover, expand a stack with its badge. Cull mode and the Editor filmstrip show stacks too (S expands a stack while culling; flags act on the cover only and say so).
- **Keywords in the Editor**: a Keywords button (⌘K) edits the open photo's own keywords; changes are saved when you close it, Esc discards.
- **Merge** (HDR and panorama) now uses each photo as turned and flipped in the Library, and refuses photos turned differently or with an unreadable edit file before it opens the dialog.

**Editing**
- **Rotate 90°** (Photo ▸ Rotate Left / Right, ⌘[ and ⌘]). Masks and red-eye points turn with the picture; the Crop tab's Reset turns them back.
- **Auto Crop** (Crop tab): crops away the empty corners left by Straighten, Upright, Scale and rotation, in one undo step.
- **Targeted tool**: drag on the photo to move the tone curve, Selective Color and B&W Mix.
- **Lightroom settings import** (Photo ▸ Import Lightroom Settings…): reads a Lightroom/Camera Raw `.xmp` into the open photo as one undo step, including its rotation. Approximate: only Exposure has been checked against Lightroom.

**Safety and reliability**
- The Editor now loads an existing edit file even for folders imported by drag-and-drop or Finder, and will not overwrite an edit file it did not load. When edits cannot be saved, a persistent amber **Edits not saved** chip in the Editor's bottom bar says why and offers a fix (Reload, Show in Finder, Grant Access, Try Again).
- Fixed an Editor canvas that could stay blank after the first launch from `open -a`.
- Fixed stale stack badges in the Library grid.

## Good to know
- **Auto Crop**, **Auto Stack** and the **Lightroom import** are new and have only been checked on synthetic photos and a few scratch folders. The import's slider scale is nominal apart from Exposure.
- Stacks: manual stacks are never changed by a new Auto Stack run; Export, Rename, Trash and the other bulk tools still act on every photo, including those hidden inside a collapsed stack.
- Rotation: with Perspective or Stretch changed, masks land only approximately after a rotation. Merge uses the original photo's rotation and flips (not a virtual copy's), and no other edit.
- Not checked live: the Edits-not-saved chip's Show in Finder / Reload / Try Again actions, Cull Compare and Survey with stacks, suggestion clicks in the Keywords popover, and the Finder/Dock open path.
- Everything listed under "Good to know" in the 1.0.0 and 1.1.0 notes still applies (RAW tested with Nikon D610 files only, slow Clarity + Dehaze on very large images, little real-world testing of panorama and 3+ frame HDR, no Sky/Object masks).

## Third-party
GRDB (MIT) and, optionally, Depth Anything V2 Small (Apache-2.0). Full notices are in Help ▸ Third-Party Licences.
