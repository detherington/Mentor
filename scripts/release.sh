#!/bin/bash
#
# Build, sign and notarize a Mentor release for Orbis — the same model as
# Muesli. Everything lands in dist/:
#   dist/Mentor-<version>.zip             what Sparkle downloads to update
#   dist/installer/Mentor-<version>.dmg   what people install from
#   dist/appcast.xml                      the Sparkle feed (every release in
#                                         dist/, plus delta updates)
#   dist/upload-<version>/                exactly the files to upload
#
# Orbis serves them from https://sbsorbis.com/download/mentor/, and its
# Mentor download page reads the appcast and links the newest DMG (it swaps
# the zip's .zip for .dmg, so both must be uploaded, with these names).
#
# Usage (from the repo root):
#   scripts/release.sh             build, notarize, write the appcast, tag
#   scripts/release.sh --check     run the pre-build checks only
#   scripts/release.sh --verify    after uploading: confirm Orbis serves
#                                  this version's appcast, zip and DMG
# Options:
#   --allow-dirty   skip the clean-tree check (testing; doesn't tag or push)
#
# Release notes: an optional HTML fragment at release-notes/<version>.html
# (no <html>/<body>) is embedded in the appcast and shown in the update
# window.
#
# Prereqs (one-time): Developer ID Application cert (team 8B29CDK832);
# Sparkle's EdDSA key in the login Keychain (account "ed25519", matching
# SUPublicEDKey); a notarytool profile — `Picsy` here, or set
# MENTOR_NOTARY_PROFILE:
#   xcrun notarytool store-credentials Picsy --apple-id dge@me.com --team-id 8B29CDK832
# and xcodegen (brew install xcodegen, or scripts/bootstrap.sh).
#
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Mentor"
DOWNLOAD_BASE="https://sbsorbis.com/download/mentor"
FEED_URL="$DOWNLOAD_BASE/appcast.xml"
SIGN_IDENTITY="Developer ID Application: Darrell Etherington (8B29CDK832)"
NOTARY_PROFILE="${MENTOR_NOTARY_PROFILE:-Picsy}"
# Keychain account holding Mentor's EdDSA key. Muesli signs with its own
# key file, so the two apps' update keys can't cross.
SPARKLE_ACCOUNT="ed25519"
ENTITLEMENTS="Mentor/Resources/Mentor.entitlements"
INFO_PLIST_SRC="Mentor/Resources/Info.plist"
DIST="dist"
VOLUME_NAME="Mentor Installer"
ICON_SIZE=128
WINDOW_WIDTH=660
WINDOW_HEIGHT=440

MODE="release"
ALLOW_DIRTY=false
while [ $# -gt 0 ]; do
    case "$1" in
        --check)       MODE="check" ;;
        --verify)      MODE="verify" ;;
        --allow-dirty) ALLOW_DIRTY=true ;;
        -h|--help)     sed -n '3,32p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1 (see --help)"; exit 2 ;;
    esac
    shift
done

fail() { echo "ERROR: $*" >&2; exit 1; }

VERSION=$(grep -m1 'MARKETING_VERSION:' project.yml | sed -E 's/.*"(.*)".*/\1/')
[ -n "$VERSION" ] || fail "couldn't read MARKETING_VERSION from project.yml."
TAG="v${VERSION}"
ZIP_NAME="${APP_NAME}-${VERSION}.zip"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
ZIP="$DIST/$ZIP_NAME"
DMG="$DIST/installer/$DMG_NAME"
UPLOAD="$DIST/upload-${VERSION}"

