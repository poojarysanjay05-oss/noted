#!/usr/bin/env bash
#
# make-dmg.sh: package an exported Noted.app into a drag-to-install DMG.
#
# Usage:
#   ./scripts/make-dmg.sh path/to/Noted.app [version]
#
# Produces dist/Noted-<version>.dmg (plus a .sha256 file) with Noted and an
# Applications shortcut side by side, ready to attach to a GitHub Release.
#
# Optional notarization (needs a paid Apple Developer account and a
# Developer ID-signed app). Store your credentials once with:
#   xcrun notarytool store-credentials noted-notary \
#     --apple-id you@example.com --team-id TEAMID
# then run:
#   NOTARY_PROFILE=noted-notary ./scripts/make-dmg.sh path/to/Noted.app
#
set -euo pipefail

APP_PATH="${1:-}"
if [[ -z "$APP_PATH" || ! -d "$APP_PATH" || "${APP_PATH%/}" != *.app ]]; then
    echo "Usage: $0 path/to/Noted.app [version]" >&2
    echo "Export the app first: Xcode → Product → Archive → Distribute App → Custom → Copy App." >&2
    exit 1
fi
APP_PATH="${APP_PATH%/}"
APP_NAME="$(basename "$APP_PATH" .app)"

# Version: from the argument, otherwise from the app's Info.plist.
VERSION="${2:-}"
if [[ -z "$VERSION" ]]; then
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "0.1")"
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$REPO_ROOT/dist"
DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"
VOLUME_NAME="$APP_NAME"

WORK_DIR="$(mktemp -d)"
STAGING="$WORK_DIR/staging"
RW_DMG="$WORK_DIR/rw.dmg"
MOUNT_POINT=""

cleanup() {
    if [[ -n "$MOUNT_POINT" && -d "$MOUNT_POINT" ]]; then
        hdiutil detach "$MOUNT_POINT" -quiet -force >/dev/null 2>&1 || true
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

echo "▸ Packaging $APP_NAME $VERSION"

# Check the app is signed (ad-hoc "Sign to Run Locally" is fine); macOS on
# Apple silicon refuses to run unsigned code.
if ! codesign --verify --deep --strict "$APP_PATH" >/dev/null 2>&1; then
    echo "✗ $APP_PATH isn't validly signed. Export it again from Xcode (Archive → Distribute App)." >&2
    exit 1
fi

# 1. Stage the app next to an Applications shortcut.
mkdir -p "$STAGING" "$DIST_DIR"
ditto "$APP_PATH" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"

# 2. Build a writable image so the Finder window can be laid out.
hdiutil create -quiet -volname "$VOLUME_NAME" -srcfolder "$STAGING" \
    -fs HFS+ -format UDRW -ov "$RW_DMG"
MOUNT_POINT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG" \
    | awk -F'\t' '/\/Volumes\// { print $NF; exit }')"

# 3. Lay out the window: big icons, app on the left, Applications on the right.
#    Needs permission for Terminal to control Finder; skipped if refused.
if osascript >/dev/null 2>&1 <<EOF
tell application "Finder"
    tell disk "$VOLUME_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 760, 480}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set text size of viewOptions to 13
        set position of item "$APP_NAME.app" of container window to {150, 170}
        set position of item "Applications" of container window to {410, 170}
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF
then
    echo "▸ Arranged the installer window"
else
    echo "▸ Skipped window layout (allow Terminal to control Finder for the nicer layout)"
fi

sync
hdiutil detach "$MOUNT_POINT" -quiet
MOUNT_POINT=""

# 4. Compress into the final read-only DMG.
rm -f "$DMG_PATH"
hdiutil convert -quiet "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH"

# 5. Optional: notarize and staple (Developer ID-signed apps only).
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    echo "▸ Notarizing with profile '$NOTARY_PROFILE' (this can take a few minutes)…"
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG_PATH"
fi

(cd "$DIST_DIR" && shasum -a 256 "$(basename "$DMG_PATH")" > "$(basename "$DMG_PATH").sha256")

echo "✓ Created $DMG_PATH ($(du -h "$DMG_PATH" | cut -f1))"
echo "  SHA-256: $(cut -d' ' -f1 "$DMG_PATH.sha256")"
echo
echo "Next: attach it to a release at https://github.com/poojarysanjay05-oss/noted/releases/new"
