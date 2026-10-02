# MacPicard

Native macOS Swift 6 recreation of the core MusicBrainz Picard workflow.

The first release targets MP3, FLAC, M4A/MP4, Ogg Vorbis, Ogg Opus, and WAV. The project plan is documented in [picard-swift6-plan.md](picard-swift6-plan.md).

## Phase 1

Phase 1 establishes the Swift Package Manager foundation:

- Swift 6 language mode with complete strict-concurrency checking.
- `PicardFoundation` library target.
- Native macOS executable target.
- Structured logging through `OSLog`.
- Runtime diagnostics.
- Application paths and directory preparation.
- Codable configuration with schema migration support.
- Keychain storage.
- Security-scoped bookmark persistence and access management.
- Unit tests for configuration, migration, keychain, paths, and runtime startup.
- GitHub Actions build and test workflow.

## Local development

```sh
swift build -Xswiftc -strict-concurrency=complete
swift test -Xswiftc -strict-concurrency=complete
swift run MacPicard
```

The application currently displays the initialized Phase 1 foundation status. Audio formats, metadata models, MusicBrainz networking, and the tagging UI are implemented in later phases.
