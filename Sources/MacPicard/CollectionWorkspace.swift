import AppKit
import PicardFoundation
import PicardSessions
import SwiftUI

struct BrowserEntry {
    let artist: String
    let grouping: String
    let searchText: String
    init(_ file: AudioFile) {
        artist = file.metadata.firstValue(for: "albumartist") ?? file.metadata.firstValue(for: "artist") ?? "Unknown artist"
        grouping = [artist, file.metadata.firstValue(for: "album") ?? "", file.metadata.firstValue(for: "discnumber") ?? "", file.metadata.firstValue(for: "tracknumber") ?? "", file.metadata.firstValue(for: "title") ?? ""].joined(separator: "\u{1F}")
        searchText = ([file.url.lastPathComponent] + ["title", "artist", "album", "albumartist", "genre"].flatMap { file.metadata.values(for: $0) }).joined(separator: " ")
    }
}

struct CollectionTrack: Identifiable {
    let id: UUID
    let title: String
    let artist: String
    let album: String
    let number: Int
    let duration: Int
    let format: String
    let state: String
    let filename: String
    init(_ file: AudioFile) {
        id = file.id; title = file.metadata.firstValue(for: "title") ?? file.url.deletingPathExtension().lastPathComponent
        artist = file.metadata.firstValue(for: "artist") ?? "Unknown artist"
        album = file.metadata.firstValue(for: "album") ?? "Unmatched files"
        number = Int(file.metadata.firstValue(for: "tracknumber")?.split(separator: "/").first ?? "0") ?? 0
        duration = file.durationInMilliseconds ?? 0; format = file.url.pathExtension.uppercased()
        state = file.isModified ? "Changed" : file.state.rawValue.capitalized
        filename = file.url.lastPathComponent
    }
}

struct BrowserPreferences: Codable {
    var sort = "number"
    var descending = false
    var columns = TableColumnCustomization<CollectionTrack>()
    var toolbarActions: Set<String> = ["import", "lookup", "save", "organize", "artwork", "scripts", "activity"]
    var showsSidebar = true
    var showsInspector = true

    private enum CodingKeys: String, CodingKey { case sort, descending, columns, toolbarActions, showsSidebar, showsInspector }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sort = try values.decodeIfPresent(String.self, forKey: .sort) ?? "number"
        descending = try values.decodeIfPresent(Bool.self, forKey: .descending) ?? false
        columns = try values.decodeIfPresent(TableColumnCustomization<CollectionTrack>.self, forKey: .columns) ?? TableColumnCustomization()
        toolbarActions = try values.decodeIfPresent(Set<String>.self, forKey: .toolbarActions) ?? ["import", "lookup", "save", "organize", "artwork", "scripts", "activity"]
        showsSidebar = try values.decodeIfPresent(Bool.self, forKey: .showsSidebar) ?? true
        showsInspector = try values.decodeIfPresent(Bool.self, forKey: .showsInspector) ?? true
    }
}

enum BrowserToolbarAction: String, CaseIterable, Identifiable {
    case importFiles = "import"
    case lookup
    case save
    case organize
    case artwork
    case scripts
    case discard
    case activity

    var id: String { rawValue }
    var title: String {
        switch self {
        case .importFiles: "Import"
        case .lookup: "Look Up"
        case .save: "Save"
        case .organize: "Organize"
        case .artwork: "Artwork"
        case .scripts: "Tools"
        case .discard: "Discard"
        case .activity: "Activity"
        }
    }
    var systemImage: String {
        switch self {
        case .importFiles: "plus"
        case .lookup: "magnifyingglass"
        case .save: "square.and.arrow.down"
        case .organize: "folder.badge.gearshape"
        case .artwork: "photo"
        case .scripts: "wand.and.stars"
        case .discard: "arrow.uturn.backward"
        case .activity: "list.bullet.rectangle"
        }
    }
}

struct ActivityEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let message: String
    let background: Bool
}

