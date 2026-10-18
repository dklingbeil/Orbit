#!/usr/bin/env bash
# Packages a built Orbit.app into dist/Orbit-<version>.dmg.
# Optional: SIGN_IDENTITY="Developer ID Application: …" and NOTARY_PROFILE=<notarytool keychain profile>.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:?usage: make-dmg.sh path/to/Orbit.app}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DIST="$ROOT/dist"
DMG="$DIST/Orbit-$VERSION.dmg"
mkdir -p "$DIST"

if [ -n "${SIGN_IDENTITY:-}" ]; then
    echo "Signing with $SIGN_IDENTITY"
    if [ -f "$APP/Contents/MacOS/ffmpeg" ]; then
        codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP/Contents/MacOS/ffmpeg"
    fi
    codesign --force --options runtime --timestamp --entitlements "$ROOT/App/Orbit.entitlements" --sign "$SIGN_IDENTITY" "$APP"
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Orbit" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

if [ -n "${SIGN_IDENTITY:-}" ]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi
if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi
echo "Created $DMG"
