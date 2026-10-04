# MacPicard

Native macOS Swift 6 recreation of the core MusicBrainz Picard workflow.

The first release targets MP3, FLAC, M4A/MP4, Ogg Vorbis, Ogg Opus, and WAV. The active end-to-end roadmap is documented in [docs/IMPROVEMENT_PLAN.md](docs/IMPROVEMENT_PLAN.md). The phase sections below record the original implementation history; they are separate from the new improvement phases.

The current identity uses MusicBrainz-inspired purple/orange accents and an original geometric music-tag icon; MacPicard remains independent. See [Design](docs/DESIGN.md). **Library → Collection Tools…** (⇧⌘K) unifies Selection/Album/Entire collection scope with named ordered scripts, reviewed filename-to-tag parsing, scoped configuration profiles and separate identify/stage/save/organize steps. Failed or still-pending saves never enter guided organization. [Collection Tools guide](docs/WORKFLOWS.md) covers persistence, imports, profile scope and safety.

## Libraries and sessions

Choose **File → Add Music Library…** (⌘O) to link a music directory. Supported audio files in its subfolders are indexed. Monitoring coalesces folder notifications into quiet background checks, with a five-minute fallback for missed events. Checks wait during playback, pending edits, reviews and foreground work. Unchanged libraries do not rebuild the browser or write their workspace. **Library → Refresh Library** (⌘R) checks immediately with progress and cancellation, even with pending edits. Refreshes preserve edits, detect external changes, track unambiguous renames, and retain unavailable files until their drive reconnects. Use **Reconnect Library Folder…** to restore folder access.

**Activity** keeps per-file results for imports, tag saves, manual refreshes and organization. **Retry Failed Files** retries only unchanged failed save drafts or unfinished imports; successful files are not rewritten. **Check Files** inspects interrupted saves/moves without writing audio. Known completed results are recovered after restart only when their filesystem identity and pending-edit baseline still match. A file found at a temporary move path is left intact; Activity provides its original, destination and temporary paths for recovery. Matching's **Resume** continues safe read-only jobs, rechecking stale proposals. No interrupted write or move is automatically replayed.

Importing or dropping external music into a **Music Library** copies it into that library folder, organized as `Album Artist/Album/01 - Title.ext` (with a disc prefix for multi-disc albums). Original files and embedded metadata stay untouched. Missing tags fall back to artist/album placeholders and the source filename. Identical files at the organized destination are reused; different files with the same name receive a numbered suffix, never an overwrite. Files already inside the library are indexed in place. A **Session** continues to reference originals without copying them.

Choose **File → New Session…** (⌘N) for an independent tagging workspace, or **Save Session As…** (⇧⌘S) to snapshot the current files and pending edits. Switch with the sidebar workspace chooser or **File → Open Workspace**. Workspaces autosave on edits, before switching, and on quit; saving a workspace does not write tags to the music files. **Save Selected Tags** (⌘S) and **Save All Changed Tags** (⌥⌘S) write audio metadata.

Use **More → Discard Selected Changes…**, track/album right-click **Discard Unsaved Changes…**, or **Edit → Discard Selected Changes…** (⌥⌘Z) to revert pending tags and artwork after confirmation. **Discard All Unsaved Changes…** applies across the current workspace. Discard restores the last loaded/saved values, persists the reverted workspace, and never writes audio or undoes tags already saved to disk. Missing/failed files keep their availability status.

Albums start collapsed each time a workspace opens. Click an album to browse its tracks and select the album for batch editing; click its disclosure chevron to expand sidebar tracks. **Find Music…** (⌘F) searches title, artist, album, genre, and filename across the entire collection. Filters show unsaved changes, missing artwork, unidentified tracks, or unavailable files. Album sorting, Expand All, and Collapse All are available in the sidebar and View menu. Command-click and Shift-click support track selection.

Search and filter changes deselect tracks that leave the results, and album selection respects the active filter. MusicBrainz lookup operates on one album at a time. Batch scripts evaluate each track's own metadata, preserving distinct titles and track numbers.

### Review MusicBrainz matches

