# MacPicard

Native macOS Swift 6 recreation of the core MusicBrainz Picard workflow.

The first release targets MP3, FLAC, M4A/MP4, Ogg Vorbis, Ogg Opus, and WAV. The project plan is documented in [picard-swift6-plan.md](picard-swift6-plan.md).

## Libraries and sessions

Choose **File → Add Music Library…** (⌘O) to link a music directory. Supported audio files in its subfolders are indexed, and the active library refreshes every minute. **Library → Refresh Library** (⌘R) scans immediately. Refreshes preserve pending edits, detect external changes, and retain unavailable files until their drive reconnects. Use **Reconnect Library Folder…** after moving a collection.

Choose **File → New Session…** (⌘N) for an independent tagging workspace, or **Save Session As…** (⇧⌘S) to snapshot the current files and pending edits. Switch with the sidebar workspace chooser or **File → Open Workspace**. Workspaces autosave on edits, before switching, and on quit; saving a workspace does not write tags to the music files. **Save Selected Tags** (⌘S) and **Save All Changed Tags** (⌥⌘S) write audio metadata.

Albums start collapsed each time a workspace opens. Click an album to browse its tracks and select the album for batch editing; click its disclosure chevron to expand sidebar tracks. **Find Music…** (⌘F) searches title, artist, album, genre, and filename across the entire collection. Filters show unsaved changes, missing artwork, unidentified tracks, or unavailable files. Album sorting, Expand All, and Collapse All are available in the sidebar and View menu. Command-click and Shift-click support track selection.

Search and filter changes deselect tracks that leave the results, and album selection respects the active filter. MusicBrainz lookup operates on one album at a time. Batch scripts evaluate each track's own metadata, preserving distinct titles and track numbers.

**Library → Manage Libraries & Sessions…** provides naming, switching, automatic refresh settings, and workspace removal. Removing a workspace leaves all music untouched and retains its document in Application Support. The original single-session data migrates automatically to **My Session**. Catalogs, separate session documents, and recovery files live under `Application Support/MacPicard/Workspaces`; directory access is retained with security-scoped bookmarks.

The File, Edit, View, Library, and Metadata menus share their actions and enabled states with the on-screen controls. The sidebar and metadata inspector can be hidden, and the action bar adapts to narrower windows. **Help → MacPicard Guide** explains these workflows in the app.

Menu placement and persistent folder access follow Apple's [command groups](https://developer.apple.com/documentation/swiftui/commandgroupplacement) and [security-scoped URL access](https://developer.apple.com/documentation/foundation/url/startaccessingsecurityscopedresource()) APIs.

## Playback and right-click actions

Right-click a song in either the track list or an expanded sidebar album to **Play**, **Play Next**, **Add to Queue**, or **Play Album**. Play starts with the exact song clicked and continues through its album in numeric track order, without changing the metadata-editing selection. Double-clicking a main-list track also plays it. Right-click album rows for album playback and batch actions.

The native player uses Apple's [AVPlayer](https://developer.apple.com/documentation/avfoundation/avplayer) and supports the same MP3, FLAC, M4A/MP4, Ogg Vorbis, Ogg Opus, and WAV formats on macOS 26. Its bottom bar provides pause/resume, previous/next, stop, seeking, volume/mute, and a queue that can play or remove individual entries. Adding to an empty queue does not autoplay. Playback errors appear in the player with a retry action; missing files do not affect pending tag edits. Switching workspaces or quitting clears playback, and saving or organizing the playing file stops it before file operations.

The **Playback** menu provides Play Selected Track (⌘Return), pause/resume (⌘P), previous/next (⌃⌘← / ⌃⌘→), stop (⌘.), and Show Queue (⇧⌘P). Playback is intentionally transient and never starts automatically after relaunch.

Track and album context menus also provide metadata editing, MusicBrainz lookup, cover-art download, script editing, changed-tag saving, organization, selection, Finder reveal, and copying file paths. Batch actions use the current selection only if the clicked track belongs to it; otherwise they target that track. No context action deletes audio files.

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

## Phase 9

Phase 9 hardens the release path:

- Deterministic malformed-file and script-parser fuzz corpora exercise typed error handling without process crashes.
- Concurrent MusicBrainz requests, cancellation propagation, and release-sized track matching are covered by tests.
- Filesystem permission failures, security-scoped bookmark persistence, and session recovery boundaries are tested.
- English localization resources and accessibility audit criteria are documented for the native macOS UI.
- `Scripts/package-macpicard.sh` creates a reproducible `MacPicard.app` and zip archive with generated `.icns` artwork, metadata, resource validation, and code-signature verification.
- Distribution signing and notarization are supported through explicit `MACPICARD_CODESIGN_IDENTITY` and `MACPICARD_NOTARY_PROFILE` environment variables.

Implementation status: complete for the automated hardening and packaging gate. The remaining release checklist items are macOS environment validation steps requiring VoiceOver, accessibility settings, and upgrade installation testing; see [docs/RELEASE_CHECKLIST.md](docs/RELEASE_CHECKLIST.md).

## Local development

```sh
swift build -Xswiftc -strict-concurrency=complete
swift test -Xswiftc -strict-concurrency=complete
swift run MacPicard
```

The application targets macOS 26 and requires the Xcode 26 SDK because the production UI uses native Liquid Glass APIs.