# ---- --verify: is Orbis serving this release? ----
# Run after uploading. Sparkle and the download page both break quietly
# on a missing or renamed file, so check what's actually live. Orbis
# answers a missing file with 200 and its web app's HTML page (not 404),
# so "reachable" proves nothing — check the content type and size.
header() {  # header <url> <name> → that response header's value
    curl -fsSI "$1" | tr -d '\r' | awk -v h="$(echo "$2" | tr 'A-Z' 'a-z'):" 'tolower($1)==h {print $2}' | tail -1
}
if [ "$MODE" = "verify" ]; then
    echo "=== Checking ${DOWNLOAD_BASE}/ for ${VERSION} ==="
    case "$(header "$FEED_URL" content-type)" in
        *xml*) ;;
        *) fail "$FEED_URL isn't there (Orbis served a web page) — upload appcast.xml." ;;
    esac
    LIVE_FEED="$(mktemp -t mentor-appcast)"
    curl -fsS -H 'Cache-Control: no-cache' -o "$LIVE_FEED" "$FEED_URL" || fail "couldn't fetch $FEED_URL"
    xmllint --noout "$LIVE_FEED" || fail "the live appcast isn't valid XML."
    grep -q "<sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>" "$LIVE_FEED" ||
        fail "the live appcast has no ${VERSION} item — upload dist/upload-${VERSION}/appcast.xml."
    if [ -f "$DIST/appcast.xml" ] && ! cmp -s "$LIVE_FEED" "$DIST/appcast.xml"; then
        echo "WARN: the live appcast differs from dist/appcast.xml (stale cache, or an older upload)."
    fi
    rm -f "$LIVE_FEED"
    for f in "$ZIP_NAME" "$DMG_NAME"; do
        live_type=$(header "$DOWNLOAD_BASE/$f" content-type) || fail "$DOWNLOAD_BASE/$f isn't reachable."
        case "$live_type" in
            text/html*|"") fail "$DOWNLOAD_BASE/$f isn't there (Orbis served a web page) — upload it." ;;
        esac
        live_len=$(header "$DOWNLOAD_BASE/$f" content-length)
        local_file="$DIST/$f"; [ "$f" = "$DMG_NAME" ] && local_file="$DMG"
        if [ -f "$local_file" ]; then
            local_len=$(stat -f %z "$local_file")
            [ "$live_len" = "$local_len" ] || fail "$f on Orbis is ${live_len:-?} bytes, dist/ has ${local_len} — re-upload it (Sparkle rejects a zip whose size or signature differs)."
        fi
        echo "OK  $DOWNLOAD_BASE/$f (${live_len} bytes)"
    done
    echo "Orbis is serving ${VERSION}. Installed copies pick it up within a day, or via Check for Updates."
    exit 0
fi

# Tidy up whatever a failed run leaves behind — most importantly a still-
# mounted installer volume, which would confuse the Finder layout step on
# the next run.
MOUNT_DIR=""
STAGING_DIR="$DIST/.dmg-staging"
DMG_TEMP="$DIST/.${APP_NAME}-temp.dmg"
cleanup() {
    if [ -n "$MOUNT_DIR" ] && [ -d "$MOUNT_DIR" ]; then
        hdiutil detach "$MOUNT_DIR" -force -quiet || true
    fi
    rm -rf "$STAGING_DIR" "$DMG_TEMP"
}
trap cleanup EXIT

# ---- Regenerate project from project.yml ----
# project.yml is the source of truth for Info.plist values (feed URL,
# public key, versions). Building without regenerating uses whatever the
# last run left behind — which shipped v1.0.0 with a bad SUFeedURL and
# v1.0.10 stamped 1.0.8. So a missing xcodegen is fatal.
XCODEGEN_BIN=""
if [ -x ".local/bin/xcodegen" ]; then
    XCODEGEN_BIN=".local/bin/xcodegen"
elif command -v xcodegen >/dev/null 2>&1; then
    XCODEGEN_BIN="$(command -v xcodegen)"
fi
[ -n "$XCODEGEN_BIN" ] || fail "xcodegen not found. Install it (brew install xcodegen) or run scripts/bootstrap.sh."
echo "=== Regenerating Xcode project from project.yml ==="
"$XCODEGEN_BIN" generate 2>&1 | tail -1

# ---- Pre-build checks ----
# Everything that would otherwise only surface after a multi-minute build
# and two notarizations.
echo "=== Pre-build checks: ${APP_NAME} ${VERSION} ==="
if grep -q "REPLACE_" "$INFO_PLIST_SRC" 2>/dev/null; then
    fail "$INFO_PLIST_SRC still contains REPLACE_ placeholders — update project.yml."
