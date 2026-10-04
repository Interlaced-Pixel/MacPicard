# Improvement delivery evidence

This records implementation of `IMPROVEMENT_PLAN.md`, not the original bootstrap phases. No stub controls or placeholder implementations were added.

## Phase 1 — Command scope and truthful state

Committed as `abf33a5`.

- Shared action scope and availability support selection, explicit item sets, and the entire library.
- One recognizable Organize menu exposes selected files and the entire library. Review headings identify the actual scope.
- Monitoring has independent status, a five-minute default interval, and corrected menu/help/documentation. A passive no-op scan does not replace foreground status or selection.
- Unreachable fingerprint identification/submission UI is documented as future phase 6, not claimed as delivered.

This is the phase-1 historical state; improvement phase 6 below supersedes the fingerprint UI limitation.

Verification: OrganizationModelTests exercises entire-library organization with filtered selection and no-op monitoring. Native build passed. Existing organization execution/collision/recovery tests remain passing.

## Phase 2 — Functional Settings

Committed as `2a753eb`.

- Editable sections cover General, Libraries, Matching, Metadata/Saving, Artwork, Naming, Fingerprinting, Scripts, and Appearance.
- The default automatic-match threshold remains 85%; existing ambiguity/incompleteness checks still force review regardless of score.
- Matching country, preservation, artwork size/replacement, naming/script defaults, timestamp preservation, monitoring/recovery intervals, fingerprint-tool path, and appearance are honored by their respective operations.
- Schema-2 migration and atomic configuration persistence preserve unknown fields. Invalid drafts do not replace saved preferences. Save/Cancel/Restore Defaults are real actions.
- Credentials are explicitly loaded/edited and retained in Keychain, not configuration. Application and submission credentials have distinct fields. Fingerprint-tool validation checks the configured executable and version output.

Verification: migration, unknown-field retention, invalid-save protection, preference application, and invalid scripts are tested. The real Settings UI saved preferred country `GB` in an isolated workspace; the configuration on disk retained it through relaunch. No user libraries or credentials were edited during verification.

## Phase 3 — Full metadata editor and staged undo

Implementation is delivered; final interactive acceptance is **pending**.

- Searchable native Tag / Original / New table, changed-only and changed-first views, and optional common-field inspector editing.
- Custom tags, editable multi-value rows, removal, per-file original restore/merge, matching preservation, typed clipboard tag sets, and plain-text values.
- Presence, empty values, deletion, and mixed value arrays are distinguished without mutating files on selection. Copy explicitly uses the first selected file.
- Grouped staged undo/redo covers edits, scripts, reviewed/batch matches, and downloaded artwork. Native text editing retains its own undo manager.
- History is bounded, workspace-aware, revision/baseline-guarded, and cleared after successful disk saves/discard/moves/workspace changes. Undo cannot restore obsolete paths or undo a disk save.
- Read-only file details include location, size, format, measured duration, available audio properties, and availability/errors. Identifiers remain visible in the full tag table.
- Native audio import explicitly accepts supported files and directories. Folder-only library pickers have independent view hosts. This changes the picker configuration; final on-screen import verification remains pending.

Verification: tests cover multi-value editing, mixed selections, display-string collisions, single-transaction multi-tag removal, undo/redo, stale/newer edits, saved baselines, clipboard/merge, scripts, preserved MusicBrainz tags, persisted discard, and format round-trips. MP3, FLAC, M4A/MP4, Ogg Vorbis, Ogg Opus, and WAV round-trip custom/multi-value tags and deletions without losing unrelated tags.

## Final automated checks

- `swift test -Xswiftc -strict-concurrency=complete`: **164 tests selected, 159 passed, 5 opt-in skips, 0 failures** across eight test targets.
- Skips: live MusicBrainz (1), live Cover Art Archive (2), native Trash (1), and mounted cross-volume test (1). These are not claimed as passing.
- `xcodebuild -project MacPicard.xcodeproj -scheme 'MacPicard App' -configuration Debug -derivedDataPath DerivedData build`: **BUILD SUCCEEDED**.
- `git diff --check`: clean.
- Logs: `/tmp/macpicard-phase123-final-tests.log` and `/tmp/macpicard-phase123-final-build.log`.

## Interactive verification still required

The Mac locked during the isolated GUI run, and computer control reported that automatic unlock failed. Do not call phase 3 fully accepted until these checks finish:

1. Import the generated FLAC file through the rebuilt native picker and verify that Open enables and the file appears.
2. Open All Tags & Changes, add a custom tag with two values, apply, undo, redo, and restore/remove one tag.
3. Save/relaunch/discard against the generated fixture, ensuring Save/Discard enabled states and the original baseline stay correct.
4. Finish keyboard and VoiceOver checks of the new Settings/tag-editor controls. Comprehensive accessibility validation and large-library profiling remain part of later phases as well.

The isolated data directory is `/tmp/MacPicard-phase123.BjNsiH/State`, selected with `MACPICARD_DATA_DIRECTORY`; the audio fixture is `/tmp/MacPicard-phase123.BjNsiH/first.flac`. This test instance does not load the user's normal workspace catalog. No real music files were changed.

## Phase 4 — Scalable collection workspace

Committed as `6d50db6`.

Implemented native sortable/customizable track table, persistent sort/columns/optional toolbar buttons, overflow actions, sidebar destinations and collapsed artist grouping, album navigation independent of edit selection, debounced indexed multi-value search, affected-entry updates, and an openable bounded activity history. Playback remains independent.

