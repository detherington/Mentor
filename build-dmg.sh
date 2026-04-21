#!/bin/bash
#
# Build, sign, notarize, and DMG-package Mentor.
#
# Prereqs (one-time, already done on Darrell's machine):
#   • Developer ID Application cert in Keychain (Team 8B29CDK832).
#   • App-specific password stored as a notarytool keychain profile named
#     "notary" (also "notarytool-profile" / "Marky" — any work):
#       xcrun notarytool store-credentials notary --apple-id dge@me.com \
#         --team-id 8B29CDK832
#
# Run from the repo root:
#   ./build-dmg.sh
#
# Output: ./Mentor.dmg, signed + notarized + stapled, ready to hand out.
#
set -euo pipefail

APP_NAME="Mentor"
DMG_NAME="Mentor"
VOLUME_NAME="Mentor Installer"
DMG_FINAL="${DMG_NAME}.dmg"
DMG_TEMP="${DMG_NAME}-temp.dmg"
STAGING_DIR=".dmg-staging"
ICON_SIZE=128
WINDOW_WIDTH=660
WINDOW_HEIGHT=440

SIGN_IDENTITY="Developer ID Application: Darrell Etherington (8B29CDK832)"
NOTARY_PROFILE="Picsy"
ENTITLEMENTS="Mentor/Resources/Mentor.entitlements"

# Sparkle tooling — path into the SPM artifact cache. Xcode drops the
# Sparkle helper binaries here after first package resolve.
SPARKLE_BIN="$HOME/Library/Developer/Xcode/DerivedData/Mentor-enurpttqtmadbpguiezgofqmzesv/SourcePackages/artifacts/sparkle/Sparkle/bin"

# ---- Regenerate project from project.yml ----
# Safety net: project.yml is the source of truth for Info.plist values
# (bundle version, Sparkle feed URL, etc). If we skip this step and
# project.yml has been edited since the last xcodegen run, the build
# will silently use a stale Info.plist — which nuked v1.0.0's first
# build with a bad SUFeedURL + placeholder SUPublicEDKey, and stamped
# v1.0.10 with 1.0.8 on its first pass.
#
# Resolution order:
#   1. Repo-local `.local/bin/xcodegen` (built by `scripts/bootstrap.sh`)
#   2. Whatever's on `$PATH` (e.g. `brew install xcodegen` at
#      `/opt/homebrew/bin/xcodegen`)
XCODEGEN_BIN=""
if [ -x ".local/bin/xcodegen" ]; then
    XCODEGEN_BIN=".local/bin/xcodegen"
elif command -v xcodegen >/dev/null 2>&1; then
    XCODEGEN_BIN="$(command -v xcodegen)"
fi

if [ -n "$XCODEGEN_BIN" ]; then
    echo "=== Regenerating Xcode project from project.yml (${XCODEGEN_BIN}) ==="
    "$XCODEGEN_BIN" generate 2>&1 | tail -3
else
    echo "WARN: xcodegen not found in .local/bin or \$PATH — Info.plist may be stale."
    echo "       Run scripts/bootstrap.sh once, or install via: brew install xcodegen"
fi

# ---- Preflight: sanity-check Info.plist for unsubstituted placeholders.
PREFLIGHT_INFO="Mentor/Resources/Info.plist"
if grep -q "REPLACE_" "$PREFLIGHT_INFO" 2>/dev/null; then
    echo "ERROR: $PREFLIGHT_INFO still contains REPLACE_ placeholders."
    echo "       Update project.yml (e.g. SUPublicEDKey) and re-run."
    exit 1
fi

# ---- Build ----
echo "=== Building ${APP_NAME} for Release ==="
xcodebuild -project Mentor.xcodeproj \
    -scheme Mentor \
    -configuration Release \
    -derivedDataPath build \
    clean build 2>&1 | tail -5

BUILT_APP="build/Build/Products/Release/${APP_NAME}.app"

if [ ! -d "$BUILT_APP" ]; then
    echo "ERROR: Build failed - ${APP_NAME}.app not found at ${BUILT_APP}"
    exit 1
fi

# ---- Sign ----
# --options runtime → hardened runtime (required for notarization).
# --deep re-signs every bundled framework / dylib with the same identity.
# --timestamp embeds a secure timestamp from Apple's TSA (also required).
echo "=== Signing ${APP_NAME}.app ==="
codesign --deep --force --options runtime --timestamp \
    --sign "$SIGN_IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    "$BUILT_APP"

