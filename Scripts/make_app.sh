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

# Ad-hoc sign so the hotkey/app behave under Gatekeeper locally.
codesign --force --deep --sign - "$APP"

mkdir -p "$OUT/bin"
cp "$BIN/clap" "$OUT/bin/clap"

echo
echo "Done:"
echo "  App:  $APP            (open it, or move to /Applications)"
echo "  CLI:  $OUT/bin/clap   (symlink into your PATH, e.g.:"
echo "        ln -sf \"$OUT/bin/clap\" /usr/local/bin/clap)"
