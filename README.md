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
- Typed metadata values, metadata diffs, deleted tags, and artwork models.
- Audio file identity and state tracking.
- Atomic session and crash-recovery persistence.
- Complete TagLib-backed handlers for MP3, FLAC, M4A/MP4, Ogg Vorbis, Ogg Opus, and WAV.
- Header and extension format detection with read/write round-trip tests.
- MusicBrainz release search and lookup with JSON models for releases, media, tracks, recordings, ISRCs, labels, and release groups.
- Rate-limited MusicBrainz networking with a required User-Agent, optional authorization header, persistent response caching, retry/backoff handling, and cancellation propagation.
- Deterministic release and track matching using album identifiers, barcodes, catalog numbers, text similarity, track counts, durations, recording IDs, and ISRCs.
- A Swift 6 scripting parser and evaluator with nested functions, variables, escapes, conditionals, metadata mutation, multi-value operations, string/regex/date/numeric functions, and source-located errors.
- Chromaprint `fpcalc` integration with validated JSON decoding and AcoustID lookup/submission clients with request throttling, retries, cancellation, authentication, and consent enforcement.
- Unit tests for configuration, migration, keychain, paths, and runtime startup.
- GitHub Actions build and test workflow.

## Phase 5

Phase 5 adds the MusicBrainz integration and matching engine:

- Actor-isolated HTTP transport and response cache.
- Search and full-release lookup against the MusicBrainz Web Service.
- Retry handling for temporary failures and HTTP 429 responses, including `Retry-After`.
- Summary-level and full-release matching with exact, matched, ambiguous, and rejected decisions.
- Track assignment with recording-ID/ISRC exact matches, title/artist/duration scoring, uniqueness constraints, and unmatched reporting.
- Deterministic fixture tests for request construction, cache reuse, decoding, identifiers, and matching.

## Phase 6

Phase 6 adds scripts and automatic identification:

- `PicardScripts` parses and evaluates nested Picard-style expressions without stringly-typed shortcuts.
- Script execution reads and mutates the existing multi-value `Metadata` model, including unset/delete semantics.
- `PicardFingerprint` runs Chromaprint's `fpcalc` executable and maps AcoustID results to MusicBrainz recordings and releases.
- AcoustID submissions require both a user token and explicit consent before any network request is made.
- Fixture tests cover parser diagnostics, nested functions, metadata changes, regex/unicode handling, fingerprint decoding, lookup mapping, and submission guards.

## Local development

```sh
swift build -Xswiftc -strict-concurrency=complete
swift test -Xswiftc -strict-concurrency=complete
swift run MacPicard
```

The application currently displays the initialized foundation status. The native tagging workflow, scripting, cover art, and full editing UI are implemented in later phases.
