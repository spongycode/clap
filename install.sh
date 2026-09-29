#!/bin/bash
# clap installer for macOS.
#
#   curl -fsSL https://raw.githubusercontent.com/spongycode/clap/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/spongycode/clap/main/install.sh | bash -s -- --version v0.4.0
#   ./install.sh                  # from a checkout: builds that checkout
#
# By default installs the latest prebuilt release from GitHub (checksum and
# code signature verified). Falls back to building from source when no
# compatible release exists. Never uses sudo.
#
# Everything lives inside main() so a truncated download can't execute a
# partial script.

set -euo pipefail

main() {
    readonly REPO="spongycode/clap"
    readonly BUNDLE_ID="com.spongycode.clap"
    readonly MIN_MACOS=14
    readonly MIN_SWIFT=6

    # ---------- options (flags override env vars) ----------
    local version="${CLAP_VERSION:-latest}"
    local mode="auto"                       # auto | release | source
    local app_dir="${CLAP_APP_DIR:-}"
    local bin_dir="${CLAP_BIN_DIR:-}"
    local launch=1 action="install" purge=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --version)   need_arg "$1" "${2:-}"; version="$2"; shift ;;
            --version=*) version="${1#*=}" ;;
            --source)    mode="source" ;;
            --release)   mode="release" ;;
            --app-dir)   need_arg "$1" "${2:-}"; app_dir="$2"; shift ;;
            --app-dir=*) app_dir="${1#*=}" ;;
            --bin-dir)   need_arg "$1" "${2:-}"; bin_dir="$2"; shift ;;
            --bin-dir=*) bin_dir="${1#*=}" ;;
            --no-launch) launch=0 ;;
            --uninstall) action="uninstall" ;;
            --purge)     purge=1 ;;
            -h|--help)   usage; return 0 ;;
            *)           die "unknown option: $1 (see --help)" ;;
        esac
        shift
    done

    setup_colors
    preflight

    app_dir="$(resolve_app_dir "$app_dir")"
    bin_dir="$(resolve_bin_dir "$bin_dir")"
    local app_dest="$app_dir/clap.app"

    if [ "$action" = "uninstall" ]; then
        uninstall "$app_dest" "$bin_dir" "$purge"
        return 0
    fi
    [ "$purge" -eq 0 ] || die "--purge only applies to --uninstall"
    check_link_free "$bin_dir"          # fail before downloading or touching anything

    WORK_DIR="$(mktemp -d -t clap-install)"
    trap cleanup EXIT
    trap 'die "interrupted"' INT TERM

    # A checkout (install.sh next to Package.swift) builds itself by default.
    local checkout=""
    checkout="$(local_checkout)"
    if [ "$mode" = "auto" ] && [ -n "$checkout" ]; then
        mode="source"
    fi

    local staged="" rc=0
    if [ "$mode" != "source" ]; then
        # rc 3 = no usable release (fall back); any other failure is fatal —
        # a checksum mismatch must never silently turn into a source build.
        staged="$(fetch_release "$version")" || rc=$?
        [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ] || exit "$rc"
        if [ "$rc" -eq 3 ]; then
            [ "$mode" = "release" ] && die "no usable prebuilt release for '$version'"
            warn "No usable prebuilt release — building from source instead."
            mode="source"
        fi
    fi
    if [ "$mode" = "source" ]; then
        staged="$(build_from_source "$version" "$checkout")"
    fi

    verify_bundle "$staged"
    install_bundle "$staged" "$app_dest"
    link_cli "$app_dest" "$bin_dir"

    local installed_version
    installed_version="$(bundle_version "$app_dest")"
    ok "clap ${installed_version} installed to ${BOLD}${app_dest}${RESET}"

    if [ "$launch" -eq 1 ]; then
        open "$app_dest" && ok "Launched clap"
    fi
    finish_notes "$app_dest" "$bin_dir"
}

