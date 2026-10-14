#!/bin/bash
# Release helper for Lightbench (internal target name: PhotoApp; direct distribution: Developer ID signing + Apple notarization).
#
#   scripts/release.sh --check     Preflight that needs NO Apple account: builds Release (ad-hoc signed) and verifies what a shippable bundle
#                                  must contain (icon, notices, version, hardened runtime, sandbox entitlements, depth model). Run it any time.
#   scripts/release.sh --unsigned  NO paid account: runs the preflight, then zips the ad-hoc-signed app as build/unsigned/<Name>-<version>-unsigned.zip.
#                                  Gatekeeper blocks it on other Macs until the user approves it once (macOS 15+: System Settings → Privacy &
#                                  Security → Open Anyway; see docs/RELEASE.md). Written to build/unsigned/ so it never deletes a notarized zip.
#   scripts/release.sh             Archive, sign with your Developer ID, notarize, staple, verify, and write build/release/<Name>-<version>.zip.
#
# Needs for the full run (see docs/RELEASE.md): an Apple Developer Program membership, a "Developer ID Application" certificate in your login
# keychain, and a notarytool keychain profile created once with
#   xcrun notarytool store-credentials "photoapp-notary" --apple-id <id> --team-id <TEAMID> --password <app-specific-password>
# Environment:
#   TEAM_ID         your 10-character Apple team id                        (required for the full run)
#   NOTARY_PROFILE  the notarytool keychain profile name  (default: photoapp-notary)
#   SIGN_IDENTITY   certificate name                      (default: "Developer ID Application"; if your keychain holds certificates for
#                   more than one team, use the full name, e.g. "Developer ID Application: Your Name (TEAMID)")
set -euo pipefail

cd "$(dirname "$0")/.."
MODE="release"
[ "${1:-}" = "--check" ] && MODE="check"
[ "${1:-}" = "--unsigned" ] && MODE="unsigned"
NOTARY_PROFILE="${NOTARY_PROFILE:-photoapp-notary}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
OUT="build/release"
FAILED=0

say()  { printf '\n== %s\n' "$*"; }
ok()   { printf '   ok    %s\n' "$*"; }
bad()  { printf '   FAIL  %s\n' "$*"; FAILED=1; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "missing tool: $1" >&2; exit 2; }; }

need xcodegen; need xcodebuild; need codesign; need /usr/libexec/PlistBuddy

# --- the checks both modes share, run against a built .app -----------------------------------------------------------------------------
verify_bundle() {
    local app="$1"
    local strict_debug="${2:-no}"   # get-task-allow comes from the local dev signature: a hard failure only for the real Developer ID export
    say "Bundle checks: $app"
    local plist="$app/Contents/Info.plist"
    pb() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist" 2>/dev/null || true; }

    [ -n "$(pb CFBundleShortVersionString)" ] && [ "$(pb CFBundleShortVersionString)" != '$(MARKETING_VERSION)' ] && ok "version $(pb CFBundleShortVersionString) (build $(pb CFBundleVersion))" || bad "version strings missing or unexpanded"
    [ -f "$app/Contents/Resources/AppIcon.icns" ] && ok "app icon present" || bad "AppIcon.icns missing (Assets.xcassets / ASSETCATALOG_COMPILER_APPICON_NAME)"
    [ -f "$app/Contents/Resources/ThirdPartyNotices.md" ] && ok "third-party notices bundled" || bad "ThirdPartyNotices.md not bundled"
    [ "$(pb LSApplicationCategoryType)" != "" ] && ok "category $(pb LSApplicationCategoryType)" || bad "LSApplicationCategoryType missing"
    [ -n "$(pb NSHumanReadableCopyright)" ] && ok "copyright string set" || bad "NSHumanReadableCopyright is EMPTY — set it in project.yml (your name/company)"
    [ -d "$app/Contents/Resources/DepthAnythingV2SmallF16.mlmodelc" ] && ok "depth model bundled (Depth Range mask uses the model)" \
        || echo "   note  depth model not bundled: Depth Range falls back to embedded iPhone depth only (run scripts/fetch_depth_model.sh && xcodegen generate to include it)"

    local info; info="$(codesign -dv --entitlements - "$app" 2>&1 || true)"
    echo "$info" | grep -q "flags=.*runtime" && ok "hardened runtime enabled" || bad "hardened runtime flag missing"
    echo "$info" | grep -q "com.apple.security.app-sandbox" && ok "app sandbox entitlement" || bad "sandbox entitlement missing"
    echo "$info" | grep -q "com.apple.security.files.user-selected.read-write" && ok "user-selected read-write entitlement" || bad "file access entitlement missing"
    if echo "$info" | grep -q "get-task-allow"; then
        if [ "$strict_debug" = "yes" ]; then bad "debug entitlement get-task-allow present (notarization will reject it)"
        else echo "   note  get-task-allow present: normal for this local ad-hoc build; the Developer ID export must NOT have it (the full run checks)"; fi
    else ok "no get-task-allow"; fi
    if [ "$strict_debug" = "yes" ]; then
        local detail; detail="$(codesign -dvv "$app" 2>&1 || true)"
        echo "$detail" | grep -q "Authority=Developer ID Application" && ok "signed with a Developer ID Application certificate" || bad "not signed with Developer ID Application"
        echo "$detail" | grep -q "^Timestamp=" && ok "secure timestamp present" || bad "no secure timestamp (notarization requires one)"
    fi
    echo "   size  $(du -sh "$app" | cut -f1)"
}

