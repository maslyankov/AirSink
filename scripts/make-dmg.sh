#!/usr/bin/env bash
# Package build/AirSink.app into a DMG. Uses `create-dmg` if available
# (nicer-looking output), otherwise falls back to plain `hdiutil`.
#
# Output: build/AirSink-<version>.dmg
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="$(cat VERSION | tr -d ' \t\n\r')"
APP="build/AirSink.app"
DMG="build/AirSink-${VERSION}.dmg"

if [[ ! -d "$APP" ]]; then
    echo "build/AirSink.app missing — run scripts/build-app.sh first" >&2
    exit 1
fi

rm -f "$DMG"

if command -v create-dmg >/dev/null 2>&1; then
    echo "==> Packaging with create-dmg"
    create-dmg \
        --volname "AirSink ${VERSION}" \
        --window-pos 200 120 \
        --window-size 540 360 \
        --icon-size 100 \
        --icon "AirSink.app" 140 180 \
        --hide-extension "AirSink.app" \
        --app-drop-link 400 180 \
        "$DMG" \
        "$APP"
else
    echo "==> create-dmg not found, using hdiutil"
    STAGING="$(mktemp -d)"
    cp -R "$APP" "$STAGING/"
    ln -s /Applications "$STAGING/Applications"
    hdiutil create \
        -volname "AirSink ${VERSION}" \
        -srcfolder "$STAGING" \
        -ov -format UDZO \
        "$DMG"
    rm -rf "$STAGING"
fi

echo "==> Built ${DMG}"
echo "    sha256: $(shasum -a 256 "$DMG" | awk '{print $1}')"
