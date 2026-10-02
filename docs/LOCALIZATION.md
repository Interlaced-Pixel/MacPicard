# MacPicard localization baseline

MacPicard ships an English Localizable.strings baseline in the application bundle. Static SwiftUI labels use their source strings as stable keys, while file names, metadata, server responses, paths, and error details remain runtime data and are not translated.

Release rules:

- Keep user-facing copy in SwiftUI string literals or localized resources; do not build UI copy from opaque abbreviations.
- Preserve format names, metadata keys, MusicBrainz identifiers, file paths, and script expressions exactly.
- Check pluralization, truncation, and right-to-left layout before adding a locale.
- Run the accessibility audit after each localization pass.
