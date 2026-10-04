import PicardFoundation
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
    var toolbarActions: Set<String> = ["lookup", "artwork", "script", "save", "discard"]
}

struct ActivityEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let message: String
    let background: Bool
}

extension AppModel {
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
    var body: some View {
        Table(rows, selection: Binding(get: { model.selectedFileIDs }, set: { model.selectionChanged($0) }), sortOrder: $sortOrder,
              columnCustomization: $model.browserPreferences.columns) {
            TableColumn("Title", value: \.title) { row in
                HStack {
                    if model.playback.currentTrack?.fileID == row.id { Image(systemName: "speaker.wave.2.fill").accessibilityLabel("Now playing") }
                    Text(row.title).lineLimit(1)
                }
            }.width(min: 160, ideal: 230).customizationID("title").disabledCustomizationBehavior(.visibility)
            TableColumn("Artist", value: \.artist).customizationID("artist")
            TableColumn("Album", value: \.album).customizationID("album")
            TableColumn("#", value: \.number) { Text($0.number == 0 ? "—" : String($0.number)) }.width(40).customizationID("number")
            TableColumn("Time", value: \.duration) { Text($0.duration == 0 ? "—" : String(format: "%d:%02d", $0.duration / 60_000, $0.duration / 1_000 % 60)) }.width(65).customizationID("duration")
            TableColumn("Format", value: \.format).width(65).customizationID("format")
            TableColumn("State", value: \.state).width(85).customizationID("state")
            TableColumn("File", value: \.filename).customizationID("filename")
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
}

struct ActivityView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack {
            HStack { Text("Activity").font(.title2); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }.padding()
            if model.isBusy { ProgressView(model.statusMessage, value: model.progress).padding() }
            List(model.activity.reversed()) { entry in
                VStack(alignment: .leading) {
                    Text(entry.message).textSelection(.enabled)
                    Text("\(entry.date.formatted(date: .omitted, time: .standard)) · \(entry.background ? "Background" : "Foreground")").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let message = model.monitoringMessage { Text(message).font(.caption).padding() }
        }.frame(minWidth: 600, minHeight: 420)
    }
}
