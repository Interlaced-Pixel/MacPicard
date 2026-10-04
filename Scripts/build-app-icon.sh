#!/bin/zsh
set -euo pipefail

if [[ $# -ne 2 || ! -f "$1" ]]; then
    print -u2 'Usage: build-app-icon.sh source.png output.icns'
    exit 1
fi

ICON_INPUT="$1"
ICON_OUTPUT="$2"
ICON_TEMP="$(mktemp -d -t macpicard-xcode-icon)"
ICONSET="$ICON_TEMP/AppIcon.iconset"

cleanup_icon() {
    for size in 16 32 128 256 512; do
        [[ ! -f "$ICONSET/icon_${size}x${size}.png" ]] || rm "$ICONSET/icon_${size}x${size}.png"
        [[ ! -f "$ICONSET/icon_${size}x${size}@2x.png" ]] || rm "$ICONSET/icon_${size}x${size}@2x.png"
    done
    rmdir "$ICONSET" "$ICON_TEMP" 2>/dev/null || true
}
trap cleanup_icon EXIT
mkdir -p "$ICONSET" "$(dirname "$ICON_OUTPUT")"

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_INPUT" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    retina_size=$((size * 2))
    sips -z "$retina_size" "$retina_size" "$ICON_INPUT" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$ICON_OUTPUT"
