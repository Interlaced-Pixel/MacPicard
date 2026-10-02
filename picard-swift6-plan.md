# Native Swift 6 MusicBrainz Tagger Plan

## Goal

Recreate the core Picard workflow as a native macOS application written in Swift 6:

```text
Import files
  -> read metadata
  -> cluster files into albums
  -> query MusicBrainz and AcoustID
  -> match files to releases and tracks
  -> apply scripts and cover art
  -> edit metadata
  -> save, rename, and move files
  -> persist sessions and recover unsaved work
```

The first production release intentionally supports only the most commonly used formats. Unsupported formats must be clearly rejected; they must not be represented by placeholder handlers.

Reference project: [MusicBrainz Picard](https://github.com/metabrainz/picard)

## Supported formats

### MP3

- ID3v1
- ID3v2.3 and ID3v2.4
- APIC embedded artwork
- Multiple artists, performers, genres, and MusicBrainz identifiers
- Lyrics, ratings, replay gain, track/disc numbers, and common vendor fields

### FLAC

- Vorbis comments
- Embedded pictures
- Multi-value tags
- MusicBrainz identifiers, replay gain, lyrics, and standard album metadata

### M4A/MP4

- iTunes atoms
- Freeform atoms
- Track and disc numbers
- Embedded artwork
- MusicBrainz identifiers and common iTunes metadata

### Ogg Vorbis and Ogg Opus

- Vorbis comments
- Embedded artwork
- Multi-value tags
- MusicBrainz identifiers and standard album metadata

### WAV

- RIFF/INFO metadata
- Supported embedded ID3 metadata
- Embedded artwork where supported by the selected tag backend

The initial release excludes WMA/ASF, APE, WavPack, Musepack, DSF, DSDIFF, TAK, TTA, OptimFROG, MIDI, AC3, and Ogg Theora.

## Core features

### File management

- Import individual files, folders, and recursive folder trees.
- Drag and drop files into the application.
- Detect files by extension and file header.
- Track original metadata separately from edited metadata.
- Detect external file modifications before saving.
- Track loading, changed, saving, error, removed, and unsupported states.
- Support cancellation and recovery for long-running operations.

### Metadata editing

- Edit single-value and multi-value tags.
- Add, replace, unset, and delete tags.
- Preserve unknown and configured tags.
- Edit multiple files at once.
- Display original, current, and calculated values.
- Support custom tags.
- Extract, edit, replace, and delete embedded artwork.

### Album clustering

- Group files by normalized album title and artist.
- Use album artist, artist, path, barcode, catalog number, and date when available.
- Allow manual cluster editing.
- Keep unmatched and non-album tracks separate.

### MusicBrainz integration

- Search releases, release groups, recordings, and tracks.
- Retrieve release metadata, artist credits, labels, dates, countries, genres, relationships, and ISRCs.
- Handle MusicBrainz IDs and redirects.
- Support user authentication where required for user-specific data.
- Cache API responses on disk.
- Implement host-aware rate limiting, retries, cancellation, and request priorities.
- Send a meaningful application User-Agent.

MusicBrainz API behavior must follow the [MusicBrainz API documentation](https://musicbrainz.org/doc/MusicBrainz_API) and [rate-limit requirements](https://musicbrainz.org/doc/MusicBrainz_API/Rate_Limiting).

### Release and track matching

Implement deterministic matching based on:

- Exact MusicBrainz IDs.
- Barcode, catalog number, label, and ISRC.
- Album title.
- Album and track artist.
- Track title.
- Track duration.
- Track count and track number.
- Release date, country, format, and release type preferences.
- Minimum similarity thresholds.
- Ambiguity margins.

The matcher must return an explicit result such as `exact`, `matched`, `ambiguous`, `rejected`, or `unmatched` rather than silently choosing a weak candidate.

### AcoustID and fingerprinting

- Generate Chromaprint fingerprints.
- Look up recordings through AcoustID.
- Associate fingerprint results with MusicBrainz recordings.
- Support fingerprint submission only when authentication and user consent are available.
- Rate-limit AcoustID requests.

Reference: [AcoustID Web Service](https://acoustid.org/webservice).

### Picard scripting

Implement the complete scripting functionality needed for tagging and file naming:

- `%variable%` expansion.
- Nested `$function(...)` calls.
- Escaping and Unicode escapes.
- Conditional expressions.
- String replacement, trimming, padding, case conversion, and regular expressions.
- Metadata get/set/unset/delete operations.
- Multi-value operations.
- Date and numeric operations.
- Performer and relationship functions.
- Track, album, and matching variables.
- Script syntax errors with line and column information.
- Script result caching.

Scripts must produce the same results as the reference Picard implementation for the supported operations.

### Cover art

- Query Cover Art Archive by release and release group.
- Download thumbnails or full-size images.
- Extract artwork from supported formats.
- Save artwork into supported formats.
- Discover local artwork files.
- Identify front, back, booklet, media, and other image types.
- Resize, convert, filter, and deduplicate images.

Reference: [Cover Art Archive API](https://musicbrainz.org/doc/Cover_Art_Archive/API).

### Saving and organization

- Save tags atomically.
- Serialize saves to prevent races.
- Warn when files changed externally.
- Preserve timestamps when configured.
- Rename files using a naming script.
- Move files into configured folders.
- Detect filename collisions before changing paths.
- Support save retry and failure recovery.
- Preserve or move configured additional files.

### Sessions and profiles

- Autosave the current session.
- Restore after a crash.
- Restore unsaved metadata changes.
- Persist file placement, album assignments, manual overrides, and expanded tree state.
- Store MusicBrainz cache data where useful.
- Export and import non-secret profiles.
- Keep credentials and secrets out of profile exports.

### Native macOS interface

Use SwiftUI for the application shell and AppKit bridges for high-density hierarchical views where necessary.

Required UI:

- File, cluster, album, and track hierarchy.
- Metadata editor.
- Multi-selection editing.
- Cover-art panel.
- Search and release lookup controls.
- Progress and error reporting.
- Options and profile editor.
- Script editor with validation.
- Drag and drop.
- Context menus and keyboard navigation.
- Accessibility support.

## Swift architecture

### Modules

```text
PicardDomain       File, Cluster, Album, Track, release state machines
PicardMetadata     Metadata values, diffs, originals, deletions, images
PicardFormats      Five format handlers and format registry
PicardNetworking   HTTP, caching, retries, rate limiting, OAuth
PicardMusicBrainz  API models, JSON mapping, release loading, matching
PicardScripts      Lexer, parser, AST, evaluator, built-in functions
PicardCoverArt     Image discovery, download, processing, embedding
PicardFingerprint  Chromaprint and AcoustID integration
PicardSessions     Sessions, autosave, profiles, migrations
PicardUI           SwiftUI/AppKit application interface
PicardCLI          Profiles, sessions, plugins, and diagnostics
PicardTestSupport  Fixtures, golden vectors, fake services, test corpus
```

### Concurrency model

- `@MainActor` for UI state and presentation.
- Actors for network scheduling, disk caches, session persistence, and file coordination.
- `Sendable` value types for data crossing actor boundaries.
- Structured concurrency for file loading and network work.
- A dedicated serialized save coordinator for tag writes and renames.
- Cancellation propagated through every long-running operation.

Use Swift 6 strict concurrency checks in CI. Do not update UI state from background tasks.

### Native and C interoperability

The application remains a native Swift application. Small C/C++ interop layers may be used for mature, well-tested libraries handling tag formats, Chromaprint, or disc IDs. The Swift layer must own the format contracts, error handling, metadata mapping, and tests.

Do not depend on AVFoundation alone for tag fidelity.

## Implementation phases

### Phase 1: Compatibility baseline

- Pin a specific Picard commit as the behavioral reference.
- Inventory supported metadata fields and script behavior.
- Build a fixture corpus for all five formats.
- Create golden metadata, matching, and script-output vectors.
- Define the macOS deployment and sandbox model.

Exit criteria: all planned behavior has an explicit testable contract.

### Phase 2: Swift foundation

- Create the Swift Package Manager workspace.
- Enable Swift 6 strict concurrency.
- Add CI, logging, diagnostics, error types, configuration, and migrations.
- Implement Keychain storage and security-scoped bookmarks.

Exit criteria: clean strict-concurrency build and working test configuration.

### Phase 3: Metadata and file model

- Implement `Metadata` and multi-value semantics.
- Implement original/current metadata and diffs.
- Implement file state transitions and identity checks.
- Implement artwork data structures.
- Implement session serialization primitives.

Exit criteria: metadata and session unit tests pass independently of the UI.

### Phase 4: Five-format engine

- Implement the MP3, FLAC, MP4, Ogg, and WAV handlers.
- Implement extension and header detection.
- Implement format-specific field mappings.
- Implement artwork read/write.
- Implement atomic save and reopen tests.

Exit criteria: every declared format passes read, write, Unicode, artwork, unknown-tag, corruption, and round-trip tests.

### Phase 5: MusicBrainz and matching

- Implement the rate-limited HTTP client.
- Implement MusicBrainz API models and JSON decoding.
- Implement release and recording lookup.
- Implement clustering and matching.
- Add cache, retry, cancellation, and authentication behavior.

Exit criteria: golden matching vectors and deterministic network fixtures pass.

### Phase 6: Scripts and automatic identification

- Implement the scripting parser and evaluator.
- Implement all required built-in functions.
- Integrate scripts with album, track, file, and metadata contexts.
- Add Chromaprint and AcoustID support.

Exit criteria: reference scripts produce equivalent output and fingerprint lookups work against test fixtures.

### Phase 7: Cover art, saving, and sessions

- Implement Cover Art Archive integration.
- Implement image processing and embedding.
- Implement serialized saves, renames, moves, collisions, and recovery.
- Implement autosave, crash recovery, profiles, and migrations.

Exit criteria: a complete import-to-save workflow survives application restart and file reopening.

### Phase 8: Native UI

- Build the file and album hierarchy.
- Build metadata and artwork editors.
- Add lookup, matching, progress, error, options, and script views.
- Add keyboard navigation, accessibility, drag/drop, and multi-selection.

Exit criteria: all primary workflows are available without developer tools or manual file edits.

Implementation status: complete. The executable target now provides the primary import, cluster, edit, identify, cover-art, script, save, organize, session-recovery, keyboard, accessibility, drag/drop, and multi-selection workflows. The visual system uses macOS 26 Liquid Glass for controls and navigation with standard materials for content.

### Phase 9: Production hardening

- Add malformed-file fuzzing.
- Add script-parser fuzzing.
- Test large libraries and concurrent requests.
- Test cancellation and crash recovery.
- Test filesystem permissions and sandbox bookmarks.
- Add localization and accessibility audits.
- Sign, notarize, and upgrade-test the application.

Exit criteria: release builds contain no stubs, placeholder handlers, fake services, or unimplemented required functions.

## Testing requirements

### Unit tests

- Metadata operations and diffs.
- Format mappings.
- Script parsing and evaluation.
- Matching scores.
- Filename generation.
- Session migrations.
- Configuration behavior.

### Integration tests

```text
Import files
  -> cluster album
  -> identify MusicBrainz release
  -> match tracks
  -> run tagging script
  -> download cover art
  -> save tags
  -> rename/move files
  -> close and reopen application
  -> verify final metadata and session state
```

### Format corpus tests

For every supported format, test:

- Existing tags.
- Empty tags.
- Unicode.
- Multiple values.
- Artwork.
- Unknown fields.
- Deleted fields.
- Corrupt headers.
- Large files.
- Save and reopen behavior.

### Production rules

- No `TODO` or `fatalError` in required production paths.
- No fake API responses outside test targets.
- No format handler that only reads but cannot save.
- No silent fallback from a failed write.
- No background task may mutate UI state directly.
- Every supported feature must have unit and integration coverage.

## Definition of done

The first production release is complete when it supports:

- MP3, FLAC, M4A/MP4, Ogg Vorbis, Ogg Opus, and WAV.
- Reliable metadata read/write and artwork handling.
- MusicBrainz lookup and release matching.
- AcoustID identification.
- Picard-compatible tagging and naming scripts.
- Cover Art Archive integration.
- Rename and move operations.
- Autosave, crash recovery, and profiles.
- A responsive native macOS interface.
- Complete tests for every declared format and core workflow.
- Signed and notarized distribution.

Anything beyond this list should be treated as a later extension rather than weakening the first release's supported behavior.