extension AppModel {
    func reloadOperationHistory(markInterrupted: Bool = false) async {
        guard let directory = operationHistoryDirectory, let id = activeWorkspaceID else { return }
        do {
            let records = try await operationHistoryStore.load(directory: directory, workspaceID: id, markInterrupted: markInterrupted)
            guard activeWorkspaceID == id, operationHistoryDirectory == directory else { return }
            operationHistory = records
            if records.contains(where: { $0.state == .interrupted }) {
                recordActivity("An operation was interrupted. Open Activity to check its files.")
            }
        } catch { present(error) }
    }

    func persistOperation(_ record: FileOperationRecord) async throws {
        guard let directory = operationHistoryDirectory else { return }
        try await operationHistoryStore.save(record, directory: directory)
        if activeWorkspaceID == record.workspaceID {
            operationHistory.removeAll { $0.id == record.id }
            operationHistory.insert(record, at: 0)
        }
    }

    func retryableSaveIDs(_ record: FileOperationRecord) -> Set<UUID> {
        guard record.workspaceID == activeWorkspaceID, record.kind == .save, !isBusy else { return [] }
        return Set(record.items.compactMap { item in
            guard item.state == .failed, let baseline = item.baseline,
                  file(id: item.id)?.matchesPersistedRevision(baseline) == true, baseline.isModified,
                  [.ready, .changed, .saved].contains(baseline.state) else { return nil }
            return item.id
        })
    }

    func retryOperation(_ record: FileOperationRecord) async {
        guard !isBusy, record.workspaceID == activeWorkspaceID else { return }
        if record.kind == .scan { await refreshLibrary(); return }
        if record.kind == .importFiles {
            let sources = record.items.filter { [.failed, .pending, .inProgress].contains($0.state) }.map(\.source)
            if !sources.isEmpty { await importURLs(expanding: sources) }
            return
        }
        let ids = retryableSaveIDs(record)
        guard !ids.isEmpty else { return }
        await saveFiles(contextFiles(ids))
        let successes = Set(lastSaveOutcomes.filter(\.saved).map(\.fileID))
        guard !successes.isEmpty else { return }
        var resolved = record
        for index in resolved.items.indices where successes.contains(resolved.items[index].id) {
            resolved.items[index].state = .recovered
            resolved.items[index].result = file(id: resolved.items[index].id)
            resolved.items[index].message = "Saved by retry."
        }
        if resolved.items.allSatisfy({ [.completed, .recovered, .skipped].contains($0.state) }) { resolved.state = .completed }
        resolved.finishedAt = Date()
        do { try await persistOperation(resolved) } catch { present(error) }
    }

