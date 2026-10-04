# Artwork management

The improvement-roadmap phase 7 adds a full staged artwork manager. No additional tools, image editor, or user API key is required.

## Open and choose the scope

Select editable tracks, then use **Metadata → Manage Artwork…** (⌥⌘A), More in the toolbar, Manage Artwork in the inspector, or the track/album context menu. Choose Selection, Album, or Entire Library before editing. Entire Library includes available, editable files; unavailable files are excluded. The scope freezes once the draft changes so switching it cannot silently discard work.

Preview file chooses which file's image set you edit. By default, changes affect that file only; edit other files with the picker. To intentionally copy one artwork set to every scoped file, enable **Replace artwork on all … files with the preview file’s set**. This replaces, rather than merges, their complete image sets, including removal if the proposed set is empty. Review the per-file image counts before applying.

## Compare and edit

The left list shows staged images in embedded order. Select an image to compare it with the last loaded/saved original; the original picker can compare any original image. The manager reports measured dimensions, byte size, type, description and source. Older artwork without stored dimensions is measured asynchronously. Original means the disk baseline, not merely the draft when the sheet opened.

Move Up/Down, Remove, Restore Image and Restore All Original Images are available in the list controls/context menu. Restore Image can recover removed originals. A selected-image replacement retains its identity so original comparison and restore remain meaningful. Sheet-local Undo/Redo changes only this draft. Cancel discards all draft changes without touching the workspace or audio files.

## Import and download

- Import image files or drop Finder image files onto the list.
- Choose Append, Replace selected, or Replace all before importing. A failed multi-image import does not partially change the draft.
- Enter an **HTTPS** image URL to import online. Credential-bearing URLs and insecure initial URLs are rejected. Downloads are bounded and validated; invalid responses are not embedded.
- Enter a MusicBrainz release or release-group ID, find archive images, select individual entries, choose a download size and download the selected images. Manual management never silently picks the first front cover.

Network and image-processing work is cancellable. A failed import/download leaves existing images intact. URLs are read requests to the selected server; local audio and metadata are not uploaded. Sources may be persisted with staged artwork, so avoid private or token-bearing image URLs.

## Convert and embed

Settings → Artwork supplies defaults for maximum pixels, output format, JPEG quality, and embedding. The manager exposes these values for the current draft. **Convert selected / all** explicitly performs conversion and downsampling; importing alone does not silently recompress images. Keep format preserves the encoded format while resizing. JPEG conversion renders transparency on white and honors image orientation; dimensions are never enlarged. JPEG quality also applies when keeping an existing JPEG.

Turn **Embed on Save Tags** off for an export-only draft. Review & Apply is then disabled, and automatic artwork downloads during matching are disabled when this preference is off. Exporting never applies artwork to audio.

For embedding, only correctly identified JPEG/PNG is accepted. Other supported single-frame ImageIO formats can be imported for inspection and explicitly converted. Animated/multi-frame, incomplete, or malformed images are rejected. Limits are **32 MiB per image, 40 megapixels, 16,384 pixels per side, 64 images and 128 MiB total per file/export set**. Limits are checked before unbounded decoding, staging and native writes. Invalid images can be removed/replaced without changing unrelated metadata.

| Audio container | Embedded artwork |
| --- | --- |
| MP3, FLAC, Ogg Vorbis, Ogg Opus, WAV | Ordered multiple images, picture roles and descriptions |
| M4A/MP4 | Ordered multiple cover images; no independent picture roles or descriptions |

M4A rejects back/other roles until the user explicitly changes them to Front or exports them separately. Its saved staged baseline strips unsupported descriptions. Booklet maps to Leaflet and Obi to Other in typed containers. This is disclosed rather than reported as preserved unsupported data.

## Review, apply, save and recover

**Review & Apply** lists each frozen target and the old/new image counts and types. Apply validates the complete batch off the main actor, rejects changed workspaces/files or incompatible formats, and commits it as **one staged undo transaction**. Stale or invalid targets cannot cause a partial batch apply. Stop/Back cancels pending validation.

Applying does not write audio. Pending artwork and the original discard baseline persist with the workspace. Use **Save Selected Tags / Save All Changed Tags** to write through the existing same-format temporary-file transaction. Native writers close their file handles before a fresh read verifies embedded bytes, order, type and supported descriptions; only a verified temporary result replaces the original. A save failure retains staged edits and reports an error. **Discard** restores the last loaded/saved artwork without touching disk. Undo cannot reverse a completed disk save.

## Reviewed export

Export selected/all images, choose an existing destination folder, and review exact filenames before confirming. **Stop on collision** refuses conflicts; **Unique filenames** proposes numbered names. Export does not modify audio or apply the draft.

Execution rechecks the destination directory identity and filenames, creates files exclusively without following symlinks, and never truncates or overwrites existing files. Late conflicts abort; failure/cancellation rolls back only files created by this export whose identities still match. Replaced destination folders are rejected. Quit is blocked during export. Export is a reviewed set of individual file creations, not a power-failure-atomic multi-file filesystem transaction.

## Validation and remaining release gate

Automated tests cover malformed/oversized/animated images, orientation/transparency, exact measured sizes, bounded HTTPS requests, import replacement identity, per-image restore, cancellation, frozen/stale batches, undo, session persistence, six-container native round trips (including reorder and remove-all), collision races, symlinks, and destination replacement. The native SwiftUI view is rendered in a test and inspected, but that is **not** a desktop-interaction test.

Final keyboard/mouse/VoiceOver workflows and clean-account signed/notarized distribution remain explicit release gates in [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md). Consult [IMPROVEMENT_PROGRESS.md](IMPROVEMENT_PROGRESS.md) for current evidence rather than treating successful compilation as production certification.
