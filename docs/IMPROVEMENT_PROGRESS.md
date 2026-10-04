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

Calculator delivery was revised to meet the Interlaced Pixel zero-setup requirement: the official universal Chromaprint 1.6.1/FFmpeg 8.0 helper is bundled and signed in the app, with licenses, complete corresponding sources, and offline rebuild recipes. The registered publisher AcoustID application key is embedded from ignored local build configuration; users never supply an application key or executable path. Legacy configured paths are ignored. [FINGERPRINTING.md](FINGERPRINTING.md) documents delivery, limits, optional contribution authentication, privacy, and journal recovery cautions.

During native verification an inactive-folder-picker conflict was reproduced: a selectable FLAC could leave Open disabled. Folder selection now uses an on-demand native panel, preventing inactive folder importers from reconfiguring Import Audio. This supports the actual scan workflow instead of relying only on model fixtures.

Verification on October 4, 2026:

- Strict-concurrency full suite: **183 tests selected, 178 passed, 5 opt-in skips, 0 failures** across eight targets. Skips are native Trash, mounted cross-volume, live MusicBrainz, and two live Cover Art Archive checks; none are claimed as passing.
- Real official fpcalc 1.6.1 was exercised through the production provider on generated MP3, FLAC, M4A/AAC, Ogg Vorbis, Ogg Opus, and WAV audio, plus corrupt-audio rejection. Cache identity/version/corruption, calculator cancellation, diagnostic redaction, and durable journal behavior are tested.
- Application fixtures cover bounded/cached read-only generation, incorrect/untagged candidate resolution and explicit review, missing-tool/per-file failures, service-read cancellation, consent/verification/stale guards, and one-attempt uncertain submission behavior. No production credentials are loaded in these tests.
- Native Xcode app build succeeded. In the isolated app, the rebuilt picker enabled Open for FLAC and imported it, offline generation/re-generation displayed its measured 30-second result, accessible manual assignment exposed low similarity and 16 previewed tag differences, Apply staged those changes, and the current fingerprint batch opened a consent sheet with Submit disabled. Consent was not granted and no live write was made. The generated audio's SHA-256 remained unchanged through review/application/generation.
- Read-only live MusicBrainz release loading succeeded. The initial phase 6 verification used controlled AcoustID transports; the zero-setup follow-up below adds real AcoustID identification with publisher credentials. No live submission was made.

## Zero-setup delivery follow-up — 2026-10-04

Completed the publisher-directed change to self-contained app delivery:

- Vendored the official universal Chromaprint 1.6.1 calculator, statically linked FFmpeg 8.0 audio decoders, full licensing notices, complete source archives, upstream build recipes, and an offline universal rebuild script. Only macOS system libraries are dynamically loaded.
- Default fingerprinting uses the app's signed `Contents/Helpers/fpcalc`, never Homebrew/PATH or legacy executable preferences. Processes use a system-only environment. Damaged installed bundles cannot fall back to an external development tool.
- Xcode Run/Archive and standalone packaging share payload checksum/architecture/dependency checks, publisher-key validation, resource copying, and explicit nested-helper signing. Standalone packaging assembles and verifies before publishing, refuses existing outputs, and preserves older builds.
- Identification uses the registered publisher key embedded from ignored local build configuration, without reading the user's Keychain. Settings has no executable picker or application-key input. Personal authentication remains solely for optional, explicitly consented database contributions.
- Bundled TagLibSwift/TagLib license texts and the pinned complete corresponding source archive are now included in app resources as well.

Validation:

- Strict Swift 6 suite: **187 tests selected, 182 passed, 5 existing opt-in environment/live tests skipped, 0 failures**. This includes an always-on Swift-generated WAV test using the default bundled provider, damaged-app isolation, publisher-resource parsing/redaction, ignored legacy calculator preferences, built-in diagnostics, and official-calculator decoding of all six formats plus corrupt input.
- Native Debug app build and deep signature verification passed. Incremental installation was exercised; read-only dependency licenses are normalized for safe repeated builds. Invalid publisher configuration was rejected before helper installation.
- The included source-only rebuild recipe successfully compiled both arm64 and x86_64 helper slices without downloading any source/dependency. The resulting universal helper decoded generated MP3, FLAC, M4A/AAC, Ogg Vorbis, Ogg Opus, and WAV with a system-only PATH. Intel execution on Intel hardware remains a separate distribution QA step.
- A standalone packaged app clone launched with a fresh data directory and `/usr/bin:/bin` PATH. Its six-format library generated offline fingerprints and completed live AcoustID identification without opening credentials or configuring a calculator. Synthetic tones correctly returned no recording candidates; all six files remained unchanged. Built-in Settings diagnostic returned calculator 1.6.1, and closing the main window exited the app. No actual user catalog, credentials, or music was modified.
- A read-only HTTPS lookup with the registered application credential returned `status: ok` and an empty synthetic-tone result. No live submissions were sent.

Local builds are ad-hoc signed, **not notarized**. Developer ID/notarization, accessibility/upgrade QA, commercial AcoustID authorization if applicable, and remaining improvement phases retain their independent release gates.
- Full VoiceOver/mouse-drag combinations, all accessibility preferences, hardware-scale profiling, signing/notarization, and distribution remain future phase-10 validation; these smoke checks do not certify them.

The native staged application was undone with Command-Z: original title/artist/album returned and the fixture became Ready. The final rebuilt inspector was checked switching between both generated files; path, duration, size, and save availability followed the selection. Closing the isolated main window terminated its process after workspace persistence.

Logs: `/tmp/macpicard-phase456-final-tests.log`, `/tmp/macpicard-phase456-final-build.log`. Final native validation uses `/tmp/MacPicard-phase456.GD77Co/State`; only generated audio and this disposable workspace were changed. A selectable file-path label also now refreshes its native identity when the selected file changes, preventing stale path text in the inspector.

