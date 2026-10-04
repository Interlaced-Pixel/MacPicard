# MacPicard end-to-end improvement plan

Date: 2026-10-03  
Status: Planned; implementation has not started  
Baseline: Current native Swift 6 app, including library-wide matching and organization

## 1. Outcome and scope

Deliver a polished, production-ready macOS music metadata application with Picard's essential editing and identification tools, persistent music libraries, and responsive collection-wide workflows. Users must be able to import, identify, compare, edit, review, save, organize, and maintain their collection through working controls.

Every delivered feature must have its complete model, persistence, UI, error handling, cancellation where applicable, and verification. No stubs, inert buttons, simulated results, or backend-only features presented as completed UI capabilities. Compiling is necessary but does not establish usability or release readiness.

Retain Swift 6 strict concurrency, macOS 26 minimum deployment, native SwiftUI/AppKit controls, and Liquid Glass in navigation and controls. Preserve existing libraries, sessions, bookmarks, pending edits, recovery documents, and audio metadata through upgrades.

Supported formats remain MP3, FLAC, M4A/MP4, Ogg Vorbis, Ogg Opus, and WAV. There is no format expansion in this roadmap. Metadata capabilities vary by container; the UI must report unsupported tag or artwork operations accurately.

Core release scope:

- Scalable libraries/sessions, collection navigation, and passive monitoring.
- Complete metadata comparison and editing, including custom and multi-value tags.
- MusicBrainz release/track matching and AcoustID identification.
- Artwork management, scripts, filename parsing, functional preferences, and profiles.
- Selected-file, album, and entire-library matching, saving, and organization.
- Playback, operation history, keyboard access, accessibility, and release validation.

Deferred scope: optical-disc lookup/Disc ID submission, Python plugin compatibility or a plugin marketplace, extra audio formats, audio conversion/ripping, cloud sync, and Music/iTunes database synchronization. These require separate designs and acceptance criteria. This roadmap targets essential Picard workflow coverage, not complete parity with every Picard extension.

## 2. Current baseline and gaps

| Area | Existing behavior | Required improvement |
| --- | --- | --- |
| Collection | Persistent libraries/sessions, managed imports, collapsed albums, search/filter | Scalable navigation, useful columns, accurate monitoring labels, explicit action scope |
| Metadata | Nine common fields, batch edits, whole-file discard | All tags, original/new comparison, custom tags, multi-value editing, per-tag restore, undo/redo |
| Matching | Album review, one-to-one assignment, whole-library proposals at 85% | Better release details, mixed/unidentified file workflows, integrated review navigation |
| Identification | Fingerprint and AcoustID modules | Working Scan/generate/submit UI with configuration and consent |
| Artwork | Front-cover preview and download | Original/new comparison, local/URL import, multiple images, replace/remove/reorder |
| Preferences | Mostly informational Settings | Editable, validated, persistent settings and actionable profiles |
| Organization | Reviewed selected-file and entire-library moves | Clear scope picker, integrated naming preferences, efficient large previews |
| Scripts | Single-source preview/apply | Named scripts, ordering, enable/disable, diagnostics, managed naming scripts |
| Playback | Native player and queue | Consistent integration and clear file details without disrupting editing |
| Operations | Status/progress/error messages | Separate foreground/background state, cancellation, structured results, history/retry |

Known inconsistencies to address first: refresh text still says every minute although polling is five minutes; the whole-library organize toolbar action is labeled merely "Library"; README phase history can imply UI capabilities that are only implemented in backend modules.

## 3. Product rules and interaction design

### Workspace and navigation

- Keep a library/session chooser and a compact sidebar. Albums open collapsed; expanding one album must not expand the collection.
- Provide All Tracks, Albums, Unidentified, Needs Review, Unsaved Changes, Missing Artwork, and Unavailable navigation destinations with live counts.
- Add artist grouping and configurable album/track sorting. Search the full collection by default, with a visible scope when searching a subset.
- Use a virtualized, sortable track table with configurable title, artist, album, disc/track, duration, format, match confidence, and state columns. Persist column and sidebar preferences.
- Keep quick editing accessible. Offer a resizable matching workspace alongside local files; narrow layouts may use a dedicated matching presentation without losing review state.
- Preserve browsing position, selection, collapsed/expanded state, and review position during incremental updates. Never silently select every file to invoke a library command.

### Action scope

