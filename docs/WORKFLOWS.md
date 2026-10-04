# Collection Tools

Open **Library → Collection Tools…** (⇧⌘K), or the toolbar's More menu. Scripts, filename parsing, profiles and the workflow share this window. Closing the main MacPicard window still quits the app.

## Scope and safety

Choose Selection, Album or Entire collection. Entire collection includes all indexed files in the active library/session, regardless of search, filter or selection. Unavailable files appear as blocked review rows. A review freezes file/workspace baselines; changing the underlying files invalidates application. Reviews show changes, unchanged files and failures. Exclusion and explicit confirmation precede staging. Staged edits support the existing global undo/discard flow; **Save Tags is a separate disk write**.

## Scripts

Create named tagging or naming scripts, rename/duplicate/delete them, order execution and enable individual scripts. Save Scripts persists the draft; Revert Draft restores its saved version. Tagging previews run enabled tagging scripts in order against each file's own metadata. Metadata/variables pass between scripts for that file, never between files. Syntax/evaluation failures include source locations. Disabled/naming scripts do not change tags in a tagging preview.

Naming scripts preview output paths through the existing organization engine; Use for Organize updates the shared naming preference, not files. Organize still requires a destination, conflict review and explicit move confirmation. Search and lazy rows keep reviews bounded visually. Stop cancels preview work; cancellation cannot apply a partial tag batch.

JSON import merges scripts/profiles with fresh IDs; it does not replace existing items. Export contains the current draft. Imports are bounded to 2 MiB, validated for schema, IDs, source size and syntax. Scripts are bounded to 64 KiB and 64 nesting levels. Persistence uses validated atomic writes. A damaged saved workflow document is not overwritten: Reveal Data and Retry Load support restoring a valid backup externally. Workflow data lives at the app's application-support `Workflows/library.json`.

## Filename → Tags

Patterns use explicit captures, for example `{artist}/{album}/{track} - {title}` or `{track} - {title}`. Only the corresponding trailing path components are examined, without the final extension. Map captures to writable tags and enable only wanted mappings. Existing unmapped tags are preserved. Track/disc numbers must be integers from 1–9999; leading zeroes are normalized.

Repeated separators can make a filename ambiguous: `Artist - Song - Remix` does not guess which ` - ` separates artist/title. Such rows are blocked, as are unmatched patterns, adjacent/repeated captures, traversal and invalid mappings. Preview shows proposed per-file values; Apply stages only reviewed, included, valid rows. No parsing action renames or writes audio.

## Configuration profiles

Profiles are preference presets, **not libraries or sessions**. Capture current preferences, name/duplicate/delete the preset, choose included groups, save the library and explicitly activate the profile. Activation changes only checked groups:

| Group | Included preferences |
| --- | --- |
| Matching | Preferred country, confidence threshold, preserved tags |
| Naming | Default naming script |
| Tagging | Default tagging script |
| Artwork | Automatic download, size, replacement, pixel limit, output format/quality, embedding |
| Timestamps | Preserve file modification date |

Unrelated appearance, monitoring, autosave, paths, bookmarks, workspace identities, API authentication, publisher keys and calculator configuration are excluded. Export includes user-authored script text; do not put private credentials in scripts intended for sharing.

## Guided collection workflow

1. Identify and review: use album/selected matching or library-wide matching; audio scanning remains explicit.
2. Stage and inspect: metadata, artwork, tagging scripts or filename parsing. No automatic save or move follows.
3. Review changed files, then explicitly Write Tags. Outcomes report actual success/failure per file; Stop takes effect after the current safe file transaction. Unprocessed and failed files remain pending.
4. Organize Saved Files, then confirm organization in the existing move review. Failed, cancelled, unavailable, still-pending or changed-since-save files are ineligible. Already-clean scope can be explicitly admitted. Organize All in Scope is available for a deliberate naming-only workflow.

There is no automatic chaining into filesystem moves. Imports, tag writes and organization retain their existing identity checks, collision policies and recovery behavior.
