import AppKit
import PicardSessions
import SwiftUI

struct MacPicardCommands: Commands {
    @ObservedObject var model: AppModel
    @ObservedObject var presentation: AppPresentation
    @ObservedObject var playback: PlaybackController

    init(model: AppModel, presentation: AppPresentation) {
        self.model = model
        self.presentation = presentation
        playback = model.playback
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Session…") { presentation.newSession() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(model.isBusy)
            Button("Add Music Library…") { presentation.isAddingLibrary = true }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(model.isBusy)
            Menu("Open Workspace") {
                ForEach(model.workspaces.sorted { $0.lastOpenedAt > $1.lastOpenedAt }) { workspace in
                    Button(workspace.name) { Task { await model.switchWorkspace(workspace.id) } }
                        .disabled(model.isBusy || workspace.id == model.activeWorkspaceID)
                }
            }
        }

        CommandGroup(replacing: .importExport) {
            Button("Import Audio Files or Folder…") { presentation.isImporting = true }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(model.isBusy)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save Selected Tags") { Task { await model.saveSelected() } }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!model.canPerform(.save))
            Button("Save All Changed Tags") { Task { await model.saveAllChanges() } }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(model.isBusy || !model.hasUnsavedChanges)
            Divider()
            Button("Save Workspace") { Task { await model.saveSession() } }
                .keyboardShortcut("s", modifiers: [.command, .control])
                .disabled(model.isBusy)
            Button("Save Session As…") { presentation.newSession(copying: true) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(model.isBusy)
            Divider()
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: .command)
        }

        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { presentation.isShowingSettings = true }
                .keyboardShortcut(",", modifiers: .command)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Select All Visible Tracks") { model.selectAllVisible() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(model.visibleFiles.isEmpty)
            Button("Clear Track Selection") { model.clearSelection() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(model.selectedFiles.isEmpty)
            Button("Find Music…") { presentation.focusSearch() }
                .keyboardShortcut("f", modifiers: .command)
        }

        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { model.undoUserEdit() }.keyboardShortcut("z", modifiers: .command)
                .disabled(model.isBusy || !model.canUndoUserEdit)
            Button("Redo") { model.redoUserEdit() }.keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(model.isBusy || !model.canRedoUserEdit)
            Divider()
            Button("Discard Selected Changes…") {
                presentation.requestDiscard(model.selectedFiles, workspaceID: model.activeWorkspaceID)
            }.keyboardShortcut("z", modifiers: [.command, .option])
                .disabled(!model.canDiscardChanges(model.selectedFileIDs))
            Button("Discard All Unsaved Changes…") {
                presentation.requestDiscard(model.files, workspaceID: model.activeWorkspaceID)
            }.disabled(!model.canDiscardChanges(Set(model.files.map(\.id))))
        }

        CommandGroup(after: .sidebar) {
            Button(presentation.showsSidebar ? "Hide Sidebar" : "Show Sidebar") {
                presentation.showsSidebar.toggle()
            }.keyboardShortcut("s", modifiers: [.command, .control, .option])
            Button(presentation.showsInspector ? "Hide Metadata Inspector" : "Show Metadata Inspector") {
                presentation.showsInspector.toggle()
            }.keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
            Button("Show All Tracks") { model.searchQuery = ""; model.browseAllTracks() }
                .keyboardShortcut("1", modifiers: .command)
            Button("Expand All Albums") { model.expandAllAlbums() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Collapse All Albums") { model.collapseAllAlbums() }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Menu("Filter Tracks") {
                Picker("Filter", selection: $model.browserFilter) {
                    ForEach(BrowserFilter.allCases) { filter in Text(filter.rawValue).tag(filter) }
                }
            }
            Menu("Sort Albums") {
                Picker("Sort", selection: $model.albumSort) {
                    ForEach(AlbumSort.allCases) { sort in Text(sort.rawValue).tag(sort) }
                }
            }
        }

        CommandMenu("Library") {
            Button("Manage Libraries & Sessions…") { presentation.isManagingWorkspaces = true }
                .keyboardShortcut("l", modifiers: [.command, .option])
            Button("Refresh Library") { Task { await model.refreshLibrary() } }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isBusy || model.activeWorkspace?.kind != .library)
            Button("Match Entire Library…") { presentation.isShowingLibraryMatch = true }
                .keyboardShortcut("m", modifiers: [.command, .option])
                .disabled(model.isBusy || model.activeWorkspace?.kind != .library || model.albumGroups.isEmpty)
            Button("Cancel Library Refresh") { model.cancelLibraryRefresh() }
                .disabled(!model.isScanningLibrary)
            Toggle("Refresh Automatically", isOn: Binding(
                get: { model.activeWorkspace?.automaticallyRefreshes ?? false },
                set: { value in Task { await model.setAutomaticRefresh(value) } }
            )).disabled(model.isBusy || model.activeWorkspace?.kind != .library)
            Button("Reconnect Library Folder…") { presentation.isRelinkingLibrary = true }
                .disabled(model.isBusy || model.activeWorkspace?.kind != .library)
            Button("Restore Removed Library Items") { Task { await model.restoreExcludedLibraryItems() } }
                .disabled(model.isBusy || model.activeWorkspace?.excludedRelativePaths.isEmpty != false)
            Divider()
            Button(model.removalActionTitle, role: .destructive) {
                presentation.requestRemoval(model.selectedFileIDs, workspaceID: model.activeWorkspaceID)
            }.keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.isBusy || model.selectedFiles.isEmpty)
            Button("Move Library Files to Trash…", role: .destructive) {
                presentation.requestRemoval(model.selectedFileIDs, workspaceID: model.activeWorkspaceID, trash: true)
            }.disabled(!model.canTrash(model.selectedFileIDs))
            Button("Remove Current Workspace…") { presentation.isManagingWorkspaces = true }
                .disabled(model.isBusy || model.activeWorkspace == nil)
            Divider()
            Button("Reveal Library Folder in Finder") { model.revealLibrary() }
                .disabled(model.activeWorkspace?.directory == nil)
            Button("Reveal Selected Files in Finder") { model.revealSelection() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.selectedFiles.isEmpty)
        }

        CommandMenu("Playback") {
            Button("Play Selected Track") {
                if let file = model.primarySelectedFile { model.playTrack(file.id) }
            }.keyboardShortcut(.return, modifiers: .command)
                .disabled(model.primarySelectedFile.map { !model.canPlay($0) } ?? true)
            Button(playback.transportIsActive ? "Pause" : "Play / Resume") { playback.togglePlayPause() }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(playback.currentTrack == nil)
            Button("Previous Track") { playback.previous() }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .control])
                .disabled(!playback.canGoPrevious)
            Button("Next Track") { playback.next() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .control])
                .disabled(!playback.canGoNext)
            Button("Stop") { playback.stop() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(playback.currentTrack == nil)
            Divider()
            Button("Show Playback Queue") { presentation.showsPlaybackQueue = true }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(playback.queue.isEmpty)
            Button("Clear Playback Queue") { playback.stop(clearQueue: true) }
                .disabled(playback.queue.isEmpty)
        }

        CommandMenu("Metadata") {
            Button("All Tags & Changes…") { presentation.isShowingMetadataEditor = true }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(!model.canEditSelection)
            Button("Look Up on MusicBrainz…") {
                presentation.isShowingLookup = true
                Task { await model.lookup() }
            }.keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(!model.canLookupSelection)
            Button("Review Track Matches…") { presentation.isShowingLookup = true }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(model.isBusy || model.matchReview == nil)
            Button("Download Cover Art") { Task { await model.downloadCoverArt() } }
                .disabled(model.isBusy || !model.canDownloadCoverArt)
            Divider()
            Button("Script Editor…") { presentation.isShowingScript = true }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!model.canEditSelection)
            Button("Organize Selected Files…") {
                model.requestOrganizationReview()
                presentation.isShowingOrganization = true
            }.keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(!model.canPerform(.organize))
            if model.activeWorkspace?.kind == .library {
                Button("Organize Entire Library…") {
                    model.requestOrganizationReview(entireLibrary: true)
                    presentation.isShowingOrganization = true
                }
                .disabled(!model.canOrganizeEntireLibrary)
            }
        }

        CommandGroup(replacing: .help) {
            Button("MacPicard Guide") { presentation.isShowingGuide = true }
        }
    }
}