Look Up from the toolbar opens an inline release-comparison workspace; the Metadata menu also retains a focused separate review window. Load a release from an official HTTPS MusicBrainz release URL or UUID, compare country/date/label/catalog/barcode/media/identifiers/archive artwork availability, and inspect score components. Drag a release track onto a local file (or a local file onto a release track), or use the accessible assignment menu; occupied slots swap rather than duplicate. Metadata → Regroup Selected Files stages shared album/album-artist tags without flattening individual titles.

Track matching uses compact aligned rows. Each row shows the local file, assigned MusicBrainz track and confidence; its Tags button opens a before/after pane. The missing-track count opens release order, the information button shows release details, and Releases opens other search results. These panels stay closed until needed. Long names truncate in rows and remain available in help and assignment menus.

Whole-library results support Ready/Review/Unresolved/Rejected/Stale filters, explicit rejection and Review Next. Search can be cancelled, checkpoints after each album, and offers Resume after relaunch to continue unfinished albums and recheck stale matches. Resumption validates workspace, matching country/threshold and local baselines; stale proposals are not batch-applied. Ready eligibility also requires complete, unique assignments without ambiguous tracks, conflicting identifiers, or missing release tracks. Checkpoints never silently apply metadata; approved staging and disk Save Tags remain separate actions.

**Look Up** now opens a find-and-match workspace. Refine the album/artist search without editing your local tags, choose a release, and inspect its complete track list next to your files. The matcher optimizes one-to-one assignments for the whole album using recording IDs/ISRCs, titles (with filename fallback for untagged files), real audio lengths, artist credits, and weak track/disc hints. Incorrect ordering and incomplete albums do not force positional matches. Uncertain or weak suggestions remain unassigned until explicitly chosen.

Pick a release track for each local file; choosing an occupied slot swaps the pairing. Leave bonus/duplicate/unrecognized files unmatched to keep **all** their tags unchanged. The release-order panel marks tracks with no local file. **Reset Matches**, **Unmatch All**, confidence explanations, and per-file tag-change previews support review. **Apply to N Files** stages only assigned files, including corrected per-disc track/disc totals and distinct recording/release-track IDs; **Save Tags** remains a separate disk write. Cancel closes the review without applying it. Newer local edits invalidate an older review instead of being overwritten. Disc and track identity follow MusicBrainz's [release/medium model](https://musicbrainz.org/doc/Release).

For a whole Music Library, choose **Library → Match Entire Library…** or the wand button beside the library folder. MacPicard searches and fully resolves each album, scores the album and one-to-one track assignments, and presents a result table without changing tags. The default 85% threshold keeps only high-confidence proposals in the batch-apply set; ambiguous, incomplete, low-score, and unmatched-track results go into a review queue. **Review** opens that album in the normal track matcher so files can be swapped or left unmatched. **Apply Ready Albums** stages only confident assignments across the library. The operation remains staged: use **Save Tags** afterward to write audio files, or **Discard** to revert the pending batch.

**Library → Manage Libraries & Sessions…** provides naming, switching, automatic refresh settings, and workspace removal. Removing a workspace leaves all music untouched and retains its document in Application Support. The original single-session data migrates automatically to **My Session**. Catalogs, separate session documents, and recovery files live under `Application Support/MacPicard/Workspaces`; directory access is retained with security-scoped bookmarks.

Right-click tracks or albums to **Remove from Library…** / **Remove from Session…**, keeping their files on disk. Removed library paths remain excluded from automatic refresh; explicitly re-import them or choose **Library → Restore Removed Library Items** to show them again. **Move Library Files to Trash…** is a separate confirmed action available only for files inside the current library, never linked originals outside it. Finder can recover trashed files; restore them before re-importing or restoring removed library items. Removing the current library switches to another workspace (or creates an empty session if it was the last one). Removal confirmations warn that pending edits on the removed tracks will be discarded; removing a whole workspace retains its saved edits.

The File, Edit, View, Library, and Metadata menus share their actions and enabled states with the on-screen controls. The sidebar and metadata inspector can be hidden, and the action bar adapts to narrower windows. **Help → MacPicard Guide** explains these workflows in the app.

