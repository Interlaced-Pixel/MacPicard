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
- Cover Art Archive release/release-group lookup, image downloads, ImageIO inspection/resizing/conversion, local artwork discovery, classification, and content-hash deduplication.
- Atomic tag saves with external-modification protection, timestamp preservation, script-driven file naming, collision policies, two-phase moves with rollback, autosave/recovery, profile export/import, and schema migration.
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

## Phase 7

Phase 7 adds cover art, saving, organization, and session persistence:

- `PicardCoverArt` integrates Cover Art Archive release and release-group endpoints and validates downloaded image bytes before embedding.
- `ArtworkProcessor` uses native ImageIO/CoreGraphics APIs for inspection, resizing, output conversion, and deduplication.
- `PicardSessions` serializes audio saves through temporary same-format files, detects external changes, preserves timestamps, and reports failures without partially updating the in-memory file.
- Script-rendered destination paths are sanitized against absolute paths and traversal, checked for collisions, and executed through a rollback-capable move plan.
- Session autosave selects the newest primary/recovery document, supports accept/discard recovery, and persists non-secret profiles with migration support.
- Fixture tests cover Cover Art Archive decoding/downloads, image processing, atomic metadata saves, move execution, profiles, recovery selection, and autosave.

## Phase 8

Phase 8 adds the complete native macOS workflow:

- SwiftUI file import, folder import, Finder drag-and-drop, album clustering, and multi-selection.
- Native track hierarchy with state indicators, selection actions, keyboard commands, and VoiceOver labels.
- Direct metadata editing for the common tag fields, multi-track edits, artwork previews, and embedded cover-art updates.
- MusicBrainz lookup, deterministic match ranking, full release selection, metadata application, and progress/error feedback.
- Picard script preview/application, safe script-driven file organization, destination selection, and collision policy support.
- Atomic save actions, session restoration, recovery autosave, and security-scoped bookmark registration from the UI.
- Native macOS 26 Liquid Glass controls and containers, using standard materials for content readability and the glass material only for controls and navigation surfaces.

Liquid Glass follows Apple's guidance to keep the material in the control/navigation layer, use regular glass for text-heavy controls, use clear glass only over visually rich backgrounds, and group related effects with GlassEffectContainer. See Apple's [Materials](https://developer.apple.com/design/human-interface-guidelines/materials), [Liquid Glass overview](https://developer.apple.com/documentation/technologyoverviews/liquid-glass), and [glassEffect](<https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:)>).

## Local development

```sh
swift build -Xswiftc -strict-concurrency=complete
swift test -Xswiftc -strict-concurrency=complete
swift run MacPicard
```

The application targets macOS 26 and requires the Xcode 26 SDK because the production UI uses native Liquid Glass APIs.