struct QuickStartView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Get things done with MacPicard").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            guide("Keep a music library", symbol: "externaldrive",
                  text: "Choose File → Add Music Library and select a folder. Imports copy audio into Artist / Album folders, leaving originals untouched. Existing library files are indexed in place. Right-click tracks or albums to remove them from the library or move its copies to Trash after confirmation. Remove a library in Library → Manage Libraries & Sessions; this never deletes its audio.")
            guide("Keep separate sessions", symbol: "rectangle.stack",
                  text: "Create a named session for a particular tagging task. Import files or folders, then return through the workspace chooser or File → Open Workspace. Pending edits are saved in the workspace; Save Tags writes them to the audio files.")
            guide("Review and revert", symbol: "arrow.triangle.branch",
                  text: "Look Up shows suggested file-to-track assignments. Choose or swap tracks, leave extras unmatched, and preview tag changes before applying. Nothing is written until Save Tags. Use Discard on the toolbar or in the Edit/right-click menus to revert pending tags and artwork; already-saved tags cannot be undone this way.")
            guide("Navigate a large collection", symbol: "magnifyingglass",
                  text: "Albums start collapsed. Click an album to open all its tracks; click its chevron to expand the sidebar. Press ⌘F to search title, artist, album, genre, or filename across the collection. Filters highlight unsaved edits, missing artwork, unidentified tracks, and unavailable files.")
            guide("Edit and identify music", symbol: "slider.horizontal.3",
                  text: "Select tracks with Command-click or Shift-click. The inspector shows Multiple values when tags differ; typing a value applies it to the selection. Use Metadata → Look Up on MusicBrainz, choose a release, then Apply Match. Save Selected Tags with ⌘S, or Save All Changed Tags with ⌥⌘S.")
            guide("Listen while you work", symbol: "play.circle",
                  text: "Right-click a song to Play, Play Next, or Add to Queue. Right-click an album to play it in track order. The player provides pause, seeking, volume, and queue controls. Double-click a track to play it; ⌘P toggles playback. Playback stops when you switch workspaces or quit.")
            guide("Organize files", symbol: "folder.badge.gearshape",
                  text: "Organize previews filenames and folders before moving anything. Choose a naming preset or custom pattern, resolve conflicts, exclude files, then confirm Move Files. Libraries default to their own folder; moves outside it need explicit acknowledgment. Existing files are never overwritten. Pending tags remain unsaved. Reveal files in Finder with ⇧⌘R.")
        }
        .padding(24)
        .frame(width: 650)
    }

    private func guide(_ title: String, symbol: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.tint).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
