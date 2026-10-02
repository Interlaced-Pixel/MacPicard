# MacPicard accessibility audit

Phase 9 audit baseline: macOS 26 SwiftUI controls and navigation are used throughout the primary workflow.

## Verified in source

- Import, lookup, cover-art, script, save, organize, settings, and dismissal actions expose visible labels and help text where appropriate.
- Track rows combine title, filename, and state into a single VoiceOver element.
- Artwork previews expose a meaningful label and mark decorative backdrop shapes hidden.
- Progress indicators expose operation-progress or working labels.
- Native List, TextField, TextEditor, Form, NavigationSplitView, and Button controls retain standard keyboard and focus behavior.
- Command menu actions provide keyboard equivalents for selection and MusicBrainz operations.
- The interface uses system fonts, standard materials, semantic colors, and no color-only state indication.

## Release verification

Before shipping a signed build, run VoiceOver through import, multi-selection, metadata editing, lookup, script preview, save, and organize flows. Verify Reduce Motion, Increase Contrast, Larger Text, and keyboard-only navigation on a macOS 26 release system. The audit is intentionally kept as a release checklist because those behaviors depend on the actual OS accessibility stack and cannot be proven by a command-line build alone.
