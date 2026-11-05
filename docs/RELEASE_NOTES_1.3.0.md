# Lightbench 1.3.0

Everything in 1.2.0, plus the items below. Your original files are still never modified (the one deliberate exception is the explicit, confirmed "Move to Trash"), and nothing is uploaded.

Requires macOS 14 or later. The app is built for Apple silicon and Intel; it has only been tested on an Apple silicon Mac.

## Installing this build (unsigned)
This download is **not notarized**, so macOS blocks the first launch.
1. Unzip and drag `Lightbench.app` to Applications (replace the old one when updating; your library and edits stay where they are).
2. Open it once and dismiss the warning.
3. Open System Settings ▸ Privacy & Security, scroll down and click **Open Anyway**, then confirm. (macOS 14: Control-click the app ▸ Open instead. Or run `xattr -dr com.apple.quarantine /Applications/Lightbench.app` in Terminal.)
4. If macOS asks whether Lightbench may access data from other apps, choose Allow.

Before the catalog is upgraded to this version, the app writes a backup into `Application Support/PhotoApp/Backups/`. This version adds a catalog table for Recently Deleted and a column for small faces.

## What's new

**Library**
- **Recently Deleted** (Photo ▸ Recently Deleted…): photos you moved to the Trash from the app are listed, and Restore brings back their ratings, keywords, collections and info once the file is back in its folder (use Put Back in the Finder first). The app never moves a file out of the Trash.
- **Export original files**: the export sheet can copy the original photo file unchanged, and JPEG/HEIC exports can be kept under a file-size limit.

**People**
- **Small faces** (People ▸ "Also find small faces"): finds the many small faces in group photos. They are never grouped automatically; you give them to someone yourself.
- **Select several faces** and give them all to a person, mark them "Not this person", or undo the last assignment.
- **Select Similar**: tick the faces that look like the ones you ticked (Strict / Normal / Loose), then review and assign. It only ticks; it never assigns.

**Editing**
- **Colour-gradient slider tracks** for Temperature, Tint, Hue, Saturation, Vibrance and Selective Color.
- **A pinned histogram and EXIF strip** above the Edit panel.
- **A narrower Adjust panel**: it now takes less of the window (the smallest window is about 60 pt narrower).

**Reliability**
- Opening a folder or photo from Finder while the app is already running no longer creates an extra blank window.

## Good to know
- The face limits for Select Similar were measured on one set of Nikon D610 group photos only (the same person sat at 0.23–0.41 and the first different person at 0.44 on its distance scale). Loose can still tick other people; always review before assigning.
- Not checked live: Merge/Hide/Delete Person and Undo Assign through the People sheet, Make Cover / Remove from Stack, a single photo dragged from Finder, and Put Back in the Finder.
- Everything listed under "Good to know" in the 1.0.0, 1.1.0 and 1.2.0 notes still applies (RAW tested with Nikon D610 files only, slow Clarity + Dehaze on very large images, little real-world testing of panorama and 3+ frame HDR merges).
