# Releasing PhotoApp (direct distribution)

How to turn this repo into a signed, notarized app other people can open. The App Store route is at the end. Everything the repo can do
without your Apple account is already done and checked by `scripts/release.sh --check`.

## What is already in place
- App icon: PLACEHOLDER art in `Sources/App/Assets.xcassets` (`scripts/make_app_icon.swift` redraws it; replace the PNGs with real artwork any time).
- Version: `MARKETING_VERSION` (1.0.0) and `CURRENT_PROJECT_VERSION` (1) in `project.yml`. Bump the build number for every notarized build.
- Category (`public.app-category.photography`), hardened runtime, App Sandbox + user-selected read-write file access.
- `ThirdPartyNotices.md` (GRDB MIT, Depth Anything V2 Small Apache-2.0 with its full text) is bundled in the app.
- `scripts/release.sh`: `--check` (preflight, no account needed) and the full archive → sign → notarize → staple → zip run.

## Decisions only you can make (the preflight fails until the first is done)
1. **Copyright string.** `NSHumanReadableCopyright` in `project.yml` is empty. Put your name or company, e.g. `"Copyright © 2026 Your Name"`.
2. **Final name and bundle ID.** Both are still placeholders (`PhotoApp`, `com.photoapp.PhotoApp`). Changing the bundle ID changes the sandbox
   container, so the catalog and folder grants of any existing install do NOT carry over — decide before anyone else installs it. (Even with the
   same bundle ID, moving from a development/ad-hoc build to a Developer ID build changes the code signature; macOS 14+ may ask once before the app
   opens its existing container on a machine that already ran a dev build.)
   Change `bundleIdPrefix` / `PRODUCT_NAME` / `CFBundleDisplayName` in `project.yml`, regenerate, rebuild.
3. **Ship the depth model or not.** Run `scripts/fetch_depth_model.sh && xcodegen generate` to include it (adds ~50 MB). Without it the Depth Range
   mask only works with iPhone depth data.
4. **Direct download vs Mac App Store** (see the end).

## One-time Apple setup
1. Join the Apple Developer Program (paid).
2. In Xcode → Settings → Accounts, add your Apple ID, then create a **Developer ID Application** certificate. Check with
   `security find-identity -v -p codesigning` (it must list "Developer ID Application: …").
3. Create an app-specific password at appleid.apple.com, then store notarization credentials once:
   `xcrun notarytool store-credentials "photoapp-notary" --apple-id <your id> --team-id <TEAMID> --password <app-specific-password>`
4. Find your 10-character Team ID (developer.apple.com → Membership).

## Each release
1. Set the version in `project.yml` (`MARKETING_VERSION`, and raise `CURRENT_PROJECT_VERSION`), `xcodegen generate`.
2. Full test suite green: `xcodebuild -scheme PhotoApp test`.
3. Preflight: `scripts/release.sh --check` (must end with PREFLIGHT PASSED).
4. `TEAM_ID=XXXXXXXXXX scripts/release.sh` — archives with your Developer ID, exports, re-checks the bundle (including that `get-task-allow` is absent),
   submits to Apple and waits, staples the ticket, verifies with `spctl`, and writes `build/release/PhotoApp-<version>.zip`.
5. Do the clean-machine test below on THAT zip.
6. Tag the commit (`git tag v1.0.0`) and publish the zip (a GitHub release, your site, …) with the release notes below.

If notarization is rejected, `xcrun notarytool log <submission-id> --keychain-profile photoapp-notary` names the offending file. The usual causes are a
missing hardened runtime or secure timestamp (both set by the script) or an unsigned nested binary.

## Clean-machine test (never skip)
On a Mac (or a fresh macOS user account) that has never run PhotoApp, with the downloaded zip (so Gatekeeper quarantines it as a user would see):
- Unzip, drag to Applications, open. There must be no "damaged" or "unidentified developer" dialog.
- First launch: the empty Library opens without a crash; Import Folder… works on a folder of JPEGs and a folder with your camera's RAW files.
- Quit and relaunch: the library and thumbnails are still there and a previously imported folder still opens (folder bookmarks survived).
- Edit a photo, quit, relaunch: the edit is restored (sidecar). Export a JPEG and open it elsewhere.
- Cull a few photos (Compare `C`, Survey `N`), Write Metadata to XMP on a copy of a folder, undo a rename.
- If you shipped the depth model: add a Depth mask to an HEIC with depth data and to a JPEG.

## Release notes: set expectations
- RAW support runs on Apple's decoder (`CIRAWFilter`); it has been exercised with Nikon D610 files only.
- Opening a photo from Finder / double-clicking an image is not supported yet; use Import Folder… or Open….
- Panorama merge and 3+ frame HDR brackets have had little real-world testing; Merge writes a new TIFF and never touches the originals.
- Known, deliberately deferred: the Shadows/Highlights/Black Point curve can bend backwards at extreme slider combinations (IMPROVEMENTS.md D64).
- The app never uploads anything; the catalog, thumbnails and sidecars stay on the Mac. Originals are never modified.

## Mac App Store instead
Different requirements: an App Store distribution certificate and provisioning profile, App Store Connect listing (screenshots, description, privacy
answers), `method` = `app-store-connect` in the export options, and review. The sandbox entitlements are already App-Store-shaped. The unsupported
open-from-Finder path and the placeholder icon/name are the likeliest review friction. `scripts/release.sh` does NOT cover this route.