# ====================================================================
# Output
# ====================================================================
setup_colors() {
    BOLD="" DIM="" RED="" GREEN="" YELLOW="" CYAN="" RESET=""
    if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
        BOLD=$'\033[1m' DIM=$'\033[2m' RED=$'\033[31m' GREEN=$'\033[32m'
        YELLOW=$'\033[33m' CYAN=$'\033[36m' RESET=$'\033[0m'
    fi
}
info() { printf '%s==>%s %s\n' "${CYAN}${BOLD}" "$RESET" "$*" >&2; }
ok()   { printf '%s✓%s %s\n' "$GREEN" "$RESET" "$*" >&2; }
warn() { printf '%sWarning:%s %s\n' "${YELLOW}${BOLD}" "$RESET" "$*" >&2; }
die()  { printf '%sError:%s %s\n' "${RED:-}${BOLD:-}" "${RESET:-}" "$*" >&2; exit 1; }
need_arg() { [ -n "$2" ] || die "$1 requires a value"; }

usage() {
    cat <<'EOF'
clap installer

Usage: install.sh [options]

  --version <tag>    Install a specific release, e.g. v0.4.0 (default: latest)
  --source           Build from source instead of downloading a release
  --release          Require a prebuilt release (never build from source)
  --app-dir <dir>    Where clap.app goes (default: /Applications, else ~/Applications)
  --bin-dir <dir>    Where the `clap` CLI link goes (default: first writable of
                     /opt/homebrew/bin, /usr/local/bin, ~/.local/bin)
  --no-launch        Don't open clap after installing
  --uninstall        Remove clap.app and the CLI link (keeps your history)
  --purge            With --uninstall, also delete history and settings
  -h, --help         Show this help

Environment: CLAP_VERSION, CLAP_APP_DIR, CLAP_BIN_DIR mirror the flags;
NO_COLOR disables colored output.
EOF
}

cleanup() {
    if [ -n "${WORK_DIR:-}" ] && [ -d "$WORK_DIR" ]; then
        rm -rf "$WORK_DIR"
    fi
}

# ====================================================================
# Preflight
# ====================================================================
preflight() {
    [ "$(uname -s)" = "Darwin" ] || die "clap only supports macOS."
    local os_major
    os_major="$(sw_vers -productVersion | cut -d. -f1)"
    [ "$os_major" -ge "$MIN_MACOS" ] ||
        die "clap requires macOS ${MIN_MACOS} (Sonoma) or newer; this Mac runs $(sw_vers -productVersion)."
    command -v curl >/dev/null 2>&1 || die "curl is required."
}

local_checkout() {
    # Empty when piped through `curl | bash` (BASH_SOURCE is not a file then).
    local src="${BASH_SOURCE[0]:-}"
    [ -n "$src" ] && [ -f "$src" ] || return 0
    local dir
    dir="$(cd "$(dirname "$src")" && pwd)"
    if [ -f "$dir/Package.swift" ] && [ -x "$dir/Scripts/make_app.sh" ]; then
        printf '%s\n' "$dir"
    fi
}

resolve_app_dir() {
    local dir="$1"
    if [ -n "$dir" ]; then
        mkdir -p "$dir" || die "can't create $dir"
        [ -w "$dir" ] || die "$dir is not writable"
    elif [ -w /Applications ]; then
        dir="/Applications"
    else
        dir="$HOME/Applications"
        mkdir -p "$dir"
    fi
    (cd "$dir" && pwd)
}

resolve_bin_dir() {
    local dir="$1"
    if [ -z "$dir" ]; then
        local candidate
        for candidate in /opt/homebrew/bin /usr/local/bin; do
            if [ -d "$candidate" ] && [ -w "$candidate" ]; then dir="$candidate"; break; fi
        done
        [ -n "$dir" ] || dir="$HOME/.local/bin"
    fi
    mkdir -p "$dir" || die "can't create $dir"
    [ -w "$dir" ] || die "$dir is not writable"
    (cd "$dir" && pwd)
}

