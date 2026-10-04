import PicardFoundation
import PicardSessions
import SwiftUI

@MainActor
final class AppPresentation: ObservableObject {
    @Published var isImporting = false
    @Published var isChoosingDestination = false
    @Published var isShowingLookup = false
    @Published var isShowingScript = false
    @Published var isShowingSettings = false
    @Published var isAddingLibrary = false
    @Published var isRelinkingLibrary = false
    @Published var isNamingSession = false
    @Published var isManagingWorkspaces = false
    @Published var copiesCurrentSession = false
    @Published var showsSidebar = true
    @Published var showsInspector = true
    @Published var searchFocusRequest = 0
    @Published var isShowingGuide = false
    @Published var showsPlaybackQueue = false
    @Published var isConfirmingTrackRemoval = false
    @Published var trackRemovalRequest: TrackRemovalRequest?
    @Published var isConfirmingDiscard = false
    @Published var discardRequest: DiscardRequest?

    struct DiscardRequest {
        let workspaceID: UUID?
        let fileIDs: Set<UUID>
    }

    func requestDiscard(_ files: [AudioFile], workspaceID: UUID?) {
        let ids = Set(files.filter(\.isModified).map(\.id))
        guard !ids.isEmpty else { return }
        discardRequest = DiscardRequest(workspaceID: workspaceID, fileIDs: ids)
        isConfirmingDiscard = true
    }

    struct TrackRemovalRequest {
        let workspaceID: UUID?
        let fileIDs: Set<UUID>
        let trash: Bool
    }

    func requestRemoval(_ ids: Set<UUID>, workspaceID: UUID?, trash: Bool = false) {
        trackRemovalRequest = TrackRemovalRequest(workspaceID: workspaceID, fileIDs: ids, trash: trash)
        isConfirmingTrackRemoval = true
    }

    func newSession(copying: Bool = false) {
        copiesCurrentSession = copying
        isNamingSession = true
    }

    func focusSearch() {
        showsSidebar = true
        searchFocusRequest += 1
    }
}