**Settings…** (⌘,) provides editable recovery/monitoring intervals, new-library monitoring defaults, preferred release country, match threshold (85% by default), preserved tags, timestamp preservation, cover download size/replacement, default naming/tag scripts, built-in fingerprint diagnostics, optional AcoustID contribution authentication, and System/Light/Dark appearance. Save validates the draft before committing; Cancel keeps existing preferences. Preserved tags retain current values when MusicBrainz proposals are applied. Settings migrate older configuration and retain unknown keys. Optional user submission tokens are opened explicitly and stored only in Keychain. Scan Selected, Scan Album, and Scan Entire Library use built-in fingerprinting and publisher credentials without setup; results remain explicitly reviewed before tags change.

**Metadata → All Tags & Changes…** (⌥⌘T), also available in the inspector, opens the complete Tag / Original / New table. Search names and values, show only changes, or put changed tags first. Add custom tags and edit separate value rows; an empty row is an explicit empty value, while removing a tag marks it for deletion. Mixed selections are displayed without altering individual files. Tag context actions restore each file's original values, merge originals, preserve tags during matching, remove tags, and copy/paste tag sets. Copy uses the first selected file's values; pasting applies them to the selected files.

**Undo / Redo** (⌘Z / ⇧⌘Z) covers staged metadata edits, scripts, match application, and artwork changes. Multi-tag context actions are grouped as one edit. Normal text-field undo stays native. Undo never moves files or reverses tags already saved to disk: successful saves, discards, organization, and workspace switches reset staged-edit history. History is transient across relaunch; pending changes and their discard baseline are persisted. File Details shows the path, availability, file size, measured duration, container and available audio properties without modifying tags.

Menu placement and persistent folder access follow Apple's [command groups](https://developer.apple.com/documentation/swiftui/commandgroupplacement) and [security-scoped URL access](https://developer.apple.com/documentation/foundation/url/startaccessingsecurityscopedresource()) APIs.

## Collection workspace

The track table supports native keyboard navigation, multi-selection, sortable headers, and column visibility/order customization from the header context menu. Sort and column choices are saved across launches. The sidebar Filter menu shows changed, unidentified, unavailable, or artwork-missing files; artist grouping is available in its sort menu and starts collapsed. Clicking an album navigates without selecting every song for editing—use Select All or its batch context actions deliberately.

Search is debounced by 180 ms and uses cached per-file text including multi-value tags. Ordinary non-grouping edits update affected search entries instead of rebuilding the album tree. Playback and metadata editing retain independent selections. The compact toolbar contains Import, Look Up, Organize and More; Save appears when selected files have edits. Look Up is hidden while matching is open. Secondary actions and sidebar/inspector toggles are in More. There is no repeated row of optional toolbar buttons. Activity opens from the status bar and shows a bounded history of foreground outcomes and separate background warnings.

## Review file organization

**Organize** (⇧⌘O), its Metadata menu item and track/album context actions always open a read-only review. Music Libraries default to their own folder; Sessions ask for a destination (or reuse the last chosen one). Library workspaces also provide **Organize Entire Library…**, which reviews every indexed audio file regardless of the current selection. Choosing a folder does **not** start moving files. Pick an artist/album/track naming preset, artist/title layout, original filenames, or a custom Picard naming pattern. Naming is separate from metadata scripts and uses the current pending tags without saving them. The library preset pads track numbers, prefixes multi-disc tracks, sanitizes unsafe tag characters, and falls back to filenames and unknown artist/album folders.

The searchable preview shows full **From / To** paths, ready/unchanged/blocked/skipped counts, and per-file exclusion checkboxes. Filter to moves or issues, include all again, or refresh the filesystem preview. Resolve existing and duplicate destinations with **Stop on conflicts**, **Skip conflicting files**, or **Add numbered suffixes**; there is no overwrite option. Case/Unicode-equivalent destinations are conservatively treated as collisions. Files already at their target stay untouched.

**Move Files…** requires a separate confirmation. Moving outside a Music Library also requires explicit acknowledgment; those files remain linked in the workspace, but are no longer stored in its directory. Unlike library import, Organize moves files rather than copying originals. External music apps or playlists may need their file locations updated. Cancel keeps all file paths and tags unchanged.