# ====================================================================
# Prebuilt release
# ====================================================================
# Prints the staged .app path on success. Returns 3 when no compatible
# release exists (the caller falls back to a source build); dies otherwise.
fetch_release() {
    local version="$1" tag
    if [ "$version" = "latest" ]; then
        # Follow the /releases/latest redirect: no API token, no rate limit.
        tag="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/${REPO}/releases/latest" 2>/dev/null |
            sed -n 's|.*/releases/tag/||p')" || true
        if [ -z "$tag" ]; then warn "Couldn't determine the latest release."; return 3; fi
    else
        tag="$version"
        case "$tag" in v*) ;; *) tag="v$tag" ;; esac
    fi

    local zip="clap-${tag}.zip"
    local base="https://github.com/${REPO}/releases/download/${tag}"
    info "Downloading clap ${tag}"
    if ! curl -fL --progress-bar --retry 3 --retry-delay 2 -o "$WORK_DIR/$zip" "$base/$zip"; then
        warn "Release asset $zip not found."; return 3
    fi
    if ! curl -fsSL --retry 3 -o "$WORK_DIR/$zip.sha256" "$base/$zip.sha256"; then
        die "checksum file for $zip is missing — refusing to install an unverified download."
    fi

    local expected actual
    expected="$(awk '{print $1; exit}' "$WORK_DIR/$zip.sha256")"
    actual="$(shasum -a 256 "$WORK_DIR/$zip" | awk '{print $1}')"
    [ -n "$expected" ] && [ "$expected" = "$actual" ] ||
        die "checksum mismatch for $zip (expected ${expected:-?}, got $actual). The download may be corrupted."
    ok "Checksum verified"

    mkdir -p "$WORK_DIR/release"
    ditto -x -k "$WORK_DIR/$zip" "$WORK_DIR/release" || die "couldn't extract $zip"
    local app="$WORK_DIR/release/clap.app"
    [ -d "$app" ] || die "$zip doesn't contain clap.app"

    # Release builds may be single-architecture; don't install one this Mac can't run.
    local arch archs
    arch="$(uname -m)"
    archs="$(lipo -archs "$app/Contents/MacOS/ClapApp" 2>/dev/null || true)"
    case " $archs " in
        *" $arch "*) ;;
        *) warn "The ${tag} release is built for '${archs:-unknown}', not ${arch}."; return 3 ;;
    esac
    printf '%s\n' "$app"
}

# ====================================================================
# Source build
# ====================================================================
build_from_source() {
    local version="$1" checkout="$2" src
    command -v swift >/dev/null 2>&1 ||
        die "Building from source needs the Xcode Command Line Tools: run ${BOLD}xcode-select --install${RESET}"
    local swift_major
    swift_major="$(swift --version 2>/dev/null | sed -n 's/.*Swift version \([0-9][0-9]*\).*/\1/p' | head -1)"
    [ -n "$swift_major" ] && [ "$swift_major" -ge "$MIN_SWIFT" ] ||
        die "Building needs Swift ${MIN_SWIFT}+ (found ${swift_major:-none}). Update Xcode or the Command Line Tools."

    if [ -n "$checkout" ]; then
        src="$checkout"
        info "Building from local checkout ${DIM}${src}${RESET}"
    else
        command -v git >/dev/null 2>&1 || die "git is required to build from source."
        src="$WORK_DIR/src"
        local ref=()
        [ "$version" = "latest" ] || ref=(--branch "$version")
        info "Cloning ${REPO}${ref[1]:+ @ ${ref[1]}}"
        git clone --quiet --depth 1 ${ref[@]+"${ref[@]}"} "https://github.com/${REPO}.git" "$src" ||
            die "couldn't clone https://github.com/${REPO} — check your network connection."
    fi

    local log="$WORK_DIR/build.log"
    info "Building release binaries (this takes a couple of minutes)…"
    if ! "$src/Scripts/make_app.sh" "$WORK_DIR/dist" >"$log" 2>&1; then
        printf '%s\n' "${DIM}--- last lines of the build log ---${RESET}" >&2
        tail -25 "$log" >&2
        die "build failed."
    fi
    ok "Build complete"
    printf '%s\n' "$WORK_DIR/dist/clap.app"
}

# ====================================================================
# Install
# ====================================================================
verify_bundle() {
    local app="$1" id
    id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true)"
    [ "$id" = "$BUNDLE_ID" ] || die "unexpected bundle identifier '${id:-none}' in $app"
    [ -x "$app/Contents/MacOS/ClapApp" ] && [ -x "$app/Contents/MacOS/clap" ] ||
        die "$app is missing its executables"
    codesign --verify --deep --strict "$app" 2>/dev/null ||
        die "code signature check failed for $app — refusing to install it."
    ok "Code signature valid"
}