say "Generating the Xcode project"
xcodegen generate >/dev/null

if [ "$MODE" = "check" ] || [ "$MODE" = "unsigned" ]; then
    say "Building Release (ad-hoc signed; no Apple account needed)"
    APP="build/check/Build/Products/Release/PhotoApp.app"
    rm -rf "$APP" # a failed build must not be able to pass by checking an app left over from an earlier run
    xcodebuild -scheme PhotoApp -configuration Release -derivedDataPath build/check build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
    [ -d "$APP" ] || { echo "Release build failed" >&2; exit 1; }
    verify_bundle "$APP"
    say "Signing"
    SIG="$(codesign -dv "$APP" 2>&1 | grep -E "^Signature" || true)"
    echo "   $SIG   (expected 'adhoc' here; the full run signs with Developer ID)"
    [ "$FAILED" = 0 ] || { say "PREFLIGHT FOUND PROBLEMS (above)"; exit 1; }
    say "PREFLIGHT PASSED"
    if [ "$MODE" = "unsigned" ]; then
        NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP/Contents/Info.plist")"
        VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
        UOUT="build/unsigned"
        rm -rf "$UOUT"; mkdir -p "$UOUT/stage"
        ditto "$APP" "$UOUT/stage/$NAME.app"         # the bundle folder name is not part of the signature, so renaming the copy is safe
        ditto -c -k --keepParent "$UOUT/stage/$NAME.app" "$UOUT/$NAME-$VERSION-unsigned.zip"
        rm -rf "$UOUT/stage"
        say "DONE: $UOUT/$NAME-$VERSION-unsigned.zip (NOT notarized — see docs/RELEASE.md, 'Without a paid Apple account')"
    fi
    exit 0
fi

# --- full release ------------------------------------------------------------------------------------------------------------------------
: "${TEAM_ID:?set TEAM_ID to your 10-character Apple team id (see docs/RELEASE.md)}"
security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY" || { echo "no '$SIGN_IDENTITY' certificate in the keychain (see docs/RELEASE.md)" >&2; exit 2; }
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || { echo "notarytool profile '$NOTARY_PROFILE' not found (see docs/RELEASE.md)" >&2; exit 2; }

rm -rf "$OUT"; mkdir -p "$OUT"
say "Archiving (Developer ID, hardened runtime, secure timestamp)"
xcodebuild -scheme PhotoApp -configuration Release -archivePath "$OUT/PhotoApp.xcarchive" archive \
    DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_IDENTITY" OTHER_CODE_SIGN_FLAGS="--timestamp" \
    2>&1 | grep -E "error:|ARCHIVE (SUCCEEDED|FAILED)"

cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>$SIGN_IDENTITY</string>
</dict></plist>
PLIST
say "Exporting"
xcodebuild -exportArchive -archivePath "$OUT/PhotoApp.xcarchive" -exportOptionsPlist "$OUT/ExportOptions.plist" -exportPath "$OUT/export" 2>&1 | grep -E "error:|EXPORT (SUCCEEDED|FAILED)"
APP="$OUT/export/PhotoApp.app"
verify_bundle "$APP" yes
[ "$FAILED" = 0 ] || { echo "fix the problems above before notarizing" >&2; exit 1; }
codesign --verify --deep --strict --verbose=2 "$APP"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP/Contents/Info.plist")"
ZIP="$OUT/$NAME-$VERSION.zip"
say "Notarizing (this waits for Apple, usually a few minutes)"
ditto -c -k --keepParent "$APP" "$OUT/notarize-upload.zip"
NOTARY_OUT="$(xcrun notarytool submit "$OUT/notarize-upload.zip" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)" || true
echo "$NOTARY_OUT"
# `--wait` can exit 0 even for an Invalid result: require the explicit verdict.
if ! echo "$NOTARY_OUT" | grep -qE "^ *status: Accepted"; then
    SUB_ID="$(echo "$NOTARY_OUT" | awk '/^ *id:/ {print $2; exit}')"
    echo "Notarization was NOT accepted. Details: xcrun notarytool log ${SUB_ID:-<submission-id>} --keychain-profile $NOTARY_PROFILE" >&2
    exit 1
fi
say "Stapling"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -t exec -vv "$APP"
FINAL="$OUT/$NAME.app"
ditto "$APP" "$FINAL"                                  # ship it under the product name (the stapled ticket and signature are unaffected)
spctl -a -t exec -vv "$FINAL"
ditto -c -k --keepParent "$FINAL" "$ZIP"
rm -f "$OUT/notarize-upload.zip"
say "DONE: $ZIP"
echo "Next: test it on a Mac that has never run the app (docs/RELEASE.md, 'Clean-machine test')."
