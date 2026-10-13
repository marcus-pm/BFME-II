#!/bin/bash
# Package build/"BFME II.app" into a drag-to-Applications DMG (macOS only).
#
#   scripts/make-dmg.sh [build_dir] [output.dmg]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${1:-$ROOT/build}"
VERSION="${VERSION:-$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo 0.0.0)}"
VERSION="${VERSION#v}"
DMG="${2:-$BUILD/BFME-II-macOS-$VERSION.dmg}"
APP="$BUILD/BFME II.app"

[ -d "$APP" ] || { echo "missing $APP — run scripts/build-app.sh first" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/BFME II.app"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/docs/READ ME FIRST.txt" "$STAGE/READ ME FIRST.txt"

rm -f "$DMG"
hdiutil create -volname "BFME II" -srcfolder "$STAGE" -fs HFS+ \
	-format UDZO -imagekey zlib-level=9 -ov "$DMG"
hdiutil verify "$DMG"
shasum -a 256 "$DMG" | tee "$DMG.sha256"
