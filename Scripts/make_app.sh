#!/bin/bash
# Assemble clap.app from a release build and install the CLI.
# Usage: Scripts/make_app.sh [output-dir]   (default: ./dist)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/dist}"
APP="$OUT/clap.app"

echo "Building release binaries..."
swift build -c release --package-path "$ROOT"
BIN="$ROOT/.build/release"

echo "Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/ClapApp" "$APP/Contents/MacOS/ClapApp"
cp "$BIN/clap" "$APP/Contents/MacOS/clap"
cp "$ROOT/Scripts/Info.plist" "$APP/Contents/Info.plist"
if [ -d "$ROOT/Resources" ]; then
    cp -R "$ROOT/Resources/"* "$APP/Contents/Resources/" 2>/dev/null || true
fi

# Sign with the first available Apple Development identity so macOS
# services that require stable signing (e.g. SMAppService login items)
# accept the bundle; ad-hoc only as last resort.
SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/Apple Development/ { print $2; exit }')"
if [ -n "$SIGN_IDENTITY" ]; then
    echo "Signing with identity $SIGN_IDENTITY"
    codesign --force --deep -s "$SIGN_IDENTITY" --identifier "com.spongycode.clap" "$APP"
else
    codesign --force --deep -s - --identifier "com.spongycode.clap" "$APP"
fi

mkdir -p "$OUT/bin"
cp "$BIN/clap" "$OUT/bin/clap"

echo
echo "Done:"
echo "  App:  $APP            (open it, or move to /Applications)"
echo "  CLI:  $OUT/bin/clap   (symlink into your PATH, e.g.:"
echo "        ln -sf \"$OUT/bin/clap\" /usr/local/bin/clap)"
