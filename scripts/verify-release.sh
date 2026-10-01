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
    local binary_details
    binary_details="$(file "$binary")" || fail "cannot inspect executable: $binary"
    [[ "$binary_details" == *arm64* ]] || fail "binary is not arm64: $binary"
    codesign --verify --deep --strict "$bundle" || fail "invalid code signature: $bundle"
    local signature_details
    signature_details="$(codesign -dv "$bundle" 2>&1)" || fail "cannot inspect code signature: $bundle"
    [[ "$signature_details" == *'Signature=adhoc'* ]] || fail "application is not ad-hoc signed: $bundle"
}

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

printf 'Release verified: %s\n' "$dmg"
