#!/bin/bash
# Bumps the release version across every file that stores it and prints the
# new version. Usage: Scripts/bump_version.sh <major|minor|patch|none>
set -euo pipefail

BUMP="${1:-}"
if [[ ! "$BUMP" =~ ^(major|minor|patch|none)$ ]]; then
    echo "usage: $0 <major|minor|patch|none>" >&2
    exit 2
fi

CLI_FILE="Sources/ClapCLIKit/ClapCLI.swift"
CURRENT="$(sed -n 's/^    public static let version = "\([0-9]*\.[0-9]*\.[0-9]*\)"/\1/p' "$CLI_FILE")"
if [[ -z "$CURRENT" ]]; then
    echo "error: could not read current version from $CLI_FILE" >&2
    exit 1
fi

IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT"
case "$BUMP" in
    major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
    minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
    patch) PATCH=$((PATCH + 1)) ;;
    none)  ;;
esac
NEW="$MAJOR.$MINOR.$PATCH"

if [[ "$NEW" == "$CURRENT" && "$BUMP" != "none" ]]; then
    echo "error: version unchanged" >&2
    exit 1
fi

substitute_inplace() {
    local pattern="$1" file="$2"
    sed "$pattern" "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

substitute_inplace "s/public static let version = \"$CURRENT\"/public static let version = \"$NEW\"/" "$CLI_FILE"
substitute_inplace "s/clipboard & shell history manager · v$CURRENT/clipboard & shell history manager · v$NEW/" \
    Sources/ClapApp/SettingsView.swift
substitute_inplace "s/<string>$CURRENT<\/string>/<string>$NEW<\/string>/" Scripts/Info.plist
echo "$NEW"