    func restoreCommittedOperationResults() async {
        let records = operationHistory
        let current = Dictionary(files.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let excluded = activeWorkspace?.excludedRelativePaths ?? []
        let root = libraryDirectory
        let replacements = await Task.detached(priority: .utility) {
            var results: [UUID: AudioFile] = [:]
            for record in records where record.state == .interrupted {
                for item in record.items {
                    guard let result = item.result, results[result.id] == nil,
                          let actual = try? AudioFileIdentity.capture(url: result.url), actual.matches(result.identity) else { continue }
                    if let previous = current[result.id] {
                        guard previous.matchesPersistedRevision(item.baseline) else { continue }
                    } else {
                        guard record.kind == .importFiles, let root,
                              let path = LibraryPaths.relativePath(of: result.url, in: root), !excluded.contains(path) else { continue }
                    }
                    results[result.id] = result
                }
            }
            return results
        }.value
        guard !replacements.isEmpty else { return }
        let existingIDs = Set(files.map(\.id))
        var restored = files.map { replacements[$0.id] ?? $0 }
        restored.append(contentsOf: replacements.values.filter { !existingIDs.contains($0.id) }.sorted { $0.url.path < $1.url.path })
        if files != restored {
            files = restored
            do { try await flushSession(); statusMessage = "Recovered completed file operations. Check Activity for unfinished files." }
            catch { present(error) }
        }
    }

    func startOperationCheck(_ record: FileOperationRecord) {
        guard !isBusy, recoveryCheckTask == nil else { return }
        recoveryCheckTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.recoveryCheckTask = nil }
            await self.checkInterruptedOperation(record)
        }
    }

    func checkInterruptedOperation(_ record: FileOperationRecord) async {
        guard !isBusy, record.workspaceID == activeWorkspaceID,
              [.save, .organize].contains(record.kind) else { return }
        isWorking = true; checkingOperationID = record.id; progress = 0
        statusMessage = "Checking \(record.items.count) files…"
        defer { isWorking = false; checkingOperationID = nil; progress = nil }
        do {
            let checked = try await operationHistoryStore.check(record) { [weak self] value in
                await self?.updateSaveProgress(value)
            }
            try Task.checkCancellation()
            let baselines = Dictionary(record.items.compactMap { item in item.baseline.map { (item.id, $0) } }, uniquingKeysWith: { _, last in last })
            let results = Dictionary(checked.items.compactMap { item in item.result.map { (item.id, $0) } }, uniquingKeysWith: { _, last in last })
            let merged = files.map { file in
                // A later user edit always wins, including changes made since a
                // previous recovery check. Recovery never writes audio itself.
                file.matchesPersistedRevision(baselines[file.id]) ? (results[file.id] ?? file) : file
            }
            if merged != files { files = merged; clearEditHistory() }
            try await flushSession()
            try await persistOperation(checked)
            statusMessage = checked.state == .completed ? "File checks complete." : "Some files need attention. See Activity for their paths."
        } catch is CancellationError { statusMessage = "File check cancelled. No recovery changes were applied." }
        catch { present(error) }
    }

    func loadBrowserPreferences() {
        guard let browserPreferencesURL else { return }
        do { browserPreferences = try JSONDecoder().decode(BrowserPreferences.self, from: Data(contentsOf: browserPreferencesURL)) }
        catch { if FileManager.default.fileExists(atPath: browserPreferencesURL.path) { recordActivity("Browser preferences could not be restored; using defaults.") } }
    }
    func saveBrowserPreferences() {
        guard let browserPreferencesURL else { return }
        do { try JSONEncoder().encode(browserPreferences).write(to: browserPreferencesURL, options: .atomic) }
        catch { present(error) }
    }
    func recordActivity(_ message: String, background: Bool = false) {
        guard !message.isEmpty, activity.last?.message != message else { return }
        activity.append(ActivityEntry(message: message, background: background))
        if activity.count > 200 { activity.removeFirst(activity.count - 200) }
    }
    func browseDestination(_ filter: BrowserFilter) {
        searchQuery = ""; appliedSearchQuery = ""; selectedAlbumID = nil; selectedArtist = nil
        browserFilter = filter; applyBrowserSearch(); clearSelection()
    }
    func browseArtist(_ artist: String) {
        selectedArtist = artist; selectedAlbumID = nil; clearSelection()
    }
    func navigateAlbum(_ group: AlbumGroup) {
        searchQuery = ""; appliedSearchQuery = ""; selectedArtist = nil
        selectedAlbumID = group.id; applyBrowserSearch()
        selectionChanged(selectedFileIDs.intersection(Set(group.fileIDs)))
    }
}