- Import, Match, Scan, Script, Save, Discard, and Organize must communicate their target: selected tracks, album, or entire library.
- Organize exposes "Selected Files…" and "Entire Library…" through one clearly labeled action/menu. Entire-library scope ignores search filters and the visible album; preview states the file count and library name.
- Context actions target the clicked item or its existing multi-selection according to the current established behavior. Menu, toolbar, context menu, and keyboard availability share the same command definitions.
- Clearly distinguish staging edits, saving tags, moving files, removing indexed items, and moving files to Trash. Keep the existing reviewed move and Trash confirmations.

### Visual and accessibility standard

- Use Liquid Glass for navigation and interactive controls; use readable content surfaces for tables, metadata, and long text. Review implementation against current Apple guidance rather than scattering glass modifiers across all content.
- Support light/dark appearance, Reduce Transparency, Reduce Motion, increased contrast, keyboard-only use, and VoiceOver.
- Eliminate clipped labels, fixed-height overflow, disappearing actions, stacked status banners, and unnecessarily large empty headers. Use native sizing, consistent spacing, and an overflow menu when space is limited.
- Show severity with text/icons as well as color. Display concise errors with expandable details and an appropriate retry or recovery action.
- Closing the main window must continue to quit the app safely, honoring active file-operation protection and persistence.

## 4. Architecture and data contracts

Extend the current modules rather than replace their working format engines or API clients. Split orchestration into focused services and small view models as features grow; keep AppModel as a coordinator instead of adding every operation to it.

- **Commands:** Central action definitions include label, scope, availability, shortcut, and execution target. Bind toolbar/menu/context actions to these definitions.
- **Operation coordinator:** Stable job IDs, workspace IDs, cancellation, priorities, per-item results, and completion summaries. Serialize conflicting file mutations; allow bounded independent reads.
- **Review snapshots:** Capture workspace ID, file IDs, baseline revisions, source identities, settings revision, and proposed changes. Revalidate before applying or executing. Any relevant change invalidates the affected proposal instead of overwriting newer edits.
- **Metadata editor:** Separate loaded/saved baseline from staged values and deletions. Preserve multi-value structure and unsupported/unknown fields. Technical properties such as measured duration are read-only.
- **Undo manager:** Group in-memory metadata/artwork/script edits by user action. Keep undo local to the correct workspace. Define baseline resets after save; never imply that undo reverses a completed disk move or already-written tag save.
- **Preferences:** Typed, versioned configuration with defaults, validation, migration, atomic persistence, and a clear global/per-library boundary. Tokens belong in Keychain, never profile exports or logs.
- **Monitoring:** Scan off the main actor, publish incremental deltas, merge against current file revisions, and guard workspace identity. A scan must not overwrite edits made while it was running.
- **Persistence:** Save user-visible workspace/review/settings state where useful; transient playback stays transient. Recovery distinguishes completed disk changes from pending changes.

## 5. Delivery phases

Implementation and verification evidence for improvements 1–6 is recorded in [IMPROVEMENT_PROGRESS.md](IMPROVEMENT_PROGRESS.md). Phases 4–6 deliver collection navigation, reviewed/resumable matching, and fingerprint workflows. Phase-3 import and multi-value add/undo/redo checks were subsequently verified in an isolated native app; its broader acceptance checklist remains documented. Phases 7–10 remain future work, including comprehensive accessibility and production delivery validation. These statuses refer to this improvement roadmap, not the original bootstrap phases in README.

Each phase ends with working UI, relevant automated verification, manual checks of its actual flows, updated documentation, and a separate commit. Record completed evidence against this plan. Do not declare a phase complete while its required behavior is missing or its runtime checks remain unverified.

### Phase 1 — Establish truthful UI state and command scope

Work:

- Correct monitoring labels/help/README to the actual passive behavior and five-minute fallback interval.
- Consolidate organization scope under a recognizable Organize control; retain both selected and entire-library actions.
- Introduce shared command scope/availability definitions and migrate existing actions incrementally.
- Replace ambiguous status text with separate state for foreground operations, background monitoring, and pending changes.
- Inventory all visible controls against actual handlers; remove completion claims for features not reachable through the UI.

Acceptance: menu/toolbar/context actions show consistent targets and enabled states; entire-library organization works with one album selected and an active filter; no-op monitoring leaves the UI and selection unchanged. Documentation matches runtime behavior.

