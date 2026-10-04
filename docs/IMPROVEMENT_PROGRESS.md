# Improvement phases 1–3: delivery evidence

This records implementation of `IMPROVEMENT_PLAN.md`, not the original bootstrap phases. No stub controls or placeholder implementations were added.

## Phase 1 — Command scope and truthful state

Committed as `abf33a5`.

- Shared action scope and availability support selection, explicit item sets, and the entire library.
- One recognizable Organize menu exposes selected files and the entire library. Review headings identify the actual scope.
- Monitoring has independent status, a five-minute default interval, and corrected menu/help/documentation. A passive no-op scan does not replace foreground status or selection.
- Unreachable fingerprint identification/submission UI is documented as future phase 6, not claimed as delivered.

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