struct CollectionTrackTable: View {
    @ObservedObject var model: AppModel
    @ObservedObject var presentation: AppPresentation
    @State private var sortOrder = [KeyPathComparator(\CollectionTrack.number)]
    private var rows: [CollectionTrack] { model.visibleFiles.map(CollectionTrack.init).sorted(using: sortOrder) }
    private func idealWidth(_ values: [String], minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        let longest = values.map { CGFloat($0.count) }.max() ?? 0
        return min(max(minimum, longest * 7.2 + 28), maximum)
    }
    var body: some View {
        Table(rows, selection: Binding(get: { model.selectedFileIDs }, set: { model.selectionChanged($0) }), sortOrder: $sortOrder,
              columnCustomization: $model.browserPreferences.columns) {
            TableColumn("Title", value: \.title) { row in
                HStack {
                    if model.playback.currentTrack?.fileID == row.id { Image(systemName: "speaker.wave.2.fill").accessibilityLabel("Now playing") }
                    Text(row.title).lineLimit(1)
                }
            }.width(min: 160, ideal: idealWidth(rows.map(\.title), minimum: 210, maximum: 420)).customizationID("title").disabledCustomizationBehavior(.visibility)
            TableColumn("Artist", value: \.artist).width(min: 120, ideal: idealWidth(rows.map(\.artist), minimum: 150, maximum: 300)).customizationID("artist")
            TableColumn("Album", value: \.album).width(min: 140, ideal: idealWidth(rows.map(\.album), minimum: 170, maximum: 340)).customizationID("album")
            TableColumn("#", value: \.number) { Text($0.number == 0 ? "—" : String($0.number)) }.width(40).customizationID("number")
            TableColumn("Time", value: \.duration) { Text($0.duration == 0 ? "—" : String(format: "%d:%02d", $0.duration / 60_000, $0.duration / 1_000 % 60)) }.width(65).customizationID("duration")
            TableColumn("Format", value: \.format).width(65).customizationID("format")
            TableColumn("State", value: \.state) { row in
                Text(row.state)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(stateColor(row.state))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(stateColor(row.state).opacity(0.14), in: .capsule)
            }.width(100).customizationID("state")
            TableColumn("File", value: \.filename).width(min: 150, ideal: idealWidth(rows.map(\.filename), minimum: 190, maximum: 420)).customizationID("filename")
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first { TrackContextMenu(model: model, presentation: presentation, fileID: id) }
        } primaryAction: { ids in if let id = ids.first { model.playTrack(id) } }
        .onAppear { sortOrder = [savedSort()] }
        .onChange(of: sortOrder) { _, value in
            guard let comparator = value.first else { return }
            model.browserPreferences.sort = sortName(comparator)
            model.browserPreferences.descending = comparator.order == .reverse
            model.saveBrowserPreferences()
        }
        .onChange(of: model.browserPreferences.columns) { model.saveBrowserPreferences() }
    }
    private func savedSort() -> KeyPathComparator<CollectionTrack> {
        let order: SortOrder = model.browserPreferences.descending ? .reverse : .forward
        switch model.browserPreferences.sort {
        case "title": return KeyPathComparator(\.title, order: order)
        case "artist": return KeyPathComparator(\.artist, order: order)
        case "album": return KeyPathComparator(\.album, order: order)
        case "duration": return KeyPathComparator(\.duration, order: order)
        case "format": return KeyPathComparator(\.format, order: order)
        case "state": return KeyPathComparator(\.state, order: order)
        case "filename": return KeyPathComparator(\.filename, order: order)
        default: return KeyPathComparator(\.number, order: order)
        }
    }
    private func sortName(_ value: KeyPathComparator<CollectionTrack>) -> String {
        if value.keyPath == \CollectionTrack.title { return "title" }
        if value.keyPath == \CollectionTrack.artist { return "artist" }
        if value.keyPath == \CollectionTrack.album { return "album" }
        if value.keyPath == \CollectionTrack.duration { return "duration" }
        if value.keyPath == \CollectionTrack.format { return "format" }
        if value.keyPath == \CollectionTrack.state { return "state" }
        if value.keyPath == \CollectionTrack.filename { return "filename" }
        return "number"
    }

    private func stateColor(_ state: String) -> Color {
        switch state.lowercased() {
        case "changed": return MusicBrainzTheme.orange
        case "saved", "ready": return MusicBrainzTheme.success
        case "failed", "unsupported": return MusicBrainzTheme.error
        default: return .secondary
        }
    }
}

struct ToolbarEditorView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Customize Toolbar").font(.title2.weight(.bold))
                    Text("Choose the actions that stay close at hand.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(22)
            .background(LinearGradient(colors: [MusicBrainzTheme.purple.opacity(0.18), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))

            List {
                Section("Visible actions") {
                    ForEach(BrowserToolbarAction.allCases) { action in
                        Toggle(isOn: binding(for: action)) {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(action.title)
                                    Text(description(for: action)).font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: action.systemImage).foregroundStyle(MusicBrainzTheme.purple).frame(width: 24)
                            }
                        }
                    }
                }
                Section {
                    Button("Restore Default Toolbar") {
                        model.browserPreferences.toolbarActions = ["import", "lookup", "save", "organize", "artwork", "scripts", "activity"]
                        model.saveBrowserPreferences()
                    }
                }
            }
            .listStyle(.inset)
        }
        .tint(MusicBrainzTheme.purple)
    }

    private func binding(for action: BrowserToolbarAction) -> Binding<Bool> {
        Binding(
            get: { model.browserPreferences.toolbarActions.contains(action.rawValue) },
            set: { visible in
                if visible { model.browserPreferences.toolbarActions.insert(action.rawValue) }
                else { model.browserPreferences.toolbarActions.remove(action.rawValue) }
                model.saveBrowserPreferences()
            }
        )
    }

    private func description(for action: BrowserToolbarAction) -> String {
        switch action {
        case .importFiles: "Add audio to the active library"
        case .lookup: "Find MusicBrainz matches for the selection"
        case .save: "Write pending metadata changes"
        case .organize: "Review file and folder organization"
        case .artwork: "Edit and export embedded artwork"
        case .scripts: "Open tools, scripts, and profiles"
        case .discard: "Revert unsaved changes"
        case .activity: "Review background operations"
        }
    }
}