fi
FEED_IN_PLIST=$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$INFO_PLIST_SRC")
[ "$FEED_IN_PLIST" = "$FEED_URL" ] || fail "SUFeedURL in project.yml is $FEED_IN_PLIST, expected $FEED_URL."

if ! $ALLOW_DIRTY && [ -n "$(git status --porcelain)" ]; then
    git status --short | head -15
    fail "working tree has uncommitted changes — commit them first so the release matches a commit (or pass --allow-dirty to test)."
fi

if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
    fail "tag ${TAG} already exists — bump MARKETING_VERSION in project.yml."
fi
remote_tag_status=0
git ls-remote --exit-code --tags origin "refs/tags/${TAG}" >/dev/null 2>&1 || remote_tag_status=$?
case "$remote_tag_status" in
    0) fail "tag ${TAG} already exists on origin — bump MARKETING_VERSION in project.yml." ;;
    2) ;;  # not on origin — good
    *) echo "WARN: couldn't check origin for ${TAG} (offline?)." ;;
esac

if [ -f "$DIST/appcast.xml" ]; then
    xmllint --noout "$DIST/appcast.xml" || fail "$DIST/appcast.xml isn't valid XML."
    if grep -q "<sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>" "$DIST/appcast.xml"; then
        fail "$DIST/appcast.xml already has a ${VERSION} release — bump MARKETING_VERSION in project.yml."
    fi
else
    # generate_appcast keeps earlier releases by reading the previous
    # feed; without it the new feed lists only this release. Harmless for
    # updating, but worth knowing (e.g. first release from another Mac).
    echo "note: no $DIST/appcast.xml yet — the feed will start with ${VERSION}."
fi

if ! $ALLOW_DIRTY; then
    [ "$(git branch --show-current)" = "main" ] || fail "release from main."
    git fetch --quiet origin main || fail "couldn't fetch origin/main."
    [ "$(git rev-list --count HEAD..origin/main)" = "0" ] || fail "origin/main has commits this checkout doesn't — pull first."
fi
echo "Checks passed."
if [ "$MODE" = "check" ]; then exit 0; fi

# ---- Build ----
# Sparkle orders updates by CFBundleVersion and the Orbis page compares it
# as text, so it's a fixed-width UTC timestamp, fresh for every release.
BUILD="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"
[[ "$BUILD" =~ ^[0-9]{12}$ ]] || fail "build number must be YYYYMMDDHHMM (got $BUILD)."
echo "=== Building ${APP_NAME} ${VERSION} (${BUILD}) for Release ==="
xcodebuild -project Mentor.xcodeproj \
    -scheme Mentor \
    -configuration Release \
    -derivedDataPath build \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD" \
    clean build 2>&1 | tail -3

BUILT_APP="build/Build/Products/Release/${APP_NAME}.app"
[ -d "$BUILT_APP" ] || fail "build failed — ${APP_NAME}.app not found at ${BUILT_APP}"
BUILT_INFO="$BUILT_APP/Contents/Info.plist"
[ "$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$BUILT_INFO")" = "$BUILD" ] ||
    fail "built app's CFBundleVersion isn't $BUILD — check project.yml's CFBundleVersion is \$(CURRENT_PROJECT_VERSION)."

SPARKLE_BIN="build/SourcePackages/artifacts/sparkle/Sparkle/bin"
[ -x "$SPARKLE_BIN/generate_appcast" ] || fail "$SPARKLE_BIN/generate_appcast not found — the Sparkle package didn't resolve."
# Signing updates with any other key would make every installed copy
# reject them. Check before spending time on notarization.
KEYCHAIN_PUBLIC=$("$SPARKLE_BIN/generate_keys" --account "$SPARKLE_ACCOUNT" -p 2>/dev/null | tail -1)
APP_PUBLIC=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$BUILT_INFO")
[ "$KEYCHAIN_PUBLIC" = "$APP_PUBLIC" ] ||
    fail "the Keychain's Sparkle key (account $SPARKLE_ACCOUNT) doesn't match SUPublicEDKey — updates would be rejected."