### Phase 2 — Functional preferences and configuration

Work:

- Build real Settings sections for General, Libraries, Matching, Metadata/Saving, Artwork, Naming, Fingerprinting, Scripts, and Appearance/Accessibility.
- Persist matching defaults, including **85%** automatic eligibility. Ambiguous, incomplete, conflicting, or unmatched results require review regardless of score.
- Add editable release preferences and supported preservation/write options. Expose only settings that the corresponding backend actually honors.
- Configure monitoring enablement, naming defaults, and cover-art behavior. Show built-in fingerprint diagnostics, not calculator setup. Keep only optional user contribution authentication in Keychain; the AcoustID application key is publisher-supplied during the build, never a user preference.
- Validate values before commit, show pending/error state, support restore defaults, and preserve unknown configuration fields during migrations where required.

Acceptance: changing a preference affects the relevant next operation and survives relaunch; invalid configuration cannot break saved settings; optional user credentials remain in Keychain; defaults migrate without losing existing workspaces; scanning requires no software installation, account creation, application-key entry, or executable-path configuration.

### Phase 3 — Complete metadata editor and undo

Work:

- Add a searchable Tag / Original / New table with changed-only and changed-first views. Keep common-field quick editing as an optional companion.
- Add custom tags, remove tags, edit multi-value lists, copy/paste tag sets, restore one tag, merge original values, and preserve selected tags during remote metadata application.
- Represent absent, empty, deleted, shared, and mixed values distinctly across multi-selection.
- Add undo/redo for staged edits, scripts, match application, and artwork updates through grouped transactions.
- Provide read-only file details: location, size, format, measured duration, available codec properties, identifiers, and availability/errors.

Acceptance: custom and multi-value tags round-trip in each supported format where supported; unrelated tags survive edits; mixed values never flatten on selection alone; per-tag restore and undo preserve the correct baseline; Save/Discard remain accurate after relaunch.

### Phase 4 — Scalable collection workspace

Work:

- Introduce the track table, saved columns/sorts, sidebar destinations, artist grouping, and keyboard navigation.
- Debounce searches, use indexed grouping/filtering, and update changed rows without rebuilding the entire browser on every small edit.
- Add configurable toolbar composition and an overflow menu; preserve essential actions at narrow widths.
- Separate navigation focus, editing selection, playback selection, and operation scope.
- Add a compact task indicator and openable activity view; keep background status out of the primary editing surface.

Acceptance: keyboard navigation, sorting, filtering, multi-selection, inspector resizing, and playback remain consistent at small and large window sizes. Large collections retain stable scroll/selection during updates. All controls remain accessible with display accessibility settings enabled.

### Phase 5 — Stronger matching and review workspace

Work:

- Make release comparison accessible within the main workspace, retaining a focused separate view where useful.
- Show release country, date, label/catalog, barcode, media, track totals, identifiers, artwork availability, and scoring explanations when available.
- Support unmatched/unidentified collections, explicit regrouping, and review across albums. Add assignment drag-and-drop alongside accessible menus.
- Add open-in-MusicBrainz and load-release-by-URL/ID actions. Validate identifiers and use existing secure API clients.
- Enhance entire-library results with confidence filters, review-next navigation, rejected proposals, and resumable/checkpointed read jobs. Persist enough state to revalidate resumed proposals.
- Stage only explicitly approved or eligible high-confidence assignments. Show files left unchanged and release tracks without files.

Acceptance: reordered/incomplete/multi-disc albums, extras, duplicate tracks, weak tags, and release variants can be reviewed correctly; assignments stay one-to-one; stale proposals are rejected; cancellation/relaunch does not silently apply changes; the 85% default is used consistently.

### Phase 6 — Audio fingerprint identification

Work:

- Connect the existing Chromaprint and AcoustID modules to Scan Selected, Scan Album, and Scan Entire Library actions.
- Bundle the calculator and all runtime decoding dependencies inside the app, with licenses and corresponding source. Fingerprinting and identification must work on first launch without end-user software installation, executable-path setup, or application-key entry; publisher service configuration is a developer build responsibility. Validate both native Xcode and standalone packaged delivery.
- Compute fingerprints away from the main actor with bounded concurrency; cache by audio identity and fingerprint version.
- Resolve fingerprint recording/release candidates through MusicBrainz and feed the normal review workspace. Keep fingerprint confidence and release/track confidence separately labeled.
- Add Generate Fingerprints and optional Submit AcoustIDs commands. Submission requires verified mappings, configured credentials, and explicit consent for the submitted batch; uncertain submissions are not automatically repeated.

