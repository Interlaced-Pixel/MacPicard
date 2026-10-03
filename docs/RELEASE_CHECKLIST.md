# MacPicard release checklist

Phase 9 release validation is split between automated checks and macOS-only validation that requires the built application to run.

## Automated release gate

From the repository root:

```sh
swift build -Xswiftc -strict-concurrency=complete
swift test -Xswiftc -strict-concurrency=complete
git diff --check
Scripts/package-macpicard.sh
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
Scripts/package-macpicard.sh
```

The script refuses to submit for notarization unless a Developer ID identity is explicitly provided.

## Manual macOS gate

- Launch the packaged app on a clean macOS 26 user account.
- Import MP3, FLAC, M4A/MP4, Ogg Vorbis, Ogg Opus, and WAV files from Finder and the file picker.
- Run MusicBrainz search, select a match, edit metadata, preview/apply a script, fetch cover art, save, and organize files.
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