# ---- Sign ----
# --options runtime → hardened runtime (required for notarization).
# --timestamp embeds a secure timestamp from Apple's TSA (also required).
#
# Inside-out, never `--deep` with `--entitlements`: that stamped Mentor's
# camera + microphone entitlements onto every Sparkle helper (Installer.xpc,
# Downloader.xpc, Autoupdate, Updater.app). Nested code is re-signed with
# its own entitlements preserved; only the app gets Mentor.entitlements.
echo "=== Signing ${APP_NAME}.app ==="
sign_nested() {
    codesign --force --options runtime --timestamp \
        --sign "$SIGN_IDENTITY" \
        --preserve-metadata=entitlements \
        "$1"
}
SPARKLE_FW="$BUILT_APP/Contents/Frameworks/Sparkle.framework"
SPARKLE_V="$SPARKLE_FW/Versions/Current"
if [ -d "$SPARKLE_FW" ]; then
    for item in "$SPARKLE_V"/XPCServices/*.xpc "$SPARKLE_V/Autoupdate" "$SPARKLE_V/Updater.app" "$SPARKLE_FW"; do
        [ -e "$item" ] && sign_nested "$item"
    done
fi
# Any other embedded frameworks / dylibs (none today).
if [ -d "$BUILT_APP/Contents/Frameworks" ]; then
    find "$BUILT_APP/Contents/Frameworks" -mindepth 1 -maxdepth 1 \
        \( -name "*.framework" -o -name "*.dylib" \) ! -name "Sparkle.framework" -print0 |
        while IFS= read -r -d '' item; do sign_nested "$item"; done
fi
codesign --force --options runtime --timestamp \
    --sign "$SIGN_IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    "$BUILT_APP"

# Guard against regressing: no helper may carry device entitlements.
if [ -d "$SPARKLE_FW" ]; then
    for item in "$SPARKLE_V"/XPCServices/*.xpc "$SPARKLE_V/Autoupdate" "$SPARKLE_V/Updater.app"; do
        [ -e "$item" ] || continue
        if codesign -d --entitlements - "$item" 2>/dev/null | grep -q "com.apple.security.device"; then
            fail "$(basename "$item") carries device entitlements after signing"
        fi
    done
fi
codesign --verify --deep --strict --verbose=2 "$BUILT_APP"
echo "Signature OK."

# ---- Notarize ----
# Check the verdict explicitly rather than trusting the exit code, and
# print Apple's log when it isn't "Accepted" so the reason is on screen.
notarize() {
    local json status id
    echo "Submitting $(basename "$1") to Apple (profile ${NOTARY_PROFILE}) — this can take a few minutes…"
    json=$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json) || true
    status=$(plutil -extract status raw -o - - <<< "$json" 2>/dev/null || true)
    id=$(plutil -extract id raw -o - - <<< "$json" 2>/dev/null || true)
    if [ "$status" != "Accepted" ]; then
        echo "$json"
        if [ -n "$id" ]; then
            xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" || true
        fi
        fail "notarization of $(basename "$1"): ${status:-unknown} (is the '${NOTARY_PROFILE}' notarytool profile set up?)"
    fi
    echo "Accepted: $(basename "$1") ($id)"
}

# ---- Update zip ----
# Strip extended attributes and sequester resource forks first: otherwise
# extractors other than the Finder write AppleDouble "._" files into the
# bundle, which breaks the signature's seal (Muesli hit this). Sparkle
# extracts correctly either way; this keeps a hand-unzipped copy valid.
mkdir -p "$DIST/installer"
zip_app() {
    rm -f "$ZIP"
    xattr -cr "$BUILT_APP"
    ditto -c -k --sequesterRsrc --keepParent "$BUILT_APP" "$ZIP"
}
echo "=== Notarizing the app ==="
zip_app
notarize "$ZIP"
xcrun stapler staple "$BUILT_APP"
zip_app   # again, now with the ticket stapled inside

# ---- Disk image for people ----
# Built from the stapled app. A mounted image is exact bytes — no
# extraction step to lose Sparkle.framework's symlinks — so the download
# page links this, never the zip.
echo "=== Building ${DMG_NAME} ==="
rm -rf "$STAGING_DIR" "$DMG_TEMP" "$DMG"
mkdir -p "$STAGING_DIR"
ditto "$BUILT_APP" "$STAGING_DIR/${APP_NAME}.app"
ln -s /Applications "$STAGING_DIR/Applications"
# A volume left mounted by an earlier failed run would make Finder's
# `disk "$VOLUME_NAME"` below ambiguous.
if [ -d "/Volumes/$VOLUME_NAME" ]; then
    hdiutil detach "/Volumes/$VOLUME_NAME" -force -quiet || true
fi
hdiutil create -srcfolder "$STAGING_DIR" \
    -volname "$VOLUME_NAME" \
    -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" \
    -format UDRW \
    -size 200m \
    "$DMG_TEMP" >/dev/null
MOUNT_DIR=$(hdiutil attach -readwrite -noverify "$DMG_TEMP" | grep "/Volumes/" | sed 's/.*\/Volumes/\/Volumes/')

# Lay out: app on the left, Applications symlink on the right.
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLUME_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false

        set the bounds of container window to {100, 100, $((100 + WINDOW_WIDTH)), $((100 + WINDOW_HEIGHT))}

        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to $ICON_SIZE

        set position of item "${APP_NAME}.app" of container window to {165, 200}
        set position of item "Applications" of container window to {495, 200}

        close
        open
        update without registering applications
        delay 2
        close
    end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$MOUNT_DIR" -quiet
MOUNT_DIR=""
hdiutil convert "$DMG_TEMP" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$DMG_TEMP"
rm -rf "$STAGING_DIR"
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
echo "=== Notarizing the disk image ==="
notarize "$DMG"
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"

# ---- Appcast ----
# generate_appcast signs every archive in dist/ with the EdDSA key,
# rewrites dist/appcast.xml keeping earlier releases, and writes .delta
# files so copies on recent versions download a fraction of the zip.
# Release notes named like the zip are embedded as the item description.
echo "=== Writing the appcast ==="
NOTES_SRC="release-notes/${VERSION}.html"
if [ -f "$NOTES_SRC" ]; then
    cp "$NOTES_SRC" "$DIST/${APP_NAME}-${VERSION}.html"
else
    echo "note: no $NOTES_SRC — the update window will show no release notes."
fi
"$SPARKLE_BIN/generate_appcast" \
    --account "$SPARKLE_ACCOUNT" \
    --download-url-prefix "$DOWNLOAD_BASE/" \
    -o "$DIST/appcast.xml" \
    "$DIST"
xmllint --noout "$DIST/appcast.xml"
grep -q "<sparkle:version>${BUILD}</sparkle:version>" "$DIST/appcast.xml" ||
    fail "$DIST/appcast.xml has no item for build ${BUILD}."
grep -q "url=\"${DOWNLOAD_BASE}/${ZIP_NAME}\"" "$DIST/appcast.xml" ||
    fail "$DIST/appcast.xml doesn't point at ${DOWNLOAD_BASE}/${ZIP_NAME}."

# ---- Upload folder ----
# Exactly what Orbis needs for this release: the feed, the update zip,
# the DMG the download page links, and any deltas to this build.
rm -rf "$UPLOAD"
mkdir -p "$UPLOAD"
cp "$DIST/appcast.xml" "$ZIP" "$DMG" "$UPLOAD/"
for delta in "$DIST/${APP_NAME}${BUILD}"-*.delta; do
    [ -e "$delta" ] && cp "$delta" "$UPLOAD/"
done

# ---- Tag ----
if ! $ALLOW_DIRTY; then
    git tag "$TAG"
    git push origin main "$TAG"
fi

echo ""
echo "=== ${APP_NAME} ${VERSION} (${BUILD}) is built, notarized and stapled ==="
echo "Upload everything in $(pwd)/${UPLOAD}/ to the Orbis Replit project's"
echo "client/public/download/mentor/, then redeploy Orbis:"
ls -1 "$UPLOAD" | sed 's/^/  /'
echo "Replace appcast.xml; keep the file names exactly (the appcast and the"
echo "download page reference them). Then run: scripts/release.sh --verify"