Acceptance: untagged and incorrectly tagged fixtures become reviewable candidates; scan cancellation stops subprocess/network work; corrupt files and missing tools yield recoverable per-file errors; no fingerprints/tokens leak into logs; submissions have fixture coverage without unsolicited live writes.

### Phase 7 — Full artwork management

Work:

- Build original/staged artwork comparison with a selectable image list, front/back/other types, dimensions, size, and source.
- Add local file import, drag-and-drop, validated HTTPS URL import, download selection, replace/append, remove, reorder, and per-image restore.
- Integrate artwork edits with undo, batch scope, staged persistence, and metadata-save transactions.
- Add configurable resize/format/embedding behavior and explicit external image export with reviewed destinations and collision handling.
- Honor container limitations and validate images before staging or writing them.

Acceptance: multiple embedded images and types survive round trips where supported; malformed/oversized images are handled; preview dimensions are correct; cancelling leaves baseline artwork intact; external export never overwrites files unexpectedly.

### Phase 8 — Managed scripts, naming, and collection-wide operations

Work:

- Add named tagging/naming scripts with create/rename/duplicate/delete, ordering, enablement, import/export, syntax locations, and per-file preview.
- Add filename-to-tag parsing with sample preview, explicit field mapping, ambiguity reporting, and staged application.
- Add configuration profiles with a documented option scope. Profile activation changes only included preferences; profiles exclude secrets and remain distinct from libraries/sessions.
- Unify selected/album/library save, script, match, and organize entry points. Present counts, changed fields, blocked items, and skipped items before batch commit where appropriate.
- Keep organization previews responsive with lazy rows, search, scope labels, and shared naming settings. Maintain identity checks, conflict policies, no-overwrite behavior, rollback, and explicit move confirmation.
- Offer a guided library workflow: identify/review → stage metadata/artwork/scripts → save changed files → review organization → move confirmed files. Each step reports actual results and can stop before the next mutation.

Acceptance: scripts operate on each track's own metadata; filename parsing stages correct values without writes; profile switching preserves unrelated preferences; whole-library organization includes all indexed files regardless of selection/filter; partial save failures leave failed edits pending and never auto-organize failed files.

### Phase 9 — Passive monitoring, scheduling, and recovery

Work:

- Use directory-change notifications as hints with debouncing/coalescing and an incremental background scan. Handle recursive changes, notification overflow, reconnects, and renames; keep five-minute polling as a correctness fallback.
- Prioritize user operations. Suspend/defer conflicting scans during edits, playback/file writes, matching commits, workspace switches, and organization; allow deliberate manual refresh with visible progress/cancel.
- Suppress no-op publications, unnecessary metadata reads, repeated warnings, and identical autosaves. Merge actual deltas against current revisions rather than replace a stale full snapshot.
- Add operation history with per-file outcomes, retry eligible failures, resume safe read jobs, and recovery guidance for interrupted writes/moves.
- Persist successful filesystem changes before reporting completion. Revalidate security-scoped access and offer reconnect when needed.

Acceptance: bursts of folder changes result in coalesced work; in-flight scans preserve newer edits; missing drives, replaced files, library switches, concurrent imports, and interrupted organization do not corrupt state; manual refresh remains effective; repeated no-op scans cause no browser rebuilds or session writes.

### Phase 10 — Production validation and delivery

Work:

- Complete the behavior matrix below using disposable fixtures for file mutations.
- Audit all menus, shortcuts, context actions, toolbar customization, focus, VoiceOver, light/dark appearance, accessibility settings, and minimum supported window sizes.
- Verify SwiftPM and the native Xcode scheme from clean builds; keep project generation/source membership correct as files are introduced.
- Update Help, README, accessibility/API audits, and release checklist to describe delivered behavior accurately.
- Package and verify a Release build, icon/resources, dependencies, and code signature. Produce the final `.app` and archive in Downloads, clearly reporting local ad-hoc signing versus Developer ID/notarized distribution.
- Use existing distribution credentials only when available; absence of credentials does not justify claiming notarization or a public-release gate has passed.

Acceptance: all core flows work in the packaged application, required automated and runtime checks pass, migration succeeds, and remaining external distribution prerequisites are explicitly identified. No dead controls or required placeholders remain.

