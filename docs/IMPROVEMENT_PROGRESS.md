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

## Phase 8 — Managed workflows and MusicBrainz-inspired design — 2026-10-04

Implementation delivered; **interactive acceptance remains pending** because the native computer-control service failed during validation. Phases 9–10 remain separate work.

- Requested visual redesign: original generated purple/orange geometric music-tag icon, MusicBrainz-inspired palette/header, warm neutral native surfaces and light/dark action tints. The official logo/wordmark was not copied. Native Xcode and standalone builds generate the `.icns` family. Source, provenance, final generation prompt and primary identity references are documented in [DESIGN.md](DESIGN.md).
- Collection Tools is a separate native window with Workflow, Scripts, Filename → Tags and Profiles tabs, shared Selection/Album/Entire collection scope, and menu/toolbar entry points. Main-window close still requests app termination even with tools open; recursive termination requests are guarded.
- Named tagging/naming scripts support create, rename, duplicate, delete confirmation, execution order, enablement, JSON import/export and atomic saved-library persistence. Ordered enabled tagging scripts run against each track's own metadata with per-file variables and location-bearing failures; naming previews never stage tags. Managed naming scripts also appear in organization presets and can update the shared naming default.
- Filename parsing uses explicit relative-path captures and field mappings, sample display, number normalization, ambiguity detection and per-file reviewed staging. It preserves unmapped fields and rejects invalid/duplicate mappings and traversal. Parsing budgets bound pathological separator searches; scripts are bounded to 64 KiB/64 nesting levels with cancellation checks.
- Profiles capture a whitelist of matching, naming, tagging, artwork and timestamp preferences. Activation changes only checked groups, preserves unrelated settings/workspaces/pending edits and excludes credentials, paths and bookmarks. Profile and script drafts survive tab changes, have explicit save/revert, and share validated bounded import/export. Corrupt workflow data is retained, with Reveal Data/Retry Load guidance instead of silent replacement.
- Batch previews freeze workspace/file baselines, show included/excluded/blocked/unchanged counts and original/new values, provide lazy searchable rows, require blocked-file acknowledgement and stage one existing undo transaction. Cancel/stale inputs cannot partially apply a batch.
- Guided identify/review → stage → review/write changed tags → review saved/clean organization never auto-chains mutations. Actual per-file save outcomes admit only unchanged saved/clean baselines to the move step; failed, cancelled, unavailable and pending files remain excluded. Save review/results use lazy bounded scroll areas. Independent whole-scope organization includes unavailable indexed files as blocked review rows and retains identity/collision/no-overwrite/rollback/confirmation safeguards.
- Graphify's foundation graph and current source review guided reuse of existing staged-edit and reviewed-save/move transactions rather than a separate mutation pipeline.

Validation:

- Strict Swift 6 full suite: **212 selected, 207 passed, 5 opt-in skips, 0 failures**. Skips remain native Trash, mounted cross-volume, live MusicBrainz and two live Cover Art Archive checks; they are not counted as passing. Bundled-calculator/six-format fixtures were provided. New tests cover ordered per-file scripts, disabled/naming isolation, ambiguity/mappings, scope independent of filter/selection, stale/cancelled review, undo/redo, profile whitelist, bounded/invalid/corrupt persistence and unique merge identities.
- An actual isolated FLAC save batch saved one file and failed another missing source: the failure stayed pending and was not eligible for guided organization. A pre-cancelled save changed no audio bytes and reported no saved outcomes. The original synthetic fixture hashes remained unchanged.
- All four Collection Tools tabs rendered with populated fixtures in light and dark appearances; their layouts were inspected. These are offscreen native `NSHostingView` renders, **not desktop-interaction acceptance**.
- The 11 managed-workflow/model tests also passed in an optimized Release build, including the real partial-save/cancelled-save fixture test. Final strict-concurrency runs reported no compiler warnings.
- Native Xcode Debug build and standalone optimized Release packaging succeeded. Deep signature verification and zip integrity checks passed for `/Users/jayian/Downloads/MacPicard-Phase8-2026-10-04-Verified/MacPicard.app` and `MacPicard.zip`. Fingerprint helper, publisher configuration and license/source resources remain packaged. Builds are ad-hoc signed, **not notarized**; older packages were preserved.
- Isolated LaunchServices launch displayed the redesigned main app and enabled fixture import picker. Immediately after importing/attempting to open tools, computer-control observation failed; the app process initially stayed running. No successful interactive script/profile/parser/save/move sequence or close-with-tools check is claimed. Diagnostics identify SkyComputerUseService `SIGTRAP` in `Array.remove(at:)`, not a reported MacPicard crash. Reset/reconnect did not recover the service.

