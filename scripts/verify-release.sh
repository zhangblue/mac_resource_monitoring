#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="$repo_root/dist/MacResourceMonitor.app"
dmg="$repo_root/dist/MacResourceMonitor.dmg"
executable="MacResourceMonitor"

fail() {
    printf 'Release verification failed: %s\n' "$*" >&2
    exit 1
}

check_binary() {
    local binary="$1" architectures arch build_info minos
    architectures="$(lipo -archs "$binary")" || fail "cannot inspect architectures: $binary"
    local -a slices
    read -r -a slices <<< "$architectures"
    [[ ${#slices[@]} -eq 2 && " ${slices[*]} " == *' arm64 '* && " ${slices[*]} " == *' x86_64 '* ]] || fail "expected exactly arm64 and x86_64: $binary ($architectures)"
    for arch in arm64 x86_64; do
        build_info="$(vtool -show-build -arch "$arch" "$binary")" || fail "cannot inspect $arch build version: $binary"
        minos="$(printf '%s\n' "$build_info" | awk '$1 == "minos" { print $2 }')"
        [[ "$build_info" == *'platform MACOS'* && "$minos" == '13.0' ]] || fail "invalid $arch macOS deployment target: $binary ($minos)"
    done
}

check_app() {
    local bundle="$1"
    local plist="$bundle/Contents/Info.plist"
    local binary="$bundle/Contents/MacOS/$executable"

    test -d "$bundle" || fail "missing application: $bundle"
    test -d "$bundle/Contents/Resources" || fail "missing Resources directory: $bundle"
    test -f "$plist" || fail "missing Info.plist: $bundle"
    test -x "$binary" || fail "missing executable: $binary"
    plutil -lint "$plist" >/dev/null || fail "invalid Info.plist: $bundle"
    test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")" = "$executable" || fail "incorrect CFBundleExecutable: $bundle"
    test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" = 'com.local.MacResourceMonitor' || fail "incorrect bundle identifier: $bundle"
    test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" = '1.0' || fail "incorrect short version: $bundle"
    test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")" = '1' || fail "incorrect bundle version: $bundle"
    test "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist")" = '13.0' || fail "incorrect minimum macOS version: $bundle"
    test "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$plist")" = true || fail "LSUIElement must be true: $bundle"
    local icon_name
    icon_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$plist")" || fail "missing CFBundleIconFile: $bundle"
    [[ "$icon_name" == *.icns ]] || icon_name="$icon_name.icns"
    test -f "$bundle/Contents/Resources/$icon_name" || fail "missing application icon: $bundle"
    check_binary "$binary"
    codesign --verify --all-architectures --deep --strict "$bundle" || fail "invalid code signature: $bundle"
    local signature_details
    signature_details="$(codesign -dv "$bundle" 2>&1)" || fail "cannot inspect code signature: $bundle"
    [[ "$signature_details" == *'Signature=adhoc'* ]] || fail "application is not ad-hoc signed: $bundle"
}

# The packager uses this gate before copying an app into a new image.
if [[ "${1:-}" == '--app-only' && $# -eq 1 ]]; then
    check_app "$app"
    exit 0
fi
[[ $# -eq 0 ]] || fail 'usage: verify-release.sh [--app-only]'
test -d "$app" || fail "missing application: $app"
test -f "$dmg" || fail "missing disk image: $dmg"
check_app "$app"
hdiutil verify "$dmg" || fail "invalid disk image: $dmg"

mount_point="$(mktemp -d "${TMPDIR:-/tmp}/mac-resource-monitor-verify.XXXXXX")"
mounted=false
cleanup() {
    local status=$?
    trap - EXIT
    if "$mounted"; then
        hdiutil detach "$mount_point" -quiet || hdiutil detach "$mount_point" -force -quiet || status=1
    fi
    rmdir "$mount_point" || status=1
    exit "$status"
}
trap cleanup EXIT

hdiutil attach -readonly -nobrowse -mountpoint "$mount_point" "$dmg" >/dev/null
mounted=true
check_app "$mount_point/MacResourceMonitor.app"
test -L "$mount_point/Applications" || fail "missing Applications shortcut in disk image"
test "$(readlink "$mount_point/Applications")" = '/Applications' || fail "Applications shortcut has the wrong target"
test -f "$mount_point/INSTALL.md" || fail "missing installation instructions in disk image"
app_hash="$(shasum -a 256 "$app/Contents/MacOS/$executable")"
dmg_hash="$(shasum -a 256 "$mount_point/MacResourceMonitor.app/Contents/MacOS/$executable")"
[[ "${app_hash%% *}" == "${dmg_hash%% *}" ]] || fail 'DMG executable differs from dist application'

printf 'Release verified: %s\n' "$dmg"
