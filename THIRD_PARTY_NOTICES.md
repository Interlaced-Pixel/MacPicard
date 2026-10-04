# Third-party notices

## TagLibSwift

MacPicard uses [TagLibSwift](https://github.com/jeonghi/TagLibSwift) at revision `a36e48f43a4cea1fd41baa0c90acdb6f35444800` for native Swift/C++ audio metadata I/O.

TagLibSwift is distributed under the MIT License. Its vendored TagLib files offer LGPL 2.1 or the alternative Mozilla Public License 1.1; MacPicard uses the MPL 1.1 alternative for TagLib. All original copyright notices and both license texts remain available.

Packaged builds include TagLibSwift, TagLib LGPL/MPL, and utf8cpp license texts, plus the complete pinned TagLibSwift/TagLib corresponding source archive under `Contents/Resources/ThirdParty/TagLib`. That archive includes build manifests, the fork's changes, and notices for the covered files.

## Chromaprint and FFmpeg

MacPicard bundles the official [Chromaprint 1.6.1 universal macOS calculator](https://github.com/acoustid/chromaprint/releases/tag/v1.6.1) as a separate helper executable at `Contents/Helpers/fpcalc`. Chromaprint's own code is MIT licensed, with included FFmpeg code subject to LGPL 2.1. The helper includes FFmpeg 8.0 audio decoding code and uses macOS Accelerate/vDSP, not FFTW or an external FFmpeg installation.

Full license texts, pinned complete corresponding sources, the FFmpeg build recipe, provenance, and an offline source rebuild script are delivered in `Contents/Resources/MacPicard_PicardFingerprint.bundle/Contents/Resources/Resources/Chromaprint`. See its README for rebuilding and modifying the separately signed helper. These files must remain in every distributed app.

## AcoustID

AcoustID is an online service, not an end-user software dependency. Its application key is registered and supplied by the publisher at build time; users need no application key or account to identify audio. Optional database contributions require the user's own submission token and explicit consent. The free API permits non-commercial usage only; a commercial release requires the appropriate service agreement: [AcoustID usage guidelines](https://acoustid.org/webservice).