Complete the explicit phase-8 desktop and accessibility checks in [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md) before declaring this phase fully accepted. Guide: [WORKFLOWS.md](WORKFLOWS.md). Validation logs: `/tmp/macpicard-phase8-verified-tests.log`, `/tmp/macpicard-phase8-verified-release-tests.log`, `/tmp/macpicard-phase8-verified-native.log`, `/tmp/macpicard-phase8-verified-package.log`. Test catalog: `/tmp/MacPicard-phase8.dpiuO0/State`; no real user catalog/music was modified.

## Compact interface revision — 2026-10-04

- Replaced the large matching cards with aligned local-file/track rows, bounded columns, confidence scores and assignment menus. Long titles truncate without displacing controls. Tag changes open in a 165-point lower pane; release information is a popover and release order opens on demand. Single-result searches keep the results rail closed; score details remain expandable.
- Removed the album banner during matching and reduced the normal album summary to a 40-point thumbnail with short title/artist/count text. The toolbar now has Import, Look Up, Organize and More. Save appears for selected edits; Look Up is hidden while matching is open. Duplicate toolbar actions and sidebar filter destinations were removed; filters and artist grouping remain in their menus. The inspector is capped at 380 points with tighter field spacing. Native bordered controls replace glass button styles whose labels lost contrast in the dark-mode inspection; primary actions keep explicit theme tints.
- Reviewed labels, tooltips and descriptions across menus, settings, workspaces, playback, metadata, artwork, matching, scripts/profiles and organization. Replaced developer terminology and promotional headings with short actions. Kept disk-write, file-move, recovery and submission-consent warnings. Updated the guide and documentation to match the controls.
- Edited the icon with built-in image generation to remove the off-white tile and shadow. The source and generated `.icns` retain transparency and the opaque white note; the packaged 32-point icon was visually inspected. Prompt and provenance: [DESIGN.md](DESIGN.md).
- Graphify's foundation graph and direct source review guided reuse of the existing one-to-one assignments, stale-review checks and save/move transactions. No alternate mutation pipeline was introduced. The native project adds the view and tests while preserving existing target/scheme identities.

Validation:

- Final strict-concurrency suite: **214 selected, 209 passed, 5 opt-in skips, 0 failures**. Skips remain native Trash, mounted cross-volume, live MusicBrainz and two live Cover Art Archive tests. The two new interface tests also pass in optimized Release mode.
- Inspected six native offscreen renders: workspace and matching at 1180 × 760, plus open tag changes/release order at 720 × 500, in light/dark mode. Fixtures include 12 local files, 14 release tracks and a long remix title. Rendering leaves files and assignments unchanged. Alpha and white-note checks pass.
- Native Xcode Debug build and optimized standalone packaging pass. Deep signature verification and zip integrity checks pass for `/Users/jayian/Downloads/MacPicard-Compact-2026-10-04-Final/MacPicard.app` and `MacPicard.zip`. Bundled calculator, publisher configuration and license/source resources remain included. Ad-hoc signed, **not notarized**; previous builds were preserved.
- LaunchServices with an isolated catalog and system-only PATH displayed the compact main window. File and More menus and their enabled states were inspected. The fixture import was cancelled; opening Collection Tools then closed the computer-control pipe. MacPicard remained running; SkyComputerUseService reported `SIGTRAP` in `/Users/jayian/Library/Logs/DiagnosticReports/SkyComputerUseService-2026-10-04-091343.ips`. Interactive matching/save/move, keyboard and VoiceOver acceptance are still pending, not counted as passing. Original synthetic audio hashes are unchanged; no real library was opened.

Logs: `/tmp/macpicard-compact-final-contrast-tests.log`, `/tmp/macpicard-compact-final-contrast-release.log`, `/tmp/macpicard-compact-final-contrast-native.log`, `/tmp/macpicard-compact-final-package.log`. Render prefix: `/tmp/macpicard-compact-final-contrast`. Isolated desktop catalog: `/tmp/MacPicard-compact-ui.RTdcrOMn/State`.

