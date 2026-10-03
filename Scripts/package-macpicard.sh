#!/bin/zsh

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${MACPICARD_OUTPUT_DIR:-/Users/jayian/Downloads}"
CONFIGURATION="${MACPICARD_CONFIGURATION:-release}"
APP_NAME="MacPicard.app"
APP_PATH="$OUTPUT_DIR/$APP_NAME"
ZIP_PATH="$OUTPUT_DIR/MacPicard.zip"
BUILD_PATH="$(swift build --package-path "$PROJECT_ROOT" --configuration "$CONFIGURATION" --show-bin-path)"
PRODUCT_PATH="$BUILD_PATH/MacPicard"
ICON_SOURCE="$PROJECT_ROOT/Sources/MacPicard/Resources/AppIcon.png"
INFO_PLIST="$PROJECT_ROOT/Sources/MacPicard/Resources/Info.plist"
LOCALIZATION="$PROJECT_ROOT/Sources/MacPicard/Resources/en.lproj"
TEMP_ROOT="$(mktemp -d -t macpicard-package)"

cleanup() {
    rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

swift build --package-path "$PROJECT_ROOT" --configuration "$CONFIGURATION" --product MacPicard

if [[ ! -x "$PRODUCT_PATH" ]]; then
    print -u2 "MacPicard executable was not produced at $PRODUCT_PATH"
    exit 1
fi

if [[ ! -f "$ICON_SOURCE" || ! -f "$INFO_PLIST" ]]; then
    print -u2 "Release resources are missing."
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
if [[ -e "$APP_PATH" ]]; then
    rm -rf "$APP_PATH"
fi
if [[ -e "$ZIP_PATH" ]]; then
    rm -f "$ZIP_PATH"
fi

ICONSET="$TEMP_ROOT/AppIcon.iconset"
mkdir -p "$ICONSET"
sips -z 16 16 "$ICON_SOURCE" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64 "$ICON_SOURCE" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$ICON_SOURCE" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$ICON_SOURCE" --out "$ICONSET/icon_512x512@2x.png" >/dev/null

APP_RESOURCES="$APP_PATH/Contents/Resources"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_RESOURCES"
cp "$PRODUCT_PATH" "$APP_PATH/Contents/MacOS/MacPicard"
chmod 755 "$APP_PATH/Contents/MacOS/MacPicard"
cp "$INFO_PLIST" "$APP_PATH/Contents/Info.plist"
cp -R "$LOCALIZATION" "$APP_RESOURCES/en.lproj"
iconutil -c icns "$ICONSET" -o "$APP_RESOURCES/AppIcon.icns"
printf 'MacPicard %s build\nConfiguration: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$CONFIGURATION" > "$APP_RESOURCES/BuildInfo.txt"

SIGNING_IDENTITY="${MACPICARD_CODESIGN_IDENTITY:-}"
NOTARY_PROFILE="${MACPICARD_NOTARY_PROFILE:-}"
if [[ -n "$NOTARY_PROFILE" ]]; then
    NOTARIZATION_STATUS="requested"
else
    NOTARIZATION_STATUS="not requested"
fi
if [[ -n "$NOTARY_PROFILE" && -z "$SIGNING_IDENTITY" ]]; then
    print -u2 "MACPICARD_NOTARY_PROFILE requires MACPICARD_CODESIGN_IDENTITY."
    exit 2
fi
printf 'Signature: %s\nNotarization: %s\n' "${SIGNING_IDENTITY:-Ad hoc}" "$NOTARIZATION_STATUS" > "$APP_RESOURCES/ReleaseSecurity.txt"

if [[ -n "$SIGNING_IDENTITY" ]]; then
    codesign --force --deep --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP_PATH"
    SIGNATURE_MODE="Developer ID: $SIGNING_IDENTITY"
else
    codesign --force --deep --sign - "$APP_PATH"
    SIGNATURE_MODE="Ad hoc"
fi

plutil -lint "$APP_PATH/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
if [[ -n "$NOTARY_PROFILE" ]]; then
    xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP_PATH"
    xcrun stapler validate "$APP_PATH"
    NOTARIZATION_STATUS="stapled"
    rm -f "$ZIP_PATH"
    ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
fi

print "Packaged: $APP_PATH"
print "Archive: $ZIP_PATH"
print "Signature: $SIGNATURE_MODE"
print "Notarization: $NOTARIZATION_STATUS"
