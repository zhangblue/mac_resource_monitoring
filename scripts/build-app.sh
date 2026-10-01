#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="$repo_root/dist/MacResourceMonitor.app"
executable="MacResourceMonitor"

cd "$repo_root"
mkdir -p "$repo_root/build/clang-module-cache" "$repo_root/build/cache"
export CLANG_MODULE_CACHE_PATH="$repo_root/build/clang-module-cache"
export XDG_CACHE_HOME="$repo_root/build/cache"
swift build -c release --arch arm64 --disable-sandbox
bin_dir="$(swift build -c release --arch arm64 --disable-sandbox --show-bin-path)"

test -f "$bin_dir/$executable" || {
    printf 'Missing release executable: %s\n' "$bin_dir/$executable" >&2
    exit 1
}

mkdir -p "$repo_root/dist"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
install -m 755 "$bin_dir/$executable" "$app/Contents/MacOS/$executable"
cp "$repo_root/Resources/Info.plist" "$app/Contents/Info.plist"
cp "$repo_root/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$app"

printf 'Built application: %s\n' "$app"
