# Lightbench 1.0.0

A non-destructive photo editor and library for the Mac, in the spirit of Lightroom. Your original files are never modified, and nothing is uploaded: the catalog, thumbnails and edits stay on your Mac.

Requires macOS 14 or later. Apple silicon and Intel (universal).

## Installing this build (unsigned)
This download is **not notarized**, so macOS blocks the first launch.
1. Unzip and drag `Lightbench.app` to Applications.
2. Open it once and dismiss the warning.
3. Open System Settings ▸ Privacy & Security, scroll down and click **Open Anyway**, then confirm.

Later launches work normally.

## What's in it

**Library**
- Import a folder or a whole folder tree; thumbnail grid; ratings, Pick/Reject flags, colour labels, keywords, collections and Smart Collections.
- Search by field (`iso:>800 camera:d610 lens:50mm date:2023-03 rating:>3 flag:pick keyword:x`), sort, filters.
- Culling mode with loupe, Compare and Survey; duplicate finder; People (on-device face grouping).
- XMP sidecar read/write for rating, reject, label and keywords, only on request; batch rename; Move Rejected to Trash (Trash only, never a permanent delete, after a confirmation).
- Catalog backup and restore, with an automatic backup at launch; Preferences (⌘,); Keyboard Shortcuts window (⌘/).

**Editing** (rendered live on the GPU; edits are saved next to each photo)
- Light (Exposure, Contrast, Brightness, Whites, Black Point, Brilliance, Auto Tone), Curves (including an interactive point curve and per-channel RGB), Levels, White Balance with eyedropper, Color (Saturation, Vibrance), Selective Color, Point Color, Color Grading wheels, Black & White with a per-colour mix.
- Detail: Texture, Clarity, Dehaze, Noise Reduction, Sharpen, Grain, Defringe, Vignette.
- Local adjustments: radial, linear, brush, luminance range, colour range, AI Subject and Depth Range masks, combined with intersect/subtract.
- Spot removal and Red-eye, Crop and Straighten, perspective, Scale/Stretch, Flip.
- Looks (including your own `.cube` LUTs), Styles, Presets, Copy/Paste Settings, Compare (side by side or split), full edit history.
- RAW support through Apple's decoder, with RAW-native controls.

**Output**
- Batch export to JPEG, PNG or TIFF with resize, quality, colour space, metadata policy (location removed by default), sharpening and a text watermark.
- Enhance (2x upscale into a new file), HDR merge and panorama merge (each writes a new TIFF).

## Good to know
- **RAW** has only been tested with Nikon D610 files. Other cameras should work through Apple's decoder but have not been checked.
- **Large images:** using Clarity and Dehaze together on very large images (96 MP and up) is slow, in some cases minutes.
- **Merge:** panorama and bracketed HDR merges (3+ frames) have had little real-world testing.
- **Masks:** there is no Sky or Object AI mask yet. Subject and Depth Range masks are there. Depth Range works best on photos with embedded depth (e.g. iPhone) or with the bundled depth model.
- **Face grouping** uses on-device Vision and is not perfect; face data never leaves the catalog and is never written to photos or exports.
- **Tone curve:** the Shadows/Highlights/Black Point curve is kept from bending backwards at extreme slider combinations, so combinations of two or more of those sliders at the extremes are eased back by up to about 40% of the slider values.
- **Opening from Finder or the Dock** (drop a folder or photo on the app) is supported. Lightbench never becomes the default app for images.
- Edits and keywords live in sidecar files and the catalog. A catalog backup does not contain your edits (those sit next to each photo) or the folder permissions macOS granted.

## Third-party
GRDB (MIT) and, optionally, Depth Anything V2 Small (Apache-2.0). Full notices are in Help ▸ Third-Party Licences.
