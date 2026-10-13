#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="$repo_root/dist/MacResourceMonitor.app"
dmg="$repo_root/dist/MacResourceMonitor.dmg"
executable="MacResourceMonitor"

cd "$repo_root"
# Invalidate both old release artifacts before any build can fail.
rm -rf "$app"
rm -f "$dmg"
mkdir -p "$repo_root/build/clang-module-cache" "$repo_root/build/cache" "$repo_root/dist"
export CLANG_MODULE_CACHE_PATH="$repo_root/build/clang-module-cache"
export XDG_CACHE_HOME="$repo_root/build/cache"

binaries=()
for arch in arm64 x86_64; do
    swift build -c release --arch "$arch" --disable-sandbox
    bin_dir="$(swift build -c release --arch "$arch" --disable-sandbox --show-bin-path)"
    binary="$bin_dir/$executable"
    test -f "$binary" || { printf 'Missing %s release executable: %s\n' "$arch" "$binary" >&2; exit 1; }
    actual="$(lipo -archs "$binary")"
    test "$actual" = "$arch" || { printf 'Expected thin %s executable, got: %s\n' "$arch" "$actual" >&2; exit 1; }
    binaries+=("$binary")
done

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
lipo -create "${binaries[@]}" -output "$app/Contents/MacOS/$executable"
chmod 755 "$app/Contents/MacOS/$executable"
cp "$repo_root/Resources/Info.plist" "$app/Contents/Info.plist"
cp "$repo_root/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$app"
bash "$repo_root/scripts/verify-release.sh" --app-only

printf 'Built application: %s\n' "$app"
