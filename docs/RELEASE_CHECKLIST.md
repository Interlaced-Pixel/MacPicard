# MacPicard release checklist

## Improvement phase 8: Collection Tools and identity

- Compact UI revision: resize the matching workspace with long Unicode titles, multiple releases, missing tracks and open tag changes/release order. Verify columns remain aligned, full names are available in menus/help, and no controls overlap. Check assignment swaps, filtering, reset/unmatch, tag differences, Apply and close/cancel through mouse and keyboard. Inspect the transparent icon in Dock/Finder without a faint tile boundary. Desktop matching and VoiceOver checks remain pending after the control-service failure recorded in [IMPROVEMENT_PROGRESS.md](IMPROVEMENT_PROGRESS.md).

- Inspect the new icon at 16/32/128/1024 pixels, Dock/Finder and light/dark surfaces. Verify MusicBrainz-inspired colors without suggesting affiliation. Verify visible labels, focus, keyboard navigation, VoiceOver and accessibility display preferences.
- From menus/toolbar, open Collection Tools, switch all four tabs and scopes, then close/reopen. Create/rename/duplicate/reorder/disable/delete scripts, save/reload and import/export. Unsaved drafts must be visibly identified; invalid documents must not replace saved data.
- Preview ordered scripts on distinct per-file titles, disabled/naming scripts and unavailable files. Inspect original/new differences, skip blocked/excluded rows, apply, undo, discard and relaunch. Stop must not stage a partial batch; changed baselines invalidate application.
- Parse Unicode filenames, multiple path components, leading-zero numbers, unmatched and ambiguous filenames. Verify explicit mappings, preserved unmapped fields and unchanged audio bytes until Save Tags.
- Capture and activate a profile with only Matching checked; unrelated appearance, autosave, paths, workspaces and pending edits must survive. Verify exported JSON excludes credentials/bookmarks and unknown schema/corruption is rejected without replacement.
- Test Entire collection with a restrictive search/selection: matching/scripts/save/organization must use the chosen scope, not hidden selection. Review includes unavailable items as blocked, with lazy/searchable paths and explicit move confirmation.
- Exercise a real successful/failed/cancelled save batch. Failed and unprocessed edits stay pending; only unchanged saved/clean baselines are admitted to guided organization, and no move starts automatically. Independently organizing scope still requires its own review.
- Close the main window with Collection Tools open and confirm exit/persistence; closing tools alone must retain the main app. Run isolated fixture checks only, never a real catalog.
- Interactive phase-7/8 acceptance remains pending where SkyComputerUseService crashes during UI observation. Offscreen rendering and model tests do not replace these desktop checks. Signing/notarization and phase-10 distribution QA remain separate gates.

## Zero-setup fingerprint delivery

- Build/Archive with the publisher's registered AcoustID application key supplied in ignored `Config/AcoustID.plist` or the release environment. Never ask users to supply an application key or install a calculator.
- Check that `Contents/Helpers/fpcalc` is executable, contains arm64 and x86_64 slices, and depends only on macOS system libraries. Verify the helper and enclosing app signatures separately and with deep verification.
- Launch the packaged app with a fresh data directory and a system-only PATH. Add a generated-audio library containing MP3, FLAC, M4A/AAC, Ogg Vorbis, Ogg Opus, and WAV. Generate offline and scan online without opening credentials or configuring a tool. Confirm all six results, expected unmatched synthetic tones, and unchanged audio/tag bytes.
- Verify Settings shows built-in status/version and has no application-key or executable-path controls. Optional contribution credentials must not gate scanning, metadata matching, saving, or organization.
- Confirm source archives, licensing notices, provenance, and offline rebuild recipes are present inside the app. Rebuild the helper from included source, exercise the six formats, and preserve those resources in distribution.
- Confirm bad/missing publisher configuration fails the build rather than leaving an installable partial app. Existing output packages must never be deleted by the packager.
- For a commercial product, obtain the appropriate AcoustID service agreement. Developer ID signing, notarization, upgrade QA, and accessibility QA remain separate distribution gates.

Phase 9 release validation is split between automated checks and macOS-only validation that requires the built application to run.

## Automated release gate

From the repository root:

```sh
swift build -Xswiftc -strict-concurrency=complete
swift test -Xswiftc -strict-concurrency=complete
git diff --check
scripts/package-macpicard.sh
```

The packaging script creates and validates:

- `/Users/jayian/Downloads/MacPicard.app`
- `/Users/jayian/Downloads/MacPicard.zip`
- a native `AppIcon.icns` generated from `Sources/MacPicard/Resources/AppIcon.png`;
- an `Info.plist`, English localization bundle, build metadata, and verified code signature.

By default the local artifact is ad-hoc signed. Distribution signing and notarization are opt-in and require credentials supplied by the release environment:

```sh
MACPICARD_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
MACPICARD_NOTARY_PROFILE="macpicard-notary" \
scripts/package-macpicard.sh
```

The script refuses to submit for notarization unless a Developer ID identity is explicitly provided.

## Manual macOS gate

