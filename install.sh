#!/bin/bash
# clap installation script for macOS
# Usage:
#   Remote: curl -fsSL https://raw.githubusercontent.com/spongycode/clap/main/install.sh | bash
#   Local:  ./install.sh
set -euo pipefail

BOLD="$(tput bold 2>/dev/null || echo '')"
GREEN="$(tput setaf 2 2>/dev/null || echo '')"
CYAN="$(tput setaf 6 2>/dev/null || echo '')"
YELLOW="$(tput setaf 3 2>/dev/null || echo '')"
RED="$(tput setaf 1 2>/dev/null || echo '')"
RESET="$(tput sgr0 2>/dev/null || echo '')"

echo "${CYAN}${BOLD}==> Installing clap — native macOS clipboard & shell manager...${RESET}"

# 1. macOS check
if [ "$(uname -s)" != "Darwin" ]; then
    echo "${RED}Error: clap is only supported on macOS.${RESET}" >&2
    exit 1
fi

MACOS_VERSION="$(sw_vers -productVersion | cut -d. -f1)"
if [ "$MACOS_VERSION" -lt 14 ]; then
    echo "${YELLOW}Warning: clap is designed for macOS 14 (Sonoma) or newer. Current: $(sw_vers -productVersion)${RESET}"
fi

# 2. Check Swift compiler
if ! command -v swift >/dev/null 2>&1; then
    echo "${RED}Error: Swift / Xcode Command Line Tools not found.${RESET}" >&2
    echo "Install them by running: ${BOLD}xcode-select --install${RESET}"
    exit 1
fi

TEMP_DIR=""
cleanup() {
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup EXIT

# 3. Locate or clone source
if [ -f "${0:-}" ] && [ "$(basename "$0")" = "install.sh" ]; then
    SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
    echo "Found local source in $SOURCE_DIR"
else
    TEMP_DIR="$(mktemp -d -t clap-install-XXXXXX)"
    echo "Cloning repository from GitHub..."
    git clone --depth 1 https://github.com/spongycode/clap.git "$TEMP_DIR" >/dev/null 2>&1
    SOURCE_DIR="$TEMP_DIR"
fi

# 4. Build release application & CLI
echo "Building release bundle..."
"$SOURCE_DIR/Scripts/make_app.sh" "$SOURCE_DIR/dist" >/dev/null

APP_SRC="$SOURCE_DIR/dist/clap.app"
BIN_SRC="$SOURCE_DIR/dist/bin/clap"

# 5. Install clap.app
APP_DEST="/Applications/clap.app"
if [ -w "/Applications" ]; then
    rm -rf "$APP_DEST"
    cp -R "$APP_SRC" "$APP_DEST"
else
    APP_DEST="$HOME/Applications/clap.app"
    mkdir -p "$HOME/Applications"
    rm -rf "$APP_DEST"
    cp -R "$APP_SRC" "$APP_DEST"
fi
echo "${GREEN}✓ Installed App:${RESET} $APP_DEST"

# 6. Install CLI binary
BIN_DEST=""
if [ -w "/usr/local/bin" ]; then
    BIN_DEST="/usr/local/bin/clap"
elif [ -w "/opt/homebrew/bin" ]; then
    BIN_DEST="/opt/homebrew/bin/clap"
else
    mkdir -p "$HOME/.local/bin"
    BIN_DEST="$HOME/.local/bin/clap"
fi

ln -sf "$APP_DEST/Contents/MacOS/clap" "$BIN_DEST"
echo "${GREEN}✓ Installed CLI:${RESET} $BIN_DEST"

# Check if BIN_DEST directory is in PATH
BIN_DIR="$(dirname "$BIN_DEST")"
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *)
        echo "${YELLOW}Note: $BIN_DIR is not in your \$PATH. Add it to your ~/.zshrc:${RESET}"
        echo "  export PATH=\"\$PATH:$BIN_DIR\""
        ;;
esac

# 7. Launch application
killall ClapApp 2>/dev/null || true
sleep 0.5
open "$APP_DEST"

echo
echo "${GREEN}${BOLD}==> clap is ready!${RESET}"
echo "  • Shortcut: ${BOLD}⌘ ⇧ V${RESET} (open clipboard & shell history panel)"
echo "  • Tabs:     ${BOLD}⌘1${RESET} Classic  ·  ${BOLD}⌘2${RESET} Shell    ·  ${BOLD}⌘3${RESET} Favs    ·  ${BOLD}⌘4${RESET} Media"
echo "  • CLI:      ${BOLD}clap --help${RESET} or ${BOLD}clap stats${RESET}"
echo