## Phase 7 — Full artwork management — 2026-10-04

Implementation delivered; **final interactive artwork acceptance remains pending**. This is the improvement-roadmap artwork phase, not the original bootstrap phase 7.

- Native manager reached through Cover Art, Metadata → Manage Artwork (⌥⌘A), inspector, and track/album context menus. Selectable ordered image list, last-saved/staged comparison with an original-image picker, types/descriptions, measured dimensions, sizes and sources.
- Local image picker, Finder drop, validated HTTPS image import, and individually selected release/release-group archive downloads. Atomic append/selected replacement/set replacement, remove/reorder, removed-image restore, restore-all and bounded sheet-local undo/redo. Selected replacement retains the original image identity.
- Frozen selection/album/workspace scope with explicit reviewed whole-scope set replacement. Image decoding/conversion and final batch validation run off the main actor. Cancellation and stale baselines reject changes before commit. Applying is one global staged undo transaction; sessions preserve both pending artwork and the saved discard baseline. Audio Save Tags is still separate.
- Explicit orientation-aware downsampling, JPEG/PNG conversion, quality/embedding preferences with legacy-compatible defaults, and export-only mode. Bounded previews do not decode full-size images in SwiftUI body evaluation.
- Complete single-frame images only; 32 MiB/image, 40 megapixels, 16,384-pixel side, 64-image/128 MiB set limits. Network downloads are streamed with byte limits; cache/local reads are bounded. JPEG/PNG bytes are checked before embedding. M4A supports ordered multiple covers, not roles/descriptions; unsupported roles are rejected and description removal is explicit. Booklet/Obi map to native Leaflet/Other roles.
- Native writes close buffered TagLib handles before fresh read-back verifies image bytes/order/types and supported descriptions. This fixes false-success/stale-read behavior for M4A removal and same-size Ogg reordering. Failed verification leaves the original audio intact through the existing temporary-file save transaction.
- Reviewed export with stop/unique-name collision policies, exclusive no-follow file creation, destination identity rechecks, cancellation/failure cleanup of owned files, and a quit guard during export. No existing file is overwritten. Export is not claimed to be a power-loss-atomic multi-file transaction.
- Remaining inactive SwiftUI organization folder importer now uses an on-demand native panel. Library folder panels no longer restrict content types redundantly. Normal LaunchServices launch enabled the isolated library picker; direct executable launch without normal app context did not. The panel change alone is not credited with fixing that launch-context behavior.

Validation:

- Swift 6 strict-concurrency full suite: **201 selected, 196 passed, 5 opt-in skips, 0 failures** across eight targets. Skips are native Trash, mounted cross-volume, live MusicBrainz, and two live Cover Art Archive checks; they are not counted as passing in this run. Configuration migration/round-trip and invalid artwork preferences are also exercised.
- Separately, both opt-in **live Cover Art Archive tests passed** using read-only release/release-group requests and image download. No remote metadata writes, fingerprint submissions or local audio uploads were made.
- All six actual audio containers passed multiple-image order/role/description checks where supported, reordered writes, remove-all, and rejection of malformed images or incompatible M4A roles without replacing source bytes. The same six-format round-trip test also passed in an optimized Release build. Saved M4A baselines reflect its real container capabilities.
- Model tests cover import replacement/restore identity, all-or-nothing failure, batch application/undo, cancellation, workspace/file staleness, session persistence/discard and untouched tags/paths. Image/export tests cover oversized headers/data/sets, malformed/animated images, orientation, transparent JPEG backgrounds, measured dimensions, URL policy, collisions, symlinks and replaced folders.
- A native NSHostingView rendering test produced an inspected artwork manager preview with two images and correct measured dimensions. This is an offscreen view render, **not** desktop-interaction acceptance.
- Native Xcode Debug build succeeded. Fresh standalone Release package and deep signature verification succeeded at `/Users/jayian/Downloads/MacPicard-Phase7-2026-10-04-Final/MacPicard.app` and `MacPicard.zip`. Bundled fingerprint calculator, publisher configuration and dependency licenses remain included. The build is ad-hoc signed, **not notarized**; older Downloads builds were preserved.
- A normal LaunchServices launch with an isolated catalog and system-only PATH enabled the music-library picker and indexed two generated files. Their SHA-256 hashes stayed unchanged. No actual user library/catalog or music file was edited.
- A clone of the final packaged Release app also launched with the isolated catalog and system-only PATH, displayed both generated tracks and the enabled Manage Artwork action, and retained the clean file state. Opening its artwork sheet reproduced the same computer-control service failure; it is not credited as a successful artwork interaction.

Interactive limitation: the Mac initially locked. After it became accessible, opening Manage Artwork repeatedly terminated **SkyComputerUseService** with an array-removal trap while the isolated MacPicard process stayed running. No successful mouse/keyboard image import, draft apply, export review or save/relaunch workflow is claimed from that automation. Complete those checks from [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md), including VoiceOver and accessibility preferences, before calling phase 7 fully accepted. The isolated test catalog is `/var/folders/33/x3xnfb696fzbcstg9sh4gd6m0000gn/T/MacPicard-phase7.twTPPanYLV/State`; its audio is disposable synthetic data.

Logs: `/tmp/macpicard-phase7-final4-tests.log`, `/tmp/macpicard-phase7-release-roundtrip.log`, `/tmp/macpicard-phase7-live-artwork.log`, `/tmp/macpicard-phase7-native-final.log`, and `/tmp/macpicard-phase7-package-final.log`. User-facing workflow and safety limits are documented in [ARTWORK.md](ARTWORK.md). Phases 8–10 retain separate implementation and release gates.
