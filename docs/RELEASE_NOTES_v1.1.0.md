# MacPicard 1.1.0

MacPicard 1.1.0 improves large-library workflows, matching, persistence, and release safety after the 1.0.0 public release.

## Included

- Faster collection browsing, searching, matching, scripting, artwork thumbnails, and persistence through incremental projections, bounded caches, background work, and cancellation-aware checkpoints.
- More efficient MusicBrainz release and track matching with shared request coordination, decoded-response caching, exact identifier handling, and stronger ambiguity protection.
- More resilient library monitoring and session persistence with coalesced updates, delta journals, atomic recovery, and protection against stale or torn writes.
- Additional filesystem and artwork hardening for symlink boundaries, external changes, collisions, bounded transfers, archive validation, and verified app updates.
- Updated Xcode 26 CI validation and strict-concurrency coverage across the Swift package and macOS application tests.

## Distribution

The attached macOS archive is ad-hoc signed for local evaluation. It is not Developer ID signed or notarized. macOS may require an explicit approval in Privacy & Security before opening it.

MacPicard requires macOS 26 or newer.

MacPicard is independent and is not affiliated with MusicBrainz or the Picard project.
