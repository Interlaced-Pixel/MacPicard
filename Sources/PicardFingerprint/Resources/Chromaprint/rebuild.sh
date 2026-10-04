#!/bin/bash
# Corresponding-source rebuild, developer-only. No downloads or installations.
set -euo pipefail
SOURCE_ROOT="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_ROOT="${1:?Usage: rebuild.sh NEW_OUTPUT_DIRECTORY}"
if [[ -e "$OUTPUT_ROOT" ]]; then
    printf '%s\n' 'Output directory already exists; choose a new directory.' >&2
    exit 2
fi
command -v cmake >/dev/null
xcrun --find clang >/dev/null
TASK_ROOT="$(mktemp -d -t macpicard-chromaprint-rebuild)"
trap 'rm -rf "$TASK_ROOT"' EXIT
mkdir -p "$OUTPUT_ROOT"
OUTPUT_ROOT="$(cd "$OUTPUT_ROOT" && pwd)"
tar -xzf "$SOURCE_ROOT/Source/chromaprint-1.6.1.tar.gz" -C "$TASK_ROOT"
mkdir "$TASK_ROOT/ffmpeg-build"
tar -xzf "$SOURCE_ROOT/Source/ffmpeg-build-v8.0-1.tar.gz" --strip-components=1 -C "$TASK_ROOT/ffmpeg-build"
cp "$SOURCE_ROOT/Source/ffmpeg-8.0.tar.gz" "$TASK_ROOT/ffmpeg-build/"
if ! command -v nasm >/dev/null; then
    # Optional developer-only optimization. No end-user dependency is introduced.
    /usr/bin/patch -d "$TASK_ROOT/ffmpeg-build" -p1 < "$SOURCE_ROOT/no-nasm.patch"
fi
export MAKEFLAGS="${MAKEFLAGS:--j4}"
for ARCH in arm64 x86_64; do
    if [[ "$ARCH" == arm64 ]]; then
        TARGET=arm64-apple-macos11
        DEPLOYMENT=11.0
    else
        TARGET=x86_64-apple-macos10.9
        DEPLOYMENT=10.9
    fi
    export TARGET
    /bin/bash "$TASK_ROOT/ffmpeg-build/build-macos.sh"
    export FFMPEG_DIR="$TASK_ROOT/ffmpeg-build/artifacts/ffmpeg-8.0-audio-$TARGET"
    cmake -S "$TASK_ROOT/chromaprint-1.6.1" -B "$TASK_ROOT/chromaprint-$ARCH" \
        -DCMAKE_BUILD_TYPE=Release -DBUILD_TOOLS=ON -DBUILD_TESTS=OFF \
        -DBUILD_SHARED_LIBS=OFF -DFFT_LIB=vdsp -DCMAKE_CXX_FLAGS=-stdlib=libc++ \
        -DCMAKE_OSX_ARCHITECTURES="$ARCH" -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT"
    cmake --build "$TASK_ROOT/chromaprint-$ARCH" --parallel 4
    cp "$TASK_ROOT/chromaprint-$ARCH/src/cmd/fpcalc" "$OUTPUT_ROOT/fpcalc-$ARCH"
done
lipo -create "$OUTPUT_ROOT/fpcalc-arm64" "$OUTPUT_ROOT/fpcalc-x86_64" -output "$OUTPUT_ROOT/fpcalc"
chmod 755 "$OUTPUT_ROOT/fpcalc"
"$OUTPUT_ROOT/fpcalc" -version
