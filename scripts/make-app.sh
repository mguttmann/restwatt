#!/bin/bash
# Assemble dist/Restwatt.app from the SwiftPM release product.
# Writes only below .build/ and dist/. The version comes from the VERSION file.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

version="$(tr -d '[:space:]' < VERSION)"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "VERSION must contain a semantic version, got '$version'" >&2
    exit 1
fi

swift build -c release --product Restwatt
binary="$(swift build -c release --product Restwatt --show-bin-path)/Restwatt"

app="dist/Restwatt.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

cp "$binary" "$app/Contents/MacOS/Restwatt"
printf 'APPL????' > "$app/Contents/PkgInfo"
sed "s/__VERSION__/$version/g" packaging/Info.plist.template > "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist"

# Ad-hoc signature: enough to run locally, no Developer ID involved.
codesign --force --sign - --identifier io.github.mguttmann.restwatt "$app"
codesign --verify --deep --strict "$app"

echo "Built $app (version $version)"