struct ActivityView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack {
            HStack { Text("Activity").font(.title2); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }.padding()
            if model.isBusy { ProgressView(model.statusMessage, value: model.progress).padding() }
            if model.checkingOperationID != nil {
                Button("Cancel Check") { model.recoveryCheckTask?.cancel() }.controlSize(.small)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                if !model.operationHistory.isEmpty {
                    Section("File Operations") {
                        ForEach(model.operationHistory) { operation in
                            DisclosureGroup {
                                if !operation.message.isEmpty { Text(operation.message).font(.caption).textSelection(.enabled) }
                                HStack {
                                    if operation.kind == .scan || (operation.kind == .importFiles && operation.items.contains { [.failed, .pending, .inProgress].contains($0.state) }) || !model.retryableSaveIDs(operation).isEmpty {
                                        Button(operation.kind == .scan ? "Refresh Again" : "Retry Failed Files") { Task { await model.retryOperation(operation) } }.disabled(model.isBusy)
                                    }
                                    if [.interrupted, .failed].contains(operation.state), [.save, .organize].contains(operation.kind) {
                                        Button("Check Files") { model.startOperationCheck(operation) }.disabled(model.isBusy)
                                    }
                                }.controlSize(.small)
                                ForEach(operation.items) { item in
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(item.source.lastPathComponent).lineLimit(1)
                                            Spacer()
                                            Text(item.state.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                                        }
                                        if !item.message.isEmpty { Text(item.message).font(.caption).textSelection(.enabled) }
                                        HStack {
                                            Button("Source") { NSWorkspace.shared.activateFileViewerSelecting([item.source]) }.help(item.source.path)
                                            if let path = item.destination { Button("Destination") { NSWorkspace.shared.activateFileViewerSelecting([path]) }.help(path.path) }
                                            if let path = item.temporary { Button("Temporary File") { NSWorkspace.shared.activateFileViewerSelecting([path]) }.help(path.path) }
                                        }.buttonStyle(.borderless).controlSize(.small)
                                        if [.failed, .interrupted].contains(operation.state) {
                                            DisclosureGroup("Paths") {
                                                Text("Source: \(item.source.path)")
                                                if let path = item.destination { Text("Destination: \(path.path)") }
                                                if let path = item.temporary { Text("Temporary: \(path.path)") }
                                            }.font(.caption).textSelection(.enabled)
                                        }
                                    }.padding(.vertical, 4)
                                }
                            } label: {
                                HStack {
                                    Text(operation.kind.rawValue)
                                    Text("\(operation.items.count) \(operation.items.count == 1 ? "file" : "files")").foregroundStyle(.secondary)
                                    Spacer()
                                    Text(operation.state.rawValue.capitalized).foregroundStyle(operation.state == .failed ? MusicBrainzTheme.error : (operation.state == .interrupted ? MusicBrainzTheme.orange : .secondary))
                                }.font(.callout)
                            }
                        }
                    }
                }
                Section("Messages") {
                    ForEach(model.activity.reversed()) { entry in
                        VStack(alignment: .leading) {
                            Text(entry.message).textSelection(.enabled)
                            Text("\(entry.date.formatted(date: .omitted, time: .standard)) · \(entry.background ? "Background" : "Foreground")").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                }.padding(.horizontal, 16)
            }
            if let message = model.monitoringMessage { Text(message).font(.caption).padding() }
        }.frame(minWidth: 600, minHeight: 420).tint(MusicBrainzTheme.purple)
    }
}