# Quit a clap running from `app` (and only that copy), gracefully first.
quit_running() {
    local app="$1" exe="$1/Contents/MacOS/ClapApp" pids
    pids="$(pgrep -f "^${exe}" 2>/dev/null || true)"
    [ -n "$pids" ] || return 0
    info "Quitting the running clap"
    # Address the app by path so only the copy being replaced is asked to quit.
    osascript -e "tell application \"${app}\" to quit" >/dev/null 2>&1 || true
    local _
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -f "^${exe}" >/dev/null 2>&1 || return 0
        sleep 0.3
    done
    # shellcheck disable=SC2086  # word-splitting the pid list is intended
    kill $pids 2>/dev/null || true
    sleep 0.5
}

install_bundle() {
    local staged="$1" dest="$2" backup="$2.previous"
    quit_running "$dest"
    rm -rf "$backup"
    # Stage next to the destination (same volume) so the final swap is a rename.
    local incoming="$dest.incoming"
    rm -rf "$incoming"
    ditto "$staged" "$incoming" || die "couldn't copy clap.app into $(dirname "$dest")"
    if [ -e "$dest" ]; then
        mv "$dest" "$backup" || { rm -rf "$incoming"; die "couldn't replace the existing $dest"; }
    fi
    if ! mv "$incoming" "$dest"; then
        [ -e "$backup" ] && mv "$backup" "$dest"
        rm -rf "$incoming"
        die "install failed; your previous version was restored."
    fi
    rm -rf "$backup"
}

# Only a previous clap link may be replaced — never an unrelated `clap` binary.
check_link_free() {
    local link="$1/clap"
    [ -e "$link" ] || [ -L "$link" ] || return 0
    case "$(readlink "$link" 2>/dev/null || true)" in
        */clap.app/Contents/MacOS/clap) ;;
        *) die "$link already exists and isn't a clap link; remove it or pass --bin-dir." ;;
    esac
}

link_cli() {
    local app="$1" dir="$2" link="$2/clap"
    check_link_free "$dir"
    ln -sfn "$app/Contents/MacOS/clap" "$link"
    ok "CLI linked: ${BOLD}${link}${RESET}"
}

bundle_version() {
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null || echo "?"
}

finish_notes() {
    local app="$1" bin_dir="$2"
    case ":$PATH:" in
        *":$bin_dir:"*) ;;
        *) warn "$bin_dir is not on your PATH. Add this to ~/.zshrc:"
           # shellcheck disable=SC2016  # $PATH is meant literally for the user to paste
           printf '    export PATH="%s:$PATH"\n' "$bin_dir" >&2 ;;
    esac
    if codesign -dv "$app" 2>&1 | grep -q "Signature=adhoc"; then
        warn "This build is ad-hoc signed, so macOS treats each update as a new app."
        printf '    If paste-on-select or snippets stop working, re-enable clap in\n' >&2
        printf '    System Settings → Privacy & Security → Accessibility.\n' >&2
    fi
    printf '\n%s\n' "${BOLD}Press ⌘⇧V to open clap.${RESET} ${DIM}CLI: clap --help${RESET}" >&2
}

# ====================================================================
# Uninstall
# ====================================================================
uninstall() {
    local app="$1" bin_dir="$2" purge="$3" link="$2/clap"
    quit_running "$app"
    if [ -d "$app" ]; then rm -rf "$app" && ok "Removed $app"; else info "No app at $app"; fi
    case "$(readlink "$link" 2>/dev/null || true)" in
        */clap.app/Contents/MacOS/clap) rm -f "$link" && ok "Removed $link" ;;
    esac
    local data="$HOME/Library/Application Support/clap"
    if [ "$purge" -eq 1 ]; then
        rm -rf "$data" && ok "Deleted history and settings ($data)"
    elif [ -d "$data" ]; then
        info "Kept your history in $data (use --purge to delete it)"
    fi
}

main "$@"