## Theme correction and Phase 9 — Passive monitoring, scheduling and recovery

Implemented 2026-10-04. Graphify's foundation graph identified the existing identity, session and security-scope services; direct source inspection covered newer workspace/job code absent from that graph. The implementation extends these services rather than introducing another audio-write pipeline.

- The MusicBrainz identity now uses system-neutral surfaces, adaptive accent text and a separate dark primary-button fill. Warning/success/failure colors have light/dark variants. Contrast tests require at least 4.5:1 for these foregrounds against window backgrounds, including increased-contrast appearances, and for white primary-button labels. Ordinary toolbar controls remain neutral; transient selection and action links use purple.
- Recursive [FSEvents notifications](https://developer.apple.com/documentation/coreservices/file_system_events) are hints. A two-second debounce coalesces bursts, caps pending paths at 512, and promotes overflow/dropped events/root changes/mount changes to a full scan. A five-minute default polling fallback covers missed notifications. Paths are canonicalized, including macOS's `/var` and `/private/var` aliases; a real notification test exposed and verified this requirement.
- Incremental scans inspect affected files/subtrees only, reuse unchanged metadata, and preserve UUIDs for unambiguous same-inode renames. Offline or unreadable roots fail without turning the entire library into missing items. Repeated missing/corrupt-file scans suppress duplicate changes and warnings. Background passes wait for playback, pending edits, reviews, workspace switches and foreground operations. Manual Refresh preempts quiet scans and exposes progress/cancellation.
- Scan deltas merge into current revisions, preserving newer edits, imports, removals and navigation. Workspace/generation/scan IDs reject stale completions. A brief guarded commit serializes persistence with user mutations; availability is republished when it finishes. No-op passes publish no file arrays, rebuild no browser entries and perform no session/catalog writes.
- Session/recovery saves ignore timestamp-only differences. Identical autosaves do not rewrite either document. A valid recovery document can restore a corrupt primary; if neither document is valid, loading fails rather than replacing them with an empty workspace.
- File identities clear URL resource caches before reading size/date/inode. This fixes an externally replaced file with an unchanged first 8 KB bypassing the old identity check. Atomic tag writes revalidate the original again immediately before replacement and honor cancellation before committing.
- Activity retains per-file import/save/refresh/organization outcomes on disk. Save retries require unchanged persisted revisions and exclude successes. Import retries are idempotent; interrupted mutations never replay automatically. Matching's existing checkpoint/Resume path continues verified read-only work. Read-only Check Files reports progress/cancellation and revalidates previous recovery results; source/destination/temporary paths can be revealed and copied.
- Move journals persist exact intermediate paths before staging a source. Known completed effects are restored only when identities and pending-edit baselines still match. Unknown or ambiguous writes/moves preserve edits and show recovery guidance. Successful filesystem effects reach the journal/workspace before completion is reported; persistence failure stops further writes. Quit is guarded during audio writes, import copies, moves and artwork export.

Targeted validation:

- Strict Swift 6 suite: **228 selected, 223 passed, 5 opt-in skips, zero failures**. Skips remain native Trash, mounted cross-volume, live MusicBrainz and two live Cover Art Archive checks, not counted as passing. The targeted phase-9/interface run also passed **47 tests in optimized Release mode, zero skips or failures**. New cases exercise actual recursive notifications, a 20-file burst producing one publication, 100 coalesced hints, pending-edit deferral/manual override/cancellation, one-file incremental reads, renamed draft preservation, stale delta merges, repeated missing files/warnings, zero no-op writes, corrupt-primary recovery, interrupted temporary moves, replaced-file identity, persisted retry baselines and real partial tag saves. Existing matching Resume/checkpoint tests remain covered.
- Native desktop validation used only copied/generated FLAC fixtures in `/tmp/MacPicard-phase9-ui.SPbDfc8C/State`, launched through LaunchServices with system-only PATH. Activity opened and expanded, exposed native Check Files/Retry buttons, checked a failed save without dropping its draft, retried just that file, and showed a completed one-file save. The main table changed to Saved and its pending-edits indicator disappeared. Two recursive external file additions appeared automatically while preserving selection and the foreground save message. A caught busy-availability publication issue was corrected and rechecked in the final build. Closing the main window terminated the isolated app process; no MacPicard crash report was found.
- Instruments Time Profiler recorded the real 20-file notification/coalescing test on this Apple Silicon MacBook Air (8 GB), 4.60 seconds, exit 0. The potential-hangs table contains **zero rows at its configured >250-ms threshold**. This does **not** establish the roadmap's stricter 100-ms/10,000-file release gate. Trace: `/tmp/macpicard-phase9-monitoring.trace`; exported table: `/tmp/macpicard-phase9-hangs.xml`.
- App render fixtures cover workspace, compact comparison and expanded match detail in both appearances. No real user catalog or music was modified. Full VoiceOver and earlier phases' desktop workflow matrices remain open, as does Developer ID signing/notarization.

Final logs: `/tmp/macpicard-phase9-final-tests.log`, `/tmp/macpicard-phase9-final-native.log`, `/tmp/macpicard-phase9-release-final-tests.log`, `/tmp/macpicard-phase9-final-package.log`. Delivered build: `/Users/jayian/Downloads/MacPicard-Phase9-2026-10-04-Final/MacPicard.app`, with `MacPicard.zip`. Ad-hoc signed, not notarized; older builds are preserved.

## Music Library unification — 2026-10-04

- Music Library is the only workspace type. Removed New Session, Save Session As, the Sessions chooser section, session-specific imports/removal, and library/session wording. File, Library, sidebar, settings, artwork/workflow scope, empty states and the in-app guide use library actions consistently.
- New Music Library creates an app-managed folder; Open Music Folder indexes an existing collection. Both support the same copy-and-organize imports, matching, tag editing, monitoring, organization and recovery. Import/drop cannot silently fall back to referencing originals when no library is open.
- Catalog schema 2 migrates older session entries into Music Libraries while retaining IDs, names, edits, artwork, history, exclusions, bookmarks and file paths. New owned music folders receive future imports; existing session originals are neither moved nor copied during migration and stay ineligible for library Trash. The saved-document format and storage paths remain compatible. Migration is idempotent and rejects invalid catalogs without replacing them. Graphify's foundation graph and current-source review guided reuse of the existing saved-document/bookmark services and import engine.
- Removing the last library retains music and saved/recovery documents, clears playback/navigation/monitoring, and shows the create/open screen. An intentionally empty catalog stays empty after restart; it does not recreate a session or re-import the original single-document installation.

Validation:

- Swift 6 strict-concurrency suite: **232 selected, 227 passed, 5 opt-in skips, zero failures**. The same external/live checks remain skipped. **36 focused Release tests passed without skips or failures**. Added migration tests check unchanged audio and primary/recovery document bytes, preserved pending edits/bookmark keys/exclusions and IDs, idempotence and invalid-catalog rejection. App tests cover single-document migration, managed imports, no-library import rejection and removal/restart behavior.
- Native isolated desktop validation exercised File-menu creation, the single library chooser, management, switching after removal, and final-library removal. A fresh launch of the packaged Release app confirmed the empty catalog remained empty and Import was disabled. The isolated catalog is `/tmp/MacPicard-libraries-ui.JRsOAxrc/State`.
- Desktop-control limitation: requesting app state after closing the isolated Debug app caused the control service to relaunch it without its test environment. That instance opened the normal catalog and ran startup migration/refresh; it was quit. No import, tag-save, artwork-apply, organization or Trash action was invoked in that instance. The subsequent packaged restart check explicitly restored the isolated environment and avoided reacquiring a closed app. Full VoiceOver acceptance remains a separate release gate.
- Final native Xcode Debug build, optimized app packaging, deep signature verification and zip integrity checks passed. The app includes its existing calculator, publisher configuration and dependency resources. Ad-hoc signed, **not notarized**; previous builds were preserved.

Logs: `/tmp/macpicard-libraries-final-tests.log`, `/tmp/macpicard-libraries-release-tests.log`, `/tmp/macpicard-libraries-final-native.log`, `/tmp/macpicard-libraries-package.log`. Build: `/Users/jayian/Downloads/MacPicard-MusicLibraries-2026-10-04/MacPicard.app` and `MacPicard.zip`.