## 6. Verification matrix and performance budgets

| Dimension | Required cases |
| --- | --- |
| Audio formats | Read/edit/save/reload, custom and multi-value tags, deletions, artwork, and identity tracking across all six supported formats |
| Matching | Complete, partial, reordered, multi-disc, repeated titles, compilations, no tags, wrong IDs, ambiguous releases, confidence below/at/above 85% |
| Collection scale | 100, 1,000, and 10,000 generated/indexed tracks; 50,000-track stress pass to identify practical limits |
| Filesystem | Missing drive, permission denial, security-scoped reconnect, source change, collision, symlink boundary, Unicode/case collision, cross-volume move, interruption/rollback |
| API | Invalid request, authentication error, 429/Retry-After, timeout, temporary upstream failure, HTTPS redirects, cancellation, bounded retries, cache invalidation |
| Persistence | Old configuration/library migration, restart with staged edits/reviews, primary/recovery disagreement, interruption during atomic writes |
| UI | Keyboard/VoiceOver, narrow/large window, long labels/paths, mixed multi-selection, dark/light, Reduce Motion/Transparency, increased contrast |

Measure on a documented Apple Silicon machine running supported macOS; record hardware, fixture count, cold/warm state, and timing distributions. Initial targets, subject to evidence-based adjustment:

- During monitoring and batch reads, no repeated main-thread stalls exceeding 100 ms attributable to those jobs; measure with Instruments rather than infer from actor declarations.
- Search/filter results within 300 ms at 10,000 tracks after a 150–250 ms typing debounce, measured separately from network operations.
- Selection, playback controls, and cancellation receive visible acknowledgment within 100 ms during large jobs.
- No-op monitoring produces zero collection publications and zero workspace writes; small disk changes update only affected entries where possible.
- Memory growth must be bounded by indexed data and bounded caches/queues, without eager full-resolution artwork decoding or unbounded parallel tasks. Record peak memory and repeated-job stability.

Run meaningful tests around state transitions, format/API contracts, migrations, stale reviews, concurrency, and filesystem transactions. Simple label/layout changes need build and runtime inspection, not tests that merely restate strings. Live read-only API checks supplement deterministic tests; live submission is a distinct consented action. A build alone does not pass the runtime gate.

## 7. Dependencies and release tracking

Recommended order is Phases 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → 10. Shared operation/revision infrastructure begins in Phase 1 and grows with subsequent work. Preferences support fingerprint/artwork/script behavior; metadata transactions and undo support reliable match application; final monitoring builds on conflict scheduling and collection indexing.

Phase completion record must include commit, implemented user workflows, tests/build results, runtime evidence, documentation changes, and unresolved limitations. Phases are complete only after their acceptance checks pass. This document is the single active improvement roadmap; the historical bootstrap plan is removed. Existing API, accessibility, and release-audit documents remain supporting references.

## 8. Reference material

- [Picard repository](https://github.com/metabrainz/picard)
- [Picard main screen](https://picard-docs.musicbrainz.org/en/latest/getting_started/screen_main.html)
- [Picard metadata pane](https://picard-docs.musicbrainz.org/en/latest/getting_started/metadata_pane.html)
- [Picard artwork workflow](https://picard-docs.musicbrainz.org/en/latest/usage/coverart.html)
- [Picard toolbar customization](https://picard-docs.musicbrainz.org/en/latest/config/options_interface_toolbar.html)
- [Apple materials guidance](https://developer.apple.com/design/human-interface-guidelines/materials)
- [Apple toolbars guidance](https://developer.apple.com/design/human-interface-guidelines/toolbars)
- [Apple Liquid Glass overview](https://developer.apple.com/documentation/technologyoverviews/liquid-glass)
- [MusicBrainz API](https://musicbrainz.org/doc/MusicBrainz_API)
- [AcoustID web service](https://acoustid.org/webservice)
- Supporting repository documents: `docs/API_AUDIT.md`, `docs/ACCESSIBILITY_AUDIT.md`, `docs/RELEASE_CHECKLIST.md`, and `docs/LOCALIZATION.md`.

Picard documentation establishes reference features; this roadmap's layout, sequencing, additional library behavior, and performance budgets are MacPicard design decisions. Recheck upstream documentation and Apple API availability when implementing each phase.
