#!/bin/bash
# Assemble "BFME II.app" (macOS only: needs sips, iconutil, codesign).
#
#   scripts/build-app.sh [output_dir]
#
# Env:
#   WINE_URL      tarball to bundle (default: newest Gcenx wine-staging osx64)
#   WINE_FLAVOR   staging | devel | stable (used when WINE_URL is unset)
#   VERSION       app version string (default: git describe)
#   GITHUB_TOKEN  optional, avoids GitHub API rate limits
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/build}"
APP="$OUT/BFME II.app"
VERSION="${VERSION:-$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo 0.0.0)}"
VERSION="${VERSION#v}"
WINE_FLAVOR="${WINE_FLAVOR:-staging}"
CACHE="${WINE_CACHE:-$ROOT/build/cache}"

mkdir -p "$OUT" "$CACHE"

resolve_wine_url() {
	local auth=()
	[ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
	curl -fsSL ${auth[@]+"${auth[@]}"} https://api.github.com/repos/Gcenx/macOS_Wine_builds/releases/latest |
		python3 -c '
import json, re, sys
flavor = sys.argv[1]
rel = json.load(sys.stdin)
for a in rel["assets"]:
    if re.fullmatch(r"wine-%s-.*-osx64\.tar\.xz" % flavor, a["name"]):
        print(a["browser_download_url"]); break
else:
    sys.exit("no wine-%s osx64 asset in release %s" % (flavor, rel.get("tag_name")))
' "$WINE_FLAVOR"
}

WINE_URL="${WINE_URL:-$(resolve_wine_url)}"
TARBALL="$CACHE/$(basename "$WINE_URL")"
echo "Wine: $WINE_URL"
[ -f "$TARBALL" ] || curl -fL --retry 4 -o "$TARBALL" "$WINE_URL"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
tar -xJf "$TARBALL" -C "$STAGE"
WINE_DIR="$(find "$STAGE" -maxdepth 4 -type d -path '*/Contents/Resources/wine' | head -n 1)"
[ -n "$WINE_DIR" ] || { echo "wine directory not found in tarball" >&2; exit 1; }
ditto "$WINE_DIR" "$APP/Contents/Resources/wine"

install -m 755 "$ROOT/macos/launcher.sh" "$APP/Contents/MacOS/BFME2"
sed "s/@VERSION@/$VERSION/g" "$ROOT/macos/Info.plist" >"$APP/Contents/Info.plist"
printf 'APPL????' >"$APP/Contents/PkgInfo"
cp "$ROOT/README.md" "$APP/Contents/Resources/README.md"
basename "$WINE_URL" >"$APP/Contents/Resources/WINE_VERSION"

# Icon
ICONSET="$STAGE/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
	sips -z $s $s "$ROOT/macos/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
	sips -z $((s * 2)) $((s * 2)) "$ROOT/macos/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature: no Apple Developer ID is available, so Gatekeeper will
# still ask on first open (see README), but the bundle is internally
# consistent and runs on Apple Silicon.
xattr -cr "$APP"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "Built $APP ($(du -sh "$APP" | cut -f1))"
