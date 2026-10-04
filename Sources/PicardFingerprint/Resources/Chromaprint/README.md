# Built-in audio fingerprint calculator

MacPicard ships the official Chromaprint **1.6.1 macOS universal fpcalc** helper.
It contains arm64 and x86_64 slices, statically linked FFmpeg **8.0** audio
decoders, and uses Apple's Accelerate/vDSP FFT. It needs only macOS system
libraries, not Homebrew, FFmpeg executables, a package manager, or network access.

Original binary archive:
https://github.com/acoustid/chromaprint/releases/download/v1.6.1/chromaprint-fpcalc-1.6.1-macos-universal.tar.gz

Archive SHA-256: `240aeb5a8c8205af458e3625cb7487b826b711a999e491ef00111f3cebd76f00`.
`SHA256SUMS` pins the extracted binary, source archives, and licenses. Packaging
verifies these **before** signing; code signing changes executable bytes.

## Licenses and corresponding source

Chromaprint's own code is MIT licensed; included FFmpeg code is LGPL 2.1.
FFmpeg's default non-GPL build is LGPL 2.1 or later. The actual license texts
are in `Licenses/`, and the complete corresponding source and build recipes
are in `Source/`. These resources are included in each MacPicard app, not just
available through a download link. The helper is a separate executable, not
linked into the Swift application. Its licenses permit modification and
redistribution under their respective terms; no MacPicard restriction prevents
reverse engineering for debugging modifications to this helper.

Source provenance:

- Chromaprint release source: https://github.com/acoustid/chromaprint/releases/tag/v1.6.1
- FFmpeg source: https://ffmpeg.org/releases/ffmpeg-8.0.tar.gz
- FFmpeg build recipe: https://github.com/acoustid/ffmpeg-build/tree/v8.0-1
  (archive commit `ed1fc84`, including configure flags and macOS source patch).
- Chromaprint packaging recipe and universal lipo command are included in the
  release source archive under `package/build.sh` and `.github/workflows/build.yml`.

`rebuild.sh` builds both architectures using the included archives, without
fetching any dependency. Developer prerequisites: macOS, Xcode command-line
tools, CMake, and make. NASM is optional for Intel assembly optimizations; when
absent, the included `no-nasm.patch` disables x86 assembly while retaining the
same decoders and algorithm. These are **not** end-user requirements. The output is
functionally rebuildable, not promised byte-identical across SDK/compiler
versions. A modified calculator can be copied to `Contents/Helpers/fpcalc` in
your own app copy and that copy re-signed locally with `codesign --force --sign -`
(helper first, app second); preserve these notices. Replacing it invalidates an
existing distribution signature, as with any signed application modification.
