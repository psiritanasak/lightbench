# Lightbench

A native macOS photo editor with a library, in the spirit of Lightroom. Edits are **non-destructive**: your original files are never modified, and every edit is stored as a small set of parameters that is rendered live on the GPU.

> Lightbench is a personal project. It is not signed or notarized yet, so macOS asks you to approve it once (see [Install](#install)).

## What it does

- **Library:** import folders (or copy photos from a card into your library), thumbnail grid, ratings, Pick/Reject flags, colour labels, keywords, editable title / caption / creator / copyright (⌘I, searchable, optionally written into exported files and `.xmp` sidecars), collections and Smart Collections, search (`iso:>800 camera:d610 rating:>3 …`), duplicate detection, people grouping, batch rename, XMP sidecar read/write, catalog backup and restore.
- **Editor:** exposure, contrast, tone curve (with per-channel curves), white balance, colour, selective colour, point colour, black & white mix, colour grading wheels, texture, clarity, dehaze, noise reduction, sharpening, grain, vignette, defringe, crop, straighten, perspective, Auto Straighten and Upright, spot removal, red-eye, looks (including your own `.cube` LUTs), styles and presets.
- **Local adjustments:** radial, linear, brush, luminance, colour, subject and depth masks, which can be combined.
- **RAW:** decoded through Core Image's RAW engine (tested with Nikon D610 files).
- **Virtual copies:** several edit versions of one photo, sharing one file.
- **Cull mode:** single photo, compare and survey views for fast picking.
- **Merge and export:** HDR and panorama merge, super-resolution enhance, and export to JPEG, HEIC, PNG or TIFF with colour space, sharpening, metadata, text or logo watermark and naming templates.

Your edits live next to each photo in a `<photo>.photoapp.json` file (virtual copies add `<photo>.<key>.photoapp.json`). The catalog (ratings, keywords, collections) lives in the app's own container. Nothing is written into your original files. The only deliberate exception is the explicit, confirmed **Move to Trash** (and the optional "move originals" mode of Copy Photos), which always goes to the Finder's Trash and never deletes permanently.

## Requirements

- macOS 14 (Sonoma) or newer
- Developed and tested on an Apple Silicon Mac (M1). Other Macs have not been tested.

## Install

### Download the app

1. Open the [Releases page](https://github.com/psiritanasak/lightbench/releases) and download the latest `Lightbench-<version>-unsigned.zip`.
2. Double-click the zip to unpack it, then drag **Lightbench.app** into your **Applications** folder.
3. The app is not notarized by Apple, so macOS blocks it the first time. Approve it once:
   - **macOS 15 and later:** try to open Lightbench, then go to **System Settings ▸ Privacy & Security**, scroll down to "Lightbench was blocked", and click **Open Anyway**.
   - **macOS 14:** Control-click (right-click) Lightbench in Applications, choose **Open**, then **Open** again.
   - **Or in Terminal:** `xattr -dr com.apple.quarantine /Applications/Lightbench.app`
4. If macOS asks whether Lightbench may access data from other apps, choose **Allow**. Without it the app cannot reach its own library.

On first use, Lightbench asks you to pick the folders that hold your photos (macOS sandbox rules). It only reads and writes inside folders you grant.

### Update

Download the newer zip and replace the app in Applications. Your library and edits stay where they are. Before a new version upgrades the catalog, the app writes a backup into `Application Support/PhotoApp/Backups/`.

## Build from source

You need an Xcode that supports Swift 6 (the project is built here with Xcode 27) and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
git clone https://github.com/psiritanasak/lightbench.git
cd lightbench
xcodegen generate                 # creates PhotoApp.xcodeproj (it is not committed)
xcodebuild -scheme PhotoApp build # or open PhotoApp.xcodeproj in Xcode and press Run
```

Run the tests with `xcodebuild -scheme PhotoApp test` (the full suite takes several minutes and opens the app as its test host).

### Optional: depth model

The **Depth** mask can use a small depth model (Depth Anything V2 Small, Apache-2.0, about 50 MB). It is not in the repository. Without it the app builds and runs, and the Depth mask only offers the depth data embedded in iPhone photos. To include it:

```sh
scripts/fetch_depth_model.sh && xcodegen generate
```

### Making a release zip

`scripts/release.sh --unsigned` builds a shareable ad-hoc signed zip. The signed and notarized route needs a paid Apple Developer account; see [docs/RELEASE.md](docs/RELEASE.md).

## Privacy

Everything runs on your Mac. Lightbench has no accounts, no analytics and no network access for editing. Face grouping, subject masks and duplicate detection use on-device Apple frameworks, and face data stays in the catalog.

## License

[MIT](LICENSE). Third-party components (GRDB, Depth Anything V2 Small) are listed in [ThirdPartyNotices.md](ThirdPartyNotices.md).