Verification on October 4, 2026: 10 Browser/CollectionWorkspace tests passed; Xcode native build passed. The generated 2,000-file fixture verified that one genre edit updates only one index entry and leaves album groups/navigation intact. Preference round-trip and latest-query-wins debounce are tested. In the isolated native app (`/tmp/MacPicard-phase456.GD77Co/State`), FLAC import enabled Open and populated the table; sorting and Activity opened correctly. The prior phase-3 custom two-value add/undo/redo was also verified on screen. Full VoiceOver/accessibility-setting combinations and hardware-scale profiling are not claimed by these smoke checks.

## Phase 5 — Matching and review workspace

Committed as `c8ffd3c`.

Delivered inline/focused release comparison, detailed release information and score components, secure release URL/ID loading, explicit staged regrouping, two-way assignment drag/drop with accessible menus, result confidence/state filters, rejection/review-next, checkpointed/cancellable whole-library reads, and resumed baseline validation. Ready batch application rejects incomplete/ambiguous/conflicting/stale proposals regardless of score; 85% remains the default. Read/ranking work does not apply tags; full-release ranking runs off the main actor.

Verification: Browser/EditReview/MatchingWorkspace tests cover guarded staging, one-to-one assignments, missing/extras/multi-disc tracks, URL validation, checkpoint restore/resume, rejected proposals, cancellation, stale baselines and undo. Native Xcode build passed. The isolated app loaded the real Lukas Graham release `5e0abf8a-c77a-4826-b435-b3c23b22c0b1` through the secure MusicBrainz client and displayed country/date/barcode/archive availability and unmatched/missing-track counts. Its synthetic four-second audio remained unmatched; no tags were applied from the live lookup. Live lookup is read-only; no live AcoustID submissions are part of validation.

## Phase 6 — Audio fingerprint identification

Delivered selected/album/entire-library scans, selected/entire-collection offline generation, cancellable bounded processing, identity/calculator-version caching, AcoustID recording-to-MusicBrainz release resolution, normal assignment/tag review, and separately labeled fingerprint/release/track confidence. Missing tools and invalid audio have actionable/per-file errors. Generation and read jobs do not stage metadata. Explicitly approved mappings authorize submission; imported identifiers alone do not. The submission sheet requires batch consent, rechecks tag/disk baselines, and journals intent atomically before each non-idempotent write. Accepted/uncertain/interrupted attempts are not automatically resent, including after relaunch. No live submissions were made.

The packaged app requires a configured external official `fpcalc`; it does not bundle or silently install Chromaprint/FFmpeg. The official arm64 1.6.1 calculator was exercised with generated audio in a disposable directory. [FINGERPRINTING.md](FINGERPRINTING.md) documents setup, limits, credentials, privacy, and journal recovery cautions.

During native verification an inactive-folder-picker conflict was reproduced: a selectable FLAC could leave Open disabled. Folder selection now uses an on-demand native panel, preventing inactive folder importers from reconfiguring Import Audio. This supports the actual scan workflow instead of relying only on model fixtures.

Verification on October 4, 2026:

- Strict-concurrency full suite: **183 tests selected, 178 passed, 5 opt-in skips, 0 failures** across eight targets. Skips are native Trash, mounted cross-volume, live MusicBrainz, and two live Cover Art Archive checks; none are claimed as passing.
- Real official fpcalc 1.6.1 was exercised through the production provider on generated MP3, FLAC, M4A/AAC, Ogg Vorbis, Ogg Opus, and WAV audio, plus corrupt-audio rejection. Cache identity/version/corruption, calculator cancellation, diagnostic redaction, and durable journal behavior are tested.
- Application fixtures cover bounded/cached read-only generation, incorrect/untagged candidate resolution and explicit review, missing-tool/per-file failures, service-read cancellation, consent/verification/stale guards, and one-attempt uncertain submission behavior. No production credentials are loaded in these tests.
- Native Xcode app build succeeded. In the isolated app, the rebuilt picker enabled Open for FLAC and imported it, offline generation/re-generation displayed its measured 30-second result, accessible manual assignment exposed low similarity and 16 previewed tag differences, Apply staged those changes, and the current fingerprint batch opened a consent sheet with Submit disabled. Consent was not granted and no live write was made. The generated audio's SHA-256 remained unchanged through review/application/generation.
- Read-only live MusicBrainz release loading succeeded. No live AcoustID identification was attempted without an application key, and no live submission was made. Identification/submission response handling is covered by controlled transports.
- Full VoiceOver/mouse-drag combinations, all accessibility preferences, hardware-scale profiling, signing/notarization, and distribution remain future phase-10 validation; these smoke checks do not certify them.

The native staged application was undone with Command-Z: original title/artist/album returned and the fixture became Ready. The final rebuilt inspector was checked switching between both generated files; path, duration, size, and save availability followed the selection. Closing the isolated main window terminated its process after workspace persistence.

Logs: `/tmp/macpicard-phase456-final-tests.log`, `/tmp/macpicard-phase456-final-build.log`. Final native validation uses `/tmp/MacPicard-phase456.GD77Co/State`; only generated audio and this disposable workspace were changed. A selectable file-path label also now refreshes its native identity when the selected file changes, preventing stale path text in the inspector.