- Launch the packaged app on a clean macOS 26 user account.
- Import MP3, FLAC, M4A/MP4, Ogg Vorbis, Ogg Opus, and WAV files from Finder and the file picker.
- Create a Music Library and open an existing music folder; verify both use the same library actions. Import external files into each; verify organized copies under its folder, untouched originals, identical-file reuse, and suffixed naming collisions. Upgrade a legacy session catalog; verify preserved names, IDs, pending edits, artwork, bookmarks, history and original file paths, with new imports using its managed folder.
- Remove tracks and albums without deleting files; verify they stay hidden after refresh/relaunch, then restore them from the Library menu or by explicit re-import. Test Trash only with disposable fixtures, confirming Finder recovery and protection of linked originals outside the library.
- Remove the current and last library in Manage Music Libraries; verify safe library switching and retained audio and saved edits. The last removal shows the create/open screen and must stay empty after relaunch. Cancel both item-removal and Trash confirmations and verify nothing changes.
- Run MusicBrainz search, select a match, edit metadata, preview/apply a script, fetch cover art, save, and organize files.
- Complete Manage Artwork from More, Metadata menu and context menus using disposable audio. Compare originals, import/drop files, load an HTTPS image, choose archive downloads, append/replace, reorder, remove/restore and undo/redo. Cancel without applying; apply a reviewed selection/album/workspace batch, save/relaunch, and check the actual embedded image order, roles and M4A limitations. Verify export-only mode, explicit JPEG/PNG conversion and reviewed export collisions; no existing image may be overwritten. Phase 7 automated checks do not replace this on-screen acceptance gate.
- Review an incomplete/out-of-order album: verify confident suggestions, ambiguous suggestions left unassigned, occupied-slot swaps, missing release tracks, unmatched extras, and before/after tag previews. Cancel without applying, refine the search without changing local tags, and verify disc totals and distinct MusicBrainz IDs after applying.
- Discard selected/all pending tag and artwork edits through More, Edit menu and context menus. Verify cancellation leaves edits intact, confirmation persists the revert, and audio bytes stay untouched. Tags already saved to disk must remain saved.
- Open Organize from the toolbar, Metadata menu and track/album context menus. Choose folders and presets without moving files; inspect full before/after paths, search/filter/exclude items, and resolve duplicate/existing destinations with stop, skip and numbered suffixes. Confirm that libraries default to their root, external moves require acknowledgment, and cancelling the review or move confirmation leaves every source untouched.
- Organize only disposable fixtures; verify preserved audio bytes and pending tag/artwork baselines, persisted new paths, later Save Tags, numeric/disc naming, unchanged-file handling, late collision/source-change rejection, and rollback. Refresh a library after moving to a previously excluded path; the moved item must remain visible. Verify Quit is blocked during an active move.
- Right-click both main-list tracks and sidebar tracks; verify exact-song playback, album playback, queue ordering, and multi-selection action targets.
- Verify pause/resume, seek, volume/mute, previous/next, queue controls, playback errors, double-click playback, and Playback menu shortcuts. The automated gate decodes silent fixtures for all six audio formats through the native player.
- Quit during an unsaved edit, relaunch, and verify recovery selection, discard, and accept paths.
- Enable VoiceOver and complete import, selection, lookup, edit, artwork, script, save, and organize workflows.
- Repeat the primary workflow with Reduce Motion, Increase Contrast, and Larger Text enabled.
- Verify keyboard-only navigation, focus movement, command equivalents, and no color-only state communication.

## Upgrade gate

- Install the previous release with an existing configuration, profile, cache, bookmark, session, and recovery file.
- Replace the application bundle with the new release without removing `~/Library/Application Support/MacPicard`.
- Confirm configuration migration, cached data, security-scoped bookmark resolution, profile import, and recovery selection.
- Confirm an interrupted save or move does not leave a partial destination or corrupt the session document.

## Library filesystem integration tests

The tests generate isolated audio fixtures with FFmpeg; they never use the user's music. Native Trash testing is opt-in because it temporarily moves one generated copy into the real recoverable Trash and immediately restores it during cleanup:

```sh
MACPICARD_TRASH_INTEGRATION_TEST=1 swift test --filter 'LibraryImportTests|LibraryManagementTests'
```

The library tests exercise all six supported formats, copy-only imports, source-independent persistence, duplicate reuse and naming collisions, concurrent import commits, read-only sources, missing/dotted/long Unicode tags, symlink destinations, corrupt input, cancellation, excluded paths, legacy catalog decoding, retained workspace documents, and external-modification/confirmation guards for Trash.

`swift test --filter 'MatchReviewTests|EditReviewTests'` checks global track assignment, partial/reordered/multi-disc albums, manual swaps, weak/ambiguous suggestions, duration mismatches, duplicate-ID guards, unchanged unmatched files, stale-review protection, discard consent/persistence, already-saved tags, artwork/deletion rollback, and backward-compatible duration persistence.

`swift test --filter 'OrganizationReviewTests|OrganizationModelTests'` verifies read-only preview, normalized/fallback naming, conflict policies, exclusions, no-overwrite races, source changes, symlink escapes, replaced destination folders, rename-cycle rollback, stale review/selection/options, consent, session-write failure, library exclusions, retained unsaved edits, and real FLAC move/refresh/save.

For actual cross-volume coverage, use `MACPICARD_CROSS_VOLUME_TEST=1 swift test --filter OrganizationReviewTests`. This creates a temporary APFS disk image, mounts it without opening Finder, moves a generated FLAC onto it, verifies refreshed identity and a subsequent tag save, then detaches and deletes only that test image. No user audio is used. An unsuccessful detach retains the image and reports its path.