Execution uses the exact reviewed paths, rejects changed selection/tags/options or replaced source/destination folders, rechecks source identities and all destination conflicts before any move, and atomically refuses late overwrite races. A failed move invokes two-phase rollback; recovery failures identify the retained file paths instead of hiding them. Cross-volume moves stage a complete destination-side copy before committing, then update file identities so subsequent tag saves work. Successful moves preserve pending edits and original discard baselines, update workspace paths and library exclusions, and persist the session. Session write failures before execution block the move; a post-move write failure retains the new paths and attempts recovery persistence. Quit is blocked while a move is executing. **Save Tags** remains a separate action; discarding pending tags cannot undo a file move.

## Playback and right-click actions

Right-click a song in either the track list or an expanded sidebar album to **Play**, **Play Next**, **Add to Queue**, or **Play Album**. Play starts with the exact song clicked and continues through its album in numeric track order, without changing the metadata-editing selection. Double-clicking a main-list track also plays it. Right-click album rows for album playback and batch actions.

The native player uses Apple's [AVPlayer](https://developer.apple.com/documentation/avfoundation/avplayer) and supports the same MP3, FLAC, M4A/MP4, Ogg Vorbis, Ogg Opus, and WAV formats on macOS 26. Its bottom bar provides pause/resume, previous/next, stop, seeking, volume/mute, and a queue that can play or remove individual entries. Adding to an empty queue does not autoplay. Playback errors appear in the player with a retry action; missing files do not affect pending tag edits. Switching workspaces or quitting clears playback, and saving or organizing the playing file stops it before file operations.

The **Playback** menu provides Play Selected Track (⌘Return), pause/resume (⌘P), previous/next (⌃⌘← / ⌃⌘→), stop (⌘.), and Show Queue (⇧⌘P). Playback is intentionally transient and never starts automatically after relaunch.

Track and album context menus also provide metadata editing, MusicBrainz lookup, artwork management, script editing, changed-tag saving, organization, selection, Finder reveal, copying file paths, and the removal actions described above. Batch actions use the current selection only if the clicked track belongs to it; otherwise they target that track. Permanent deletion is not offered.

## Artwork management

Choose **Metadata → Manage Artwork…** (⌥⌘A), **More → Manage Artwork…**, or Manage Artwork in the inspector/context menu. Compare original and staged images, select individual pictures, import local files or drop them from Finder, load a validated HTTPS image URL, and choose which Cover Art Archive images to download. Append or replace images, edit types/descriptions, reorder, remove, restore originals, and undo/redo within the manager.

Scope can be the selection, album, or entire workspace. Edits stay per-file unless you explicitly choose to replace the artwork set on every scoped file with the preview file’s images. **Review & Apply** stages the reviewed batch as one undoable edit; **Save Tags** separately writes it to audio. Cancel leaves the workspace unchanged. Resize/convert to JPEG or PNG, or export images after reviewing filenames and collision handling—existing files are never overwritten. M4A supports multiple ordered cover images but not picture roles/descriptions. See the [Artwork guide](docs/ARTWORK.md) for limits, preferences, and safe batch workflows.

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

The active improvement roadmap now connects fingerprint generation and AcoustID clients to the application. See [Fingerprinting](docs/FINGERPRINTING.md) for calculator setup, identification/review, offline generation, and optional consent-based submissions.

- `PicardScripts` parses and evaluates nested Picard-style expressions without stringly-typed shortcuts.
- Script execution reads and mutates the existing multi-value `Metadata` model, including unset/delete semantics.
- `PicardFingerprint` runs Chromaprint's `fpcalc` executable and maps AcoustID results to MusicBrainz recordings and releases.
- AcoustID submissions require both a user token and explicit consent before any network request is made.
- Fixture tests cover parser diagnostics, nested functions, metadata changes, regex/unicode handling, fingerprint decoding, lookup mapping, and submission guards.

## Phase 7

Phase 7 adds cover art, saving, organization, and session persistence:

