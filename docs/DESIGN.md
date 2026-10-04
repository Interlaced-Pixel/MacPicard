# MusicBrainz-inspired MacPicard identity

The requested redesign takes its palette and restrained geometric character from the [official MusicBrainz identity](https://static.metabrainz.org/MB/header-logo-1f7dc2a.svg) and [MusicBrainz site](https://musicbrainz.org/). Purple `#BA478F` and orange `#EB743B` are the reference colors. MacPicard remains an independent product; neither the MusicBrainz logo nor its wordmark is reproduced.

The native interface uses warm neutral surfaces, semantic system text, compact bordered controls and purple selection/primary-action accents. The window title is the only permanent wordmark; there is no repeated brand banner. Secondary actions live in More or contextual menus. The album summary is a small row and is hidden during track matching. The inspector is capped at 380 points so larger windows give more room to tracks rather than stretching metadata fields. Light/dark foreground variants preserve legibility; system accessibility and window controls remain native.

Matching prioritizes aligned local-file and MusicBrainz-track rows. Assignment menus preserve one-to-one swapping; confidence is visible beside each row. Tag changes open in a bounded lower pane, while release identifiers and the release-order list open on demand. Search results are hidden for a single candidate, and additional score components remain expandable. There is no fixed-height hero or always-open details card.

## Icon provenance

Asset: `Sources/MacPicard/Resources/AppIcon.png`. The native build and standalone packager generate the full `.icns` family from this source. The original icon was generated with the built-in imagegen tool; its off-white tile was then removed using the same tool in **edit mode**, referencing the existing local asset with `transparent_background: true`. Pixels outside the emblem are transparent, including the corners; the white note stays opaque. This removes the faint rounded-square outline. Original and edited generated outputs remain in the Codex generated-images directory. No official MusicBrainz artwork was copied into the app.

Final prompt:

> Use case: background-extraction. Edit target: the provided MacPicard app icon. Keep the faceted purple/orange hexagonal music-tag emblem and its white musical note exactly as they are, preserving proportions, colors and crisp edges. Remove the entire off-white rounded-square tile, its border, all shadows and the surrounding white canvas. Return ONLY the centered hexagonal emblem with genuine alpha transparency everywhere outside it, generous equal transparent margins, no faint rounded square, no matte, no glow, no shadow, no text. The white musical note must remain opaque white, not transparent. This is the macOS app icon source; nothing beyond the hexagon may have nonzero alpha.
