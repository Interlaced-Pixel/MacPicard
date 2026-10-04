# MacPicard release checklist

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
- Import external files into a Music Library; verify organized copies under its folder, untouched originals, identical-file reuse, and suffixed naming collisions. Repeat in a Session and verify it references originals without copying.
- Remove tracks and albums without deleting files; verify they stay hidden after refresh/relaunch, then restore them from the Library menu or by explicit re-import. Test Trash only with disposable fixtures, confirming Finder recovery and protection of linked originals outside the library.
- Remove the current and last library in Manage Libraries & Sessions; verify safe workspace switching and retained audio and saved edits. Cancel both item-removal and Trash confirmations and verify nothing changes.
- Run MusicBrainz search, select a match, edit metadata, preview/apply a script, fetch cover art, save, and organize files.
- Review an incomplete/out-of-order album: verify confident suggestions, ambiguous suggestions left unassigned, occupied-slot swaps, missing release tracks, unmatched extras, and before/after tag previews. Cancel without applying, refine the search without changing local tags, and verify disc totals and distinct MusicBrainz IDs after applying.
- Discard selected/all pending tag and artwork edits through the toolbar, Edit menu and context menus. Verify cancellation leaves edits intact, confirmation persists the revert, and audio bytes stay untouched. Tags already saved to disk must remain saved.
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