- `PicardCoverArt` integrates Cover Art Archive release and release-group endpoints and validates downloaded image bytes before embedding.
- Legacy HTTP links from Cover Art Archive and Internet Archive are upgraded to HTTPS, including redirects. Other insecure artwork URLs are rejected; App Transport Security remains enabled.
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

### Zero-setup app delivery

Installed MacPicard apps include the audio fingerprint calculator and decoding support. Users do not install Chromaprint, FFmpeg, Homebrew, or other tools, and do not enter an API key to scan or identify music. Online identification still requires an internet connection. Only optional contributions to the AcoustID database require personal account authentication.

For **developer builds**, supply the registered publisher application key in ignored `Config/AcoustID.plist` (`ApplicationKey` string) or `MACPICARD_ACOUSTID_APPLICATION_KEY`. Both Xcode and standalone app packaging validate and embed it; missing configuration is a build error, never a setup burden transferred to users. The helper is checksum-pinned, universal, and signed inside-out, and each app includes its licenses and corresponding source. See [fingerprint delivery](docs/FINGERPRINTING.md).

The packaging script refuses to overwrite existing builds. Use a new `MACPICARD_OUTPUT_DIR` for each package. Ad-hoc signing supports local validation; public distribution still requires Developer ID signing and notarization.

API contracts, security rules, and live integration-test instructions are documented in [docs/API_AUDIT.md](docs/API_AUDIT.md).

### Xcode

Open `MacPicard.xcodeproj`, select the **MacPicard App** scheme and **My Mac**, then use **Run** (⌘R) or **Test** (⌘U). Xcode 26 or newer and macOS 26 or newer are required. The checked-in project works without a project generator or CocoaPods installation.

The native application target builds the existing UI sources and links the seven local Swift package library products. `Package.swift` remains the single source of truth for their dependencies and the pinned TagLibSwift revision. Xcode builds the `.app` with the existing bundle identifier, icon and English localization. **MacPicard App** is distinct from SwiftPM's automatically exposed **MacPicard** executable scheme; use the app scheme for Run, Test and Archive.

```sh
xcodebuild -project MacPicard.xcodeproj -scheme 'MacPicard App' \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath DerivedData build
xcodebuild -project MacPicard.xcodeproj -scheme 'MacPicard App' \
  -destination 'platform=macOS' -derivedDataPath DerivedData test
```

All eight test targets are included. Hosted app-model tests suppress automatic restoration of your actual music workspace; their fixtures use temporary directories. Live MusicBrainz/Cover Art requests, the recoverable Trash integration test, and the temporary disk-image cross-volume test are opt-in: enable their `MACPICARD_*` variables under **Edit Scheme → Test → Arguments → Environment Variables**. Real audio fixture tests require `ffmpeg` on the test process's `PATH`.

For command-line integration runs, pass these as environment variables prefixed with `TEST_RUNNER_` (for example, `TEST_RUNNER_MACPICARD_LIVE_API_TESTS=1 xcodebuild … test`). Xcode forwards them to the test process without the prefix. Enable all four listed variables to run the full integration suite; the default scheme leaves those five external/environment-dependent tests skipped.

Debug and Release default to local **ad hoc signing**, with no development team required. This is not Developer ID signing or notarization. For distribution, configure your own signing identity/team and use the release checklist. **Product → Archive** uses Release; the standalone packaging/notarization script below remains available.

If app/test source files or package products change, regenerate the project with `ruby Scripts/generate-xcode-project.rb` and commit the shared project changes. Regeneration requires the development-only Ruby `xcodeproj` gem, version 1.27.x (`gem install --user-install xcodeproj -v 1.27.0`); it is not needed to open, build, or run the checked-in project. The generator reads target/product definitions from `swift package dump-package` and uses stable identifiers. New core library source files are picked up directly by SwiftPM without regeneration. Xcode user settings and DerivedData stay ignored.

### Swift Package Manager

```sh
swift build -Xswiftc -strict-concurrency=complete
swift test -Xswiftc -strict-concurrency=complete
swift run MacPicard
```

The application targets macOS 26 and requires the Xcode 26 SDK or newer because the production UI uses native Liquid Glass APIs.
