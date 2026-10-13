#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/mrm-universal-test.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/scripts" "$fixture/dist"
cp "$repo_root/scripts/verify-release.sh" "$fixture/scripts/verify-release.sh"
cp "$repo_root/scripts/build-dmg.sh" "$fixture/scripts/build-dmg.sh"
arm="$(cd "$repo_root" && swift build -c release --arch arm64 --disable-sandbox --show-bin-path)/MacResourceMonitor"
intel="$(cd "$repo_root" && swift build -c release --arch x86_64 --disable-sandbox --show-bin-path)/MacResourceMonitor"
test -f "$arm" && test -f "$intel" || { echo 'Build both release slices before running fixture tests' >&2; exit 1; }
test "$(lipo -archs "$arm")" = arm64
test "$(lipo -archs "$intel")" = x86_64
app="$fixture/dist/MacResourceMonitor.app"
binary="$app/Contents/MacOS/MacResourceMonitor"
dmg="$fixture/dist/MacResourceMonitor.dmg"

make_app() {
    local input="$1"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    install -m 755 "$input" "$binary"
    cp "$repo_root/Resources/Info.plist" "$app/Contents/Info.plist"
    cp "$repo_root/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
    codesign --force --deep --sign - "$app" >/dev/null
}
make_dmg() {
    local root="$fixture/dmg-root"
    rm -rf "$root" "$dmg"
    mkdir -p "$root"
    cp -R "$app" "$root/"
    ln -s /Applications "$root/Applications"
    cp "$repo_root/INSTALL.md" "$root/INSTALL.md"
    hdiutil create -quiet -volname 'Mac Resource Monitor' -srcfolder "$root" -format UDZO "$dmg"
}
verify() { bash "$fixture/scripts/verify-release.sh"; }
reject() {
    local label="$1" reason="${2:-}"
    if verify >"$fixture/result.log" 2>&1; then
        printf 'FAIL: accepted %s fixture\n' "$label" >&2
        exit 1
    fi
    if [[ -n "$reason" ]] && ! grep -Fq "$reason" "$fixture/result.log"; then
        printf 'FAIL: %s rejected for the wrong reason:\n' "$label" >&2
        cat "$fixture/result.log" >&2
        exit 1
    fi
    printf 'PASS: rejected %s\n' "$label"
}

lipo -create "$arm" "$intel" -output "$fixture/universal"
make_app "$fixture/universal"
make_dmg
verify >"$fixture/result.log" 2>&1 || { cat "$fixture/result.log" >&2; exit 1; }
echo 'PASS: accepted valid universal app and DMG'

# A previously valid app must not be shipped when rebuilding current source fails.
# Use a failing builder so this test never touches the repository's dist/.
printf '#!/usr/bin/env bash\nexit 42\n' > "$fixture/scripts/build-app.sh"
if bash "$fixture/scripts/build-dmg.sh" >"$fixture/result.log" 2>&1; then
    echo 'FAIL: packager reused an old valid app after rebuild failed' >&2
    exit 1
fi
if test -e "$dmg" || test -e "$app"; then
    echo 'FAIL: packager retained a stale release artifact after rebuild failed' >&2
    exit 1
fi
echo 'PASS: failed rebuild cannot package or retain old valid app'

# Successful rebuild replaces an old valid app with different valid executable bytes.
vtool -set-build-version macos 13.0 15.0 -replace -output "$fixture/fresh-intel" "$intel" >/dev/null
lipo -create "$arm" "$fixture/fresh-intel" -output "$fixture/fresh-universal"
make_app "$fixture/fresh-universal"
cp -R "$app" "$fixture/current.app"
make_app "$fixture/universal"
old_hash="$(shasum -a 256 "$binary")"
old_hash="${old_hash%% *}"
printf '#!/usr/bin/env bash\nset -e\ncp -R %q %q\n' "$fixture/current.app" "$app" > "$fixture/scripts/build-app.sh"
cp "$repo_root/INSTALL.md" "$fixture/INSTALL.md"
bash "$fixture/scripts/build-dmg.sh" >"$fixture/result.log" 2>&1 || { cat "$fixture/result.log" >&2; exit 1; }
new_hash="$(shasum -a 256 "$binary")"
new_hash="${new_hash%% *}"
test "$old_hash" != "$new_hash" || { echo 'FAIL: old executable was reused' >&2; exit 1; }
verify >"$fixture/result.log" 2>&1 || { cat "$fixture/result.log" >&2; exit 1; }
echo 'PASS: packager rebuilt old valid app and verified fresh DMG'

make_app "$arm"
make_dmg
reject 'arm64-only app and DMG' 'expected exactly arm64 and x86_64'
cp -R "$app" "$fixture/thin.app"
printf '#!/usr/bin/env bash\nset -e\ncp -R %q %q\n' "$fixture/thin.app" "$app" > "$fixture/scripts/build-app.sh"
if bash "$fixture/scripts/build-dmg.sh" >"$fixture/result.log" 2>&1 || test -e "$dmg"; then
    echo 'FAIL: packager accepted thin app or retained stale DMG' >&2
    exit 1
fi
if ! grep -Fq 'expected exactly arm64 and x86_64' "$fixture/result.log"; then
    echo 'FAIL: packager rejected thin app for the wrong reason' >&2
    cat "$fixture/result.log" >&2
    exit 1
fi
echo 'PASS: packager rejects thin app and removes stale DMG'

make_app "$intel"
make_dmg
reject 'x86_64-only app and DMG'

# Change only the Intel deployment target, leaving the plist unchanged.
vtool -set-build-version macos 14.0 26.2 -replace -output "$fixture/intel-too-new" "$intel" >/dev/null
lipo -create "$arm" "$fixture/intel-too-new" -output "$fixture/too-new-universal"
make_app "$fixture/too-new-universal"
make_dmg
reject 'x86_64 minimum macOS 14.0'

vtool -set-build-version macos 14.0 26.2 -replace -output "$fixture/arm-too-new" "$arm" >/dev/null
lipo -create "$fixture/arm-too-new" "$intel" -output "$fixture/arm-too-new-universal"
make_app "$fixture/arm-too-new-universal"
make_dmg
reject 'arm64 minimum macOS 14.0'

# Both copies are independently valid, but the DMG contains different bytes.
vtool -set-build-version macos 13.0 15.0 -replace -output "$fixture/intel-old-sdk" "$intel" >/dev/null
lipo -create "$arm" "$fixture/intel-old-sdk" -output "$fixture/other-universal"
make_app "$fixture/other-universal"
make_dmg
make_app "$fixture/universal"
reject 'stale DMG with different valid executable' 'DMG executable differs from dist application'

make_dmg
printf 'tamper' >> "$binary"
reject 'invalid app signature' 'invalid code signature'

make_app "$fixture/universal"
rm "$app/Contents/Resources/AppIcon.icns"
reject 'missing icon' 'missing application icon'

make_app "$fixture/universal"
chmod 644 "$binary"
reject 'non-executable binary' 'missing executable'

echo 'PASS: all universal release fixtures'