echo "Verifying signature..."
codesign --verify --deep --strict --verbose=2 "$BUILT_APP"
echo "Checking against Gatekeeper assessment policy..."
spctl --assess --type execute --verbose=2 "$BUILT_APP" || {
    echo "WARN: spctl rejected pre-notarization (expected — first-pass)."
}
echo "Signature OK."

# ---- Stage DMG contents ----
echo "=== Preparing DMG staging area ==="
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$BUILT_APP" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

# ---- Create writeable DMG, lay out the window, then convert to compressed ----
echo "=== Creating DMG ==="
rm -f "$DMG_TEMP" "$DMG_FINAL"

hdiutil create -srcfolder "$STAGING_DIR" \
    -volname "$VOLUME_NAME" \
    -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" \
    -format UDRW \
    -size 200m \
    "$DMG_TEMP"

echo "=== Configuring DMG window layout ==="
MOUNT_DIR=$(hdiutil attach -readwrite -noverify "$DMG_TEMP" | grep "/Volumes/" | sed 's/.*\/Volumes/\/Volumes/')
echo "Mounted at: $MOUNT_DIR"

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

echo "=== Compressing DMG ==="
hdiutil convert "$DMG_TEMP" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$DMG_FINAL"

rm -f "$DMG_TEMP"
rm -rf "$STAGING_DIR"

# ---- Sign the DMG itself ----
echo "=== Signing DMG ==="
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_FINAL"

# ---- Notarize + staple ----
echo "=== Notarizing DMG ==="
echo "Submitting to Apple — this can take a few minutes…"
xcrun notarytool submit "$DMG_FINAL" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

echo "=== Stapling ticket onto DMG ==="
xcrun stapler staple "$DMG_FINAL"

# ---- Confirm Gatekeeper now accepts ----
echo "=== Final Gatekeeper check ==="
spctl --assess --type open --context context:primary-signature -v "$DMG_FINAL"

echo ""
echo "=== Done ==="
echo "Signed + notarized DMG: $(pwd)/${DMG_FINAL}"
echo "Size: $(du -h "$DMG_FINAL" | cut -f1)"
echo ""

# -------- Sparkle appcast entry ---------------------------------------
# Grab the version strings out of the built Info.plist so the release
# artifacts stay in lockstep with whatever's in project.yml.
INFO_PLIST="$BUILT_APP/Contents/Info.plist"
VERSION_SHORT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST")
VERSION_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFO_PLIST")
# sign_update emits both sparkle:edSignature=… and length=… — no need
# to read the file size separately here.

echo "=== Sparkle appcast entry ==="
if [ ! -x "$SPARKLE_BIN/sign_update" ]; then
    echo "WARN: $SPARKLE_BIN/sign_update not found — Sparkle artifacts"
    echo "       may not be resolved yet. Run 'xcodebuild -resolvePackageDependencies'"
    echo "       in this project, then re-run this script to get the appcast entry."
else
    # sign_update reads the private key from the keychain (paired with
    # the SUPublicEDKey in Info.plist) and emits an attribute string
    # that slots directly into an <enclosure ... /> tag.
    SIG_OUTPUT=$("$SPARKLE_BIN/sign_update" "$DMG_FINAL")
    echo ""
    echo "Paste this <item> into appcast.xml (and push to the Mentor repo):"
    echo ""
    cat <<APPCAST

    <item>
        <title>Version ${VERSION_SHORT}</title>
        <pubDate>$(date -u +"%a, %d %b %Y %H:%M:%S +0000")</pubDate>
        <sparkle:version>${VERSION_BUILD}</sparkle:version>
        <sparkle:shortVersionString>${VERSION_SHORT}</sparkle:shortVersionString>
        <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
        <enclosure
            url="https://github.com/detherington/Mentor/releases/download/v${VERSION_SHORT}/${DMG_FINAL}"
            type="application/octet-stream"
            ${SIG_OUTPUT} />
    </item>

APPCAST
fi

echo ""
echo "=== Release checklist ==="
echo "  1. Tag + push:           git tag v${VERSION_SHORT} && git push --tags"
echo "  2. Create GitHub release v${VERSION_SHORT}, upload ${DMG_FINAL} as an asset"
echo "  3. Edit appcast.xml — paste the <item> above at the top of the <channel>"
echo "  4. Commit + push appcast.xml — the raw URL is what testers auto-check"
