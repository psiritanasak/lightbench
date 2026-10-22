# Lightbench 1.1.0

Everything in 1.0.0, plus the items below. Your original files are still never modified, and nothing is uploaded.

Requires macOS 14 or later. The app is built for Apple silicon and Intel; it has only been tested on an Apple silicon Mac.

## Installing this build (unsigned)
This download is **not notarized**, so macOS blocks the first launch.
1. Unzip and drag `Lightbench.app` to Applications (replace the old one when updating; your library and edits stay where they are).
2. Open it once and dismiss the warning.
3. Open System Settings ▸ Privacy & Security, scroll down and click **Open Anyway**, then confirm. (macOS 14: Control-click the app ▸ Open instead. Or run `xattr -dr com.apple.quarantine /Applications/Lightbench.app`.)
4. If macOS asks whether Lightbench may access data from other apps, choose Allow.

Before the catalog is upgraded to this version, the app writes a backup into `Application Support/PhotoApp/Backups/`.

## What's new

**Library**
- **Copy Photos into Library** (Add Photos menu / File menu): copy a folder or memory card into a folder of your choice, optionally into date subfolders and renamed with a naming template. Every copy is verified byte for byte, nothing is ever overwritten, and the copied photos are added to the Library. An optional **Move** mode sends the originals to the Trash only after their copy is verified, behind a separate confirmation.
- **Virtual copies** (Photo ▸ Create Virtual Copy, ⌘'): several edit versions of one photo that share a single file. Each version has its own edits, history, rating, flags, labels and keywords, and its own edit file next to the photo. Trashing a copy never moves the shared image; trashing the original photo takes its copies with it and says so first.
- **Show photos from subfolders**: a folder's context menu and Preferences ▸ Library can show the photos of its subfolders too.
- Opening the app from Finder or the Dock no longer creates extra empty windows.

**Editing**
- **Auto Straighten**: detects the horizon and sets the Straighten angle in one undo step.
- **Upright** (Crop tab): **Level** straightens the picture from near-horizontal lines, **Vertical** corrects converging verticals (keystone). Both are one undo step.
- Color Grading wheels can be adjusted with the keyboard and VoiceOver (increase/decrease Hue and Saturation, reset).

**Export**
- **HEIC** export.
- **Logo watermark**: use a PNG, JPEG or HEIC logo instead of text.

**Fixes and polish**
- Launching the app no longer forgets folder permissions it could not resolve right away.
- The rename confirmation appears after the rename sheet has closed; the Curve and Color Grading "Edited" captions no longer shift the layout.
- A Subject mask with every subject switched off now says so and disables Invert.

## Good to know
- **Upright** is new and was checked on drawn test images, not on a range of real photos. Its thresholds are untuned; it refuses (with a message) when the lines do not agree, and a very tall photo tilted far upward can be refused. Level and Auto Straighten do not crop the revealed corners.
- **Virtual copies**: no name or rename for a copy yet, copies are not stacked in the grid, and Copy Photos does not copy a virtual copy's edit file. HDR/panorama merge and XMP read/write act on the original photo, not on copies.
- The filmstrip's click-to-switch was not exercised by my automated checks; use the Library grid to switch photos if it misbehaves.
- Everything listed under "Good to know" in the 1.0.0 notes still applies (RAW tested with Nikon D610 files only, slow Clarity + Dehaze on very large images, little real-world testing of panorama and 3+ frame HDR, no Sky/Object masks).

## Third-party
GRDB (MIT) and, optionally, Depth Anything V2 Small (Apache-2.0). Full notices are in Help ▸ Third-Party Licences.
