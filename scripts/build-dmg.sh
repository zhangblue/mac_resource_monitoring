#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="$repo_root/dist/MacResourceMonitor.app"
dmg="$repo_root/dist/MacResourceMonitor.dmg"
dmg_root="$repo_root/build/dmg-root"

test -d "$app" || {
    printf 'Missing application; run scripts/build-app.sh first: %s\n' "$app" >&2
    exit 1
}

rm -rf "$dmg_root"
mkdir -p "$dmg_root"
cp -R "$app" "$dmg_root/"
ln -s /Applications "$dmg_root/Applications"
cp "$repo_root/INSTALL.md" "$dmg_root/INSTALL.md"

hdiutil create -volname "Mac Resource Monitor" -srcfolder "$dmg_root" -ov -format UDZO "$dmg"
printf 'Built disk image: %s\n' "$dmg"
