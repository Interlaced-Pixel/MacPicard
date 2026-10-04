#!/bin/zsh
# Shared by Xcode and standalone packaging; runs before the outer app is signed.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:?Usage: install-fingerprint-support.sh APP_PATH}"
PAYLOAD="$PROJECT_ROOT/Sources/PicardFingerprint/Resources/Chromaprint"
CONFIG_SOURCE="$PROJECT_ROOT/Config/AcoustID.plist"
if [[ "$APP_PATH" != /* || "$APP_PATH" != *.app || ! -d "$APP_PATH/Contents" ]]; then
    print -u2 'Expected an existing app bundle with an absolute path.'
    exit 2
fi
(cd "$PAYLOAD" && /usr/bin/shasum -a 256 -c SHA256SUMS >/dev/null)
[[ -f "$PAYLOAD/README.md" && -f "$PAYLOAD/rebuild.sh" ]]
ARCHITECTURES="$(/usr/bin/lipo -archs "$PAYLOAD/fpcalc")"
[[ " $ARCHITECTURES " == *' arm64 '* && " $ARCHITECTURES " == *' x86_64 '* ]]
if /usr/bin/otool -L "$PAYLOAD/fpcalc" | /usr/bin/awk '/^[[:space:]]/ {print $1}' | /usr/bin/grep -Ev '^(/usr/lib/|/System/Library/)' >/dev/null; then
    print -u2 'Fingerprint calculator has a non-system runtime dependency.'
    exit 2
fi
# The app key identifies MacPicard, not an individual. Never substitute a user token.
APPLICATION_KEY="${MACPICARD_ACOUSTID_APPLICATION_KEY:-}"
if [[ -z "$APPLICATION_KEY" && -f "$CONFIG_SOURCE" ]]; then
    APPLICATION_KEY="$(/usr/bin/plutil -extract ApplicationKey raw -o - "$CONFIG_SOURCE")"
fi
if [[ -z "$APPLICATION_KEY" || ${#APPLICATION_KEY} -gt 256 || "$APPLICATION_KEY" == *[^a-zA-Z0-9]* ]]; then
    print -u2 'Developer configuration missing: provide MACPICARD_ACOUSTID_APPLICATION_KEY or Config/AcoustID.plist before building. Users must never configure API keys.'
    exit 2
fi
APP_RESOURCES="$APP_PATH/Contents/Resources"
RESOURCE_BUNDLE="$APP_RESOURCES/MacPicard_PicardFingerprint.bundle"
DESTINATION="$RESOURCE_BUNDLE/Contents/Resources/Resources/Chromaprint"
mkdir -p "$APP_PATH/Contents/Helpers" "$DESTINATION" "$APP_RESOURCES/ThirdParty/TagLib"
/usr/bin/ditto "$PAYLOAD" "$DESTINATION"
# Executable code lives in the standard Helpers location; resources keep all source/licenses.
/bin/mv -f "$DESTINATION/fpcalc" "$APP_PATH/Contents/Helpers/fpcalc"
/bin/chmod 755 "$APP_PATH/Contents/Helpers/fpcalc"
/usr/bin/plutil -create xml1 "$APP_RESOURCES/AcoustID.plist"
/usr/bin/plutil -insert ApplicationKey -string "$APPLICATION_KEY" "$APP_RESOURCES/AcoustID.plist"
# The native SwiftPM resource bundle already has metadata; standalone packaging needs it too.
if [[ ! -f "$RESOURCE_BUNDLE/Contents/Info.plist" ]]; then
    /usr/bin/plutil -create xml1 "$RESOURCE_BUNDLE/Contents/Info.plist"
    /usr/bin/plutil -insert CFBundleIdentifier -string 'com.interlacedpixel.MacPicard.PicardFingerprintResources' "$RESOURCE_BUNDLE/Contents/Info.plist"
    /usr/bin/plutil -insert CFBundlePackageType -string BNDL "$RESOURCE_BUNDLE/Contents/Info.plist"
fi
/bin/cp "$PROJECT_ROOT/THIRD_PARTY_NOTICES.md" "$APP_RESOURCES/ThirdParty/THIRD_PARTY_NOTICES.md"
TAGLIB_SOURCE="$PROJECT_ROOT/.build/checkouts/TagLibSwift"
if [[ ! -d "$TAGLIB_SOURCE" && -n "${BUILD_DIR:-}" ]]; then
    TAGLIB_SOURCE="${BUILD_DIR%%/Build/*}/SourcePackages/checkouts/TagLibSwift"
fi
if [[ ! -f "$TAGLIB_SOURCE/LICENSE" ]]; then
    print -u2 'TagLibSwift license resources are missing; resolve package dependencies first.'
    exit 2
fi
/usr/bin/install -m 644 "$TAGLIB_SOURCE/LICENSE" "$APP_RESOURCES/ThirdParty/TagLib/TagLibSwift-LICENSE"
/usr/bin/install -m 644 "$TAGLIB_SOURCE/taglib/COPYING.LGPL" "$TAGLIB_SOURCE/taglib/COPYING.MPL" "$TAGLIB_SOURCE/taglib/3rdparty/utfcpp/LICENSE" "$APP_RESOURCES/ThirdParty/TagLib/"
TAGLIB_REVISION="$(/usr/bin/git -C "$TAGLIB_SOURCE" rev-parse HEAD)"
if [[ "$TAGLIB_REVISION" != a36e48f43a4cea1fd41baa0c90acdb6f35444800 ]]; then
    print -u2 'TagLibSwift source revision does not match the release notices.'
    exit 2
fi
/usr/bin/git -C "$TAGLIB_SOURCE" archive --format=tar.gz --prefix=TagLibSwift/ --output="$APP_RESOURCES/ThirdParty/TagLib/TagLibSwift-source.tar.gz" "$TAGLIB_REVISION"
SIGNING_IDENTITY="${MACPICARD_CODESIGN_IDENTITY:-${EXPANDED_CODE_SIGN_IDENTITY:--}}"
if [[ -z "$SIGNING_IDENTITY" || "$SIGNING_IDENTITY" == - ]]; then
    /usr/bin/codesign --force --sign - "$APP_PATH/Contents/Helpers/fpcalc"
else
    /usr/bin/codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP_PATH/Contents/Helpers/fpcalc"
fi
/usr/bin/codesign --verify --strict "$APP_PATH/Contents/Helpers/fpcalc"
print 'Bundled universal fingerprint calculator, corresponding source, licenses, and publisher identification configuration.'