struct LibrarySidebar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var presentation: AppPresentation
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            workspaceChooser
                .padding(14)
            Divider()
            searchControls
                .padding(12)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    Button {
                        model.browseAllTracks()
                    } label: {
                        HStack {
                            Label("All Tracks", systemImage: "music.note.list")
                            Spacer()
                            Text(model.workspaceFilesCount, format: .number)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .background(
                            model.browsingAllTracks ? Color.accentColor.opacity(0.14) : .clear,
                            in: .rect(cornerRadius: 9)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    HStack {
                        Text("ALBUMS")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(model.browserAlbumGroups.count, format: .number)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 8)

                    ForEach(model.browserAlbumGroups) { group in
                        AlbumBrowserRow(model: model, presentation: presentation, group: group)
                    }

                    if model.browserAlbumGroups.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: model.files.isEmpty ? "folder.badge.plus" : "magnifyingglass")
                                .font(.title2)
                            Text(model.files.isEmpty ? "Build your collection" : "No matching albums")
                                .font(.subheadline.weight(.medium))
                            Text(model.files.isEmpty
                                ? "Add a music folder as a library, or import files into this session."
                                : "Try another search or filter.")
                                .font(.caption)
                                .multilineTextAlignment(.center)
                            if model.files.isEmpty {
                                Button("Add Music Library…") { presentation.isAddingLibrary = true }
                                    .buttonStyle(.glass)
                            } else {
                                Button("Clear Search & Filter") {
                                    model.searchQuery = ""
                                    model.browserFilter = .all
                                }
                            }
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        .padding(.horizontal, 12)
                    }
                }
                .padding(8)
            }
            Divider()
            footer
                .padding(10)
        }
        .background(.thinMaterial)
        .onChange(of: presentation.searchFocusRequest) { _, _ in isSearchFocused = true }
    }

    private var workspaceChooser: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: model.activeWorkspace?.kind == .library ? "externaldrive" : "rectangle.stack")
                    .foregroundStyle(.tint)
                Text(model.activeWorkspace?.kind == .library ? "Music Library" : "Session")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("Add Music Library…") { presentation.isAddingLibrary = true }
                    Button("New Session…") { presentation.newSession() }
                    Button("Manage Libraries & Sessions…") { presentation.isManagingWorkspaces = true }
                } label: { Image(systemName: "plus") }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Add a library or session")
                .disabled(model.isBusy)
            }
            Menu {
                Section("Libraries") {
                    ForEach(model.workspaces.filter { $0.kind == .library }) { workspace in
                        workspaceButton(workspace)
                    }
                }
                Section("Sessions") {
                    ForEach(model.workspaces.filter { $0.kind == .session }) { workspace in
                        workspaceButton(workspace)
                    }
                }
                Divider()
                Button("Manage Libraries & Sessions…") { presentation.isManagingWorkspaces = true }
            } label: {
                Text(model.activeWorkspace?.name ?? "Choose a Workspace")
                    .font(.headline)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .menuStyle(.borderlessButton)
            .disabled(model.isBusy)

            if let workspace = model.activeWorkspace, workspace.kind == .library {
                HStack(spacing: 6) {
                    Text(workspace.directory?.lastPathComponent ?? "Folder unavailable")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(workspace.directory?.path ?? "")
                    Spacer()
                    Button { Task { await model.refreshLibrary() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help("Refresh library from disk")
                    .accessibilityLabel("Refresh Library")
                    .disabled(model.isBusy)
                }
            }
        }
    }

    private func workspaceButton(_ workspace: MusicWorkspace) -> some View {
        Button {
            Task { await model.switchWorkspace(workspace.id) }
        } label: {
            if model.activeWorkspaceID == workspace.id {
                Label(workspace.name, systemImage: "checkmark")
            } else { Text(workspace.name) }
        }
    }

    private var searchControls: some View {
        VStack(spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search music…", text: $model.searchQuery)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                    .accessibilityLabel("Search Music")
                if !model.searchQuery.isEmpty {
                    Button { model.searchQuery = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Clear Search")
                }
            }
            .padding(8)
            .background(.background.opacity(0.7), in: .rect(cornerRadius: 9))

            HStack {
                Menu {
                    Picker("Filter", selection: $model.browserFilter) {
                        ForEach(BrowserFilter.allCases) { filter in
                            Label(filter.rawValue, systemImage: filter.symbol).tag(filter)
                        }
                    }
                } label: {
                    Label(model.browserFilter == .all ? "Filter" : model.browserFilter.rawValue,
                          systemImage: "line.3.horizontal.decrease")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                Spacer(minLength: 3)
                Menu {
                    Picker("Sort Albums", selection: $model.albumSort) {
                        ForEach(AlbumSort.allCases) { sort in Text(sort.rawValue).tag(sort) }
                    }
                    Divider()
                    Button("Expand All Albums") { model.expandAllAlbums() }
                    Button("Collapse All Albums") { model.collapseAllAlbums() }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Sort and expand albums")
            }
        }
    }

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(model.albumGroups.count) albums · \(model.workspaceFilesCount) files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.hasUnsavedChanges {
                    Text("\(model.files.count(where: \.isModified)) pending edits")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Button { presentation.isShowingSettings = true } label: { Image(systemName: "gearshape") }
                .buttonStyle(.glass)
                .help("Settings")
                .accessibilityLabel("Settings")
        }
    }
}

private struct AlbumBrowserRow: View {
    @ObservedObject var model: AppModel
    @ObservedObject var presentation: AppPresentation
    let group: AppModel.AlbumGroup

    private var isExpanded: Bool { model.expandedAlbumIDs.contains(group.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) { model.toggleAlbumExpansion(group.id) }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 18, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(isExpanded ? "Collapse" : "Expand") \(group.title)")
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

                Button { model.selectAlbum(group) } label: {
                    HStack(spacing: 8) {
                        ArtworkThumbnail(artwork: group.fileIDs.first.flatMap { model.file(id: $0)?.artwork.first(of: .front) })
                            .frame(width: 34, height: 34)
                            .clipShape(.rect(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(group.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open album \(group.title)")
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .background(model.selectedAlbumID == group.id ? Color.accentColor.opacity(0.12) : .clear,
                        in: .rect(cornerRadius: 10))
            .contextMenu {
                AlbumContextMenu(model: model, presentation: presentation, group: group)
            }

            if isExpanded {
                ForEach(group.fileIDs, id: \.self) { id in
                    if let file = model.file(id: id), model.matchingFileIDs.contains(id) {
                        Button { model.selectSidebarTrack(id, album: group) } label: {
                            SidebarTrackRow(file: file, isSelected: model.selectedFileIDs.contains(id), playback: model.playback)
                        }
                        .buttonStyle(.plain)
                        .help(file.url.lastPathComponent)
                        .contextMenu { TrackContextMenu(model: model, presentation: presentation, fileID: id) }
                    }
                }
            }
        }
    }
}

struct NewSessionView: View {
    @ObservedObject var model: AppModel
    let copying: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(copying ? "Save Session As" : "New Session", systemImage: "rectangle.stack.badge.plus")
                .font(.title2.weight(.semibold))
            Text(copying
                ? "Save the current files and pending edits in a separate named session."
                : "A session remembers its files and pending edits. You can return to it at any time.")
                .foregroundStyle(.secondary)
            TextField("Session name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { create() }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(copying ? "Save Session" : "Create Session") { create() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isBusy)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func create() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task { await model.createSession(named: name, copyingCurrent: copying); dismiss() }
    }
}

struct WorkspaceManagerView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var presentation: AppPresentation
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: UUID?
    @State private var name = ""
    @State private var confirmsRemoval = false

    private var selected: MusicWorkspace? { model.workspaces.first { $0.id == selectedID } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Libraries & Sessions").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                List(selection: $selectedID) {
                    ForEach(model.workspaces) { workspace in
                        HStack {
                            Image(systemName: workspace.kind == .library ? "externaldrive" : "rectangle.stack")
                            VStack(alignment: .leading) {
                                Text(workspace.name)
                                Text(workspace.kind == .library ? "Folder Library" : "Session")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if workspace.id == model.activeWorkspaceID {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                            }
                        }.tag(workspace.id)
                    }
                }.frame(width: 230)

                VStack(alignment: .leading, spacing: 14) {
                    if let workspace = selected {
                        Text(workspace.kind == .library ? "Music Library" : "Session")
                            .font(.headline)
                        TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                        Button("Rename") { Task { await model.renameWorkspace(workspace, to: name) } }
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name == workspace.name)
                        if let directory = workspace.directory {
                            Text(directory.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            if let lastScanned = workspace.lastScannedAt {
                                Text("Last refreshed \(lastScanned.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if workspace.id == model.activeWorkspaceID && workspace.kind == .library {
                            Toggle("Refresh automatically every minute", isOn: Binding(
                                get: { model.activeWorkspace?.automaticallyRefreshes ?? false },
                                set: { value in Task { await model.setAutomaticRefresh(value) } }
                            ))
                            Button("Reconnect Folder…") {
                                dismiss()
                                presentation.isRelinkingLibrary = true
                            }
                        }
                        HStack {
                            Button("Open") {
                                Task { await model.switchWorkspace(workspace.id); dismiss() }
                            }.buttonStyle(.glassProminent)
                                .disabled(workspace.id == model.activeWorkspaceID)
                            Button("Remove…", role: .destructive) { confirmsRemoval = true }
                        }
                        Text("Removing a workspace leaves all audio files untouched. If it is open, MacPicard switches to another workspace.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Button("Add Music Library…") { dismiss(); presentation.isAddingLibrary = true }
                Button("New Session…") { dismiss(); presentation.newSession() }
                Spacer()
            }.padding(16)
        }
        .frame(width: 690, height: 430)
        .disabled(model.isBusy)
        .onAppear { selectedID = model.activeWorkspaceID; name = selected?.name ?? "" }
        .onChange(of: selectedID) { _, _ in name = selected?.name ?? "" }
        .onChange(of: model.workspaces.map(\.id)) { _, ids in
            if let selectedID, !ids.contains(selectedID) {
                self.selectedID = model.activeWorkspaceID
            }
        }
        .confirmationDialog("Remove \(selected?.name ?? "workspace")?", isPresented: $confirmsRemoval) {
            Button("Remove Workspace", role: .destructive) {
                if let selected { Task { await model.removeWorkspace(selected) } }
            }
        } message: { Text("Your music stays on disk. The saved workspace document is retained in Application Support.") }
    }
}
