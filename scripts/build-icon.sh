#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_image="$repo_root/Resources/AppIcon-1024.png"
output_icon="$repo_root/Resources/AppIcon.icns"

fail() {
    printf 'Icon build failed: %s\n' "$*" >&2
    exit 1
}

test -f "$source_image" || fail "missing source image: $source_image"
dimensions="$(sips -g pixelWidth -g pixelHeight "$source_image")" || fail "cannot inspect source image"
width="$(awk '/pixelWidth:/ { print $2 }' <<< "$dimensions")"
height="$(awk '/pixelHeight:/ { print $2 }' <<< "$dimensions")"
[[ "$width" == 1024 && "$height" == 1024 ]] || fail "source image must be 1024x1024 (found ${width}x${height})"

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/mac-resource-monitor-icon.XXXXXX")"
trap 'rm -rf "$temporary_directory"' EXIT
iconset="$temporary_directory/AppIcon.iconset"
mkdir "$iconset"

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$source_image" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    retina_size=$((size * 2))
    sips -z "$retina_size" "$retina_size" "$source_image" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$iconset" -o "$output_icon"
test -s "$output_icon" || fail "generated icon is empty: $output_icon"
printf 'Built application icon: %s\n' "$output_icon"
