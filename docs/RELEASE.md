# Releasing Lightbench (direct distribution)

How to turn this repo into a signed, notarized app other people can open. The App Store route is at the end. Everything the repo can do
without your Apple account is already done and checked by `scripts/release.sh --check`.

## What is already in place
- App icon: the designer's Lightbench mark (half white / half amber disc over a bar; master SVG in `docs/icon/`), drawn on the macOS rounded tile by `scripts/make_app_icon.swift` into `Sources/App/Assets.xcassets` (re-run it to regenerate all ten sizes).
- Version: `MARKETING_VERSION` (1.0.0) and `CURRENT_PROJECT_VERSION` (1) in `project.yml`. Bump the build number for every notarized build.
- Category (`public.app-category.photography`), hardened runtime, App Sandbox + user-selected read-write file access.
- `ThirdPartyNotices.md` (GRDB MIT, Depth Anything V2 Small Apache-2.0 with its full text) is bundled in the app.
- `scripts/release.sh`: `--check` (preflight, no account needed), `--unsigned` (shareable zip, no account), and the full archive → sign → notarize → staple → zip run.

## Decisions (made 2026-10-14)
1. **Copyright:** "Copyright © 2026 Praween Siritanasak" (`project.yml`). Done.
2. **Name: Lightbench** (`CFBundleDisplayName` / `CFBundleName` in `project.yml`; user-facing prompts read it through `Sources/App/AppInfo.swift`).
   A quick web search found no existing app by that name; that is NOT a trademark search — check before you promote it widely.
   The module name, `PhotoAppApp` and the **bundle identifier `com.photoapp.PhotoApp` are deliberately unchanged**: the bundle ID owns the sandbox container
   (the catalog, preferences and folder grants), so changing it would orphan an existing library and its folder permissions. Users never see the bundle ID.
   If you ever do change it, the catalog (`catalog.sqlite`) can be copied across, but every folder must be re-granted. (Even with the same ID, moving from a
   development/ad-hoc build to a Developer ID build changes the code signature; macOS 14+ may ask once before opening an existing container.)
3. **Depth model: shipped** (~50 MB; `scripts/fetch_depth_model.sh && xcodegen generate` before building a release).
4. **Mac App Store: not planned.** Distribution is direct download.

> Skipping the App Store does NOT remove the need for an Apple Developer ID if you want people to open the app without scary warnings: notarization
> (the thing that satisfies Gatekeeper) requires a paid Developer Program membership even for direct downloads. Without one, see the next section.

## Without a paid Apple account (`scripts/release.sh --unsigned`)
Builds the app ad-hoc signed and zips it as `build/unsigned/Lightbench-<version>-unsigned.zip` (a separate folder, so it never deletes a notarized zip).
It runs fine on your own Mac. On someone else's Mac Gatekeeper blocks it (macOS 15: "Apple could not verify 'Lightbench' is free of malware…"; older
versions: "cannot be opened because the developer cannot be verified"), and the person must approve it once:
- macOS 14: Control-click (right-click) the app → Open → Open.
- macOS 15 and later: try to open it, then System Settings → Privacy & Security → scroll to "Lightbench was blocked" → **Open Anyway**.
- Or in Terminal, after moving the app to /Applications: `xattr -dr com.apple.quarantine /Applications/Lightbench.app`.
- Heads-up (not verified here): an ad-hoc build is identified by its code hash, so each NEW unsigned build — and later the Developer ID build — may make
  macOS 14+ ask "allow Lightbench to access data from other apps?" for its own container. Testers must allow it or the app cannot reach its library.
- This zip is the local ad-hoc build and may still carry the debug entitlement `get-task-allow`; harmless for testers, never notarizable.
That is acceptable for friends and testers, not for a public download. It also cannot be stapled or notarized later without the account.

## One-time Apple setup (only for the notarized route)
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
   submits to Apple and waits, staples the ticket, verifies with `spctl`, and writes `build/release/Lightbench-<version>.zip`.
5. Do the clean-machine test below on THAT zip.
6. Tag the commit (`git tag v1.0.0`) and publish the zip (a GitHub release, your site, …) with the release notes below.

If notarization is rejected, `xcrun notarytool log <submission-id> --keychain-profile photoapp-notary` names the offending file. The usual causes are a
missing hardened runtime or secure timestamp (both set by the script) or an unsigned nested binary.

## Clean-machine test (never skip)
On a Mac (or a fresh macOS user account) that has never run Lightbench, with the downloaded zip (so Gatekeeper quarantines it as a user would see):
- Unzip, drag to Applications, open. There must be no "damaged" or "unidentified developer" dialog.
- First launch: the empty Library opens without a crash; Import Folder… works on a folder of JPEGs and a folder with your camera's RAW files.
- Quit and relaunch: the library and thumbnails are still there and a previously imported folder still opens (folder bookmarks survived).
- Edit a photo, quit, relaunch: the edit is restored (sidecar). Export a JPEG and open it elsewhere.
- Cull a few photos (Compare `C`, Survey `N`), Write Metadata to XMP on a copy of a folder, undo a rename.
- If you shipped the depth model: add a Depth mask to an HEIC with depth data and to a JPEG.

## Release notes: set expectations
- RAW support runs on Apple's decoder (`CIRAWFilter`); it has been exercised with Nikon D610 files only.
- Drag a folder or photo onto the window, or use Open With / the Dock icon, to import a folder or open a photo. Lightbench is an ALTERNATE handler, so it never becomes the default app for images. (Not live-verified at the time of writing: check it on the clean-machine test, including a cold launch by dropping a folder on the Dock icon.)
- Panorama merge and 3+ frame HDR brackets have had little real-world testing; Merge writes a new TIFF and never touches the originals.
- Known, deliberately deferred: the Shadows/Highlights/Black Point curve can bend backwards at extreme slider combinations (IMPROVEMENTS.md D64).
- The app never uploads anything; the catalog, thumbnails and sidecars stay on the Mac. Originals are never modified.

## Mac App Store instead
Different requirements: an App Store distribution certificate and provisioning profile, App Store Connect listing (screenshots, description, privacy
answers), `method` = `app-store-connect` in the export options, and review. The sandbox entitlements are already App-Store-shaped. The
unverified open-from-Finder path and the name are the likeliest review friction. `scripts/release.sh` does NOT cover this route.
