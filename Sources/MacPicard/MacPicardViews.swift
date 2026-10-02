import AppKit
import PicardFormats
import PicardFoundation
import PicardMusicBrainz
import SwiftUI
import UniformTypeIdentifiers

struct LibrarySidebar: View {
    @ObservedObject var model: AppModel
    @Binding var isImporting: Bool
    @Binding var isShowingSettings: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Library", systemImage: "music.note.list")
                    .font(.headline)
                Spacer()
                Button {
                    isImporting = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.glass)
                .help("Import audio files or a folder")
                .accessibilityLabel("Import audio")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            if model.albumGroups.isEmpty {
                ContentUnavailableView {
                    Label("No music yet", systemImage: "music.note")
                } description: {
                    Text("Import audio files or drop a folder here to begin.")
                } actions: {
                    Button("Import Audio") { isImporting = true }
                        .buttonStyle(.glassProminent)
                }
                .padding(.horizontal, 12)
            } else {
                List(selection: $model.selectedFileIDs) {
                    ForEach(model.albumGroups) { group in
                        Section {
                            ForEach(group.fileIDs, id: \.self) { id in
                                if let file = model.file(id: id) {
                                    SidebarTrackRow(file: file)
                                        .tag(id)
                                        .contextMenu {
                                            Button("Select Album") { model.selectAlbum(group) }
                                        }
                                }
                            }
                        } header: {
                            Button {
                                model.selectAlbum(group)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(group.title)
                                            .font(.subheadline.weight(.semibold))
                                            .lineLimit(1)
                                        Text(group.subtitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Select album \(group.title)")
                        }
                    }
                }
                .listStyle(.sidebar)
            }

            Divider()
            HStack {
                Label("\(model.files.count) files", systemImage: "internaldrive")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    isShowingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.glass)
                .help("Open MacPicard settings")
                .accessibilityLabel("Settings")
            }
            .padding(10)
        }
        .frame(minWidth: 260)
        .background(.thinMaterial)
        .onChange(of: model.selectedFileIDs) { _, ids in
            guard let firstID = ids.first,
                  let group = model.albumGroups.first(where: { $0.fileIDs.contains(firstID) }) else {
                return
            }
            if model.selectedAlbumID != group.id {
                model.selectedAlbumID = group.id
            }
        }
    }
}

private struct SidebarTrackRow: View {
    let file: AudioFile

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: stateSymbol)
                .foregroundStyle(stateColor)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.metadata.firstValue(for: "title") ?? file.url.deletingPathExtension().lastPathComponent)
                    .lineLimit(1)
                Text(file.url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(file.metadata.firstValue(for: "title") ?? file.url.lastPathComponent)
        .accessibilityValue(file.state.rawValue)
    }

    private var stateSymbol: String {
        switch file.state {
        case .changed: return "pencil.circle.fill"
        case .saved: return "checkmark.circle.fill"
        case .failed, .unsupported: return "exclamationmark.circle.fill"
        case .saving, .loading: return "arrow.triangle.2.circlepath"
        default: return "music.note"
        }
    }

    private var stateColor: Color {
        switch file.state {
        case .changed: return .orange
        case .saved: return .green
        case .failed, .unsupported: return .red
        default: return .secondary
        }
    }
}

struct WorkspaceView: View {
    @ObservedObject var model: AppModel
    @Binding var isImporting: Bool
    @Binding var isChoosingDestination: Bool
    @Binding var isShowingLookup: Bool
    @Binding var isShowingScript: Bool
    @Binding var isDropTargeted: Bool

    var body: some View {
        VStack(spacing: 0) {
            ActionBar(
                model: model,
                isImporting: $isImporting,
                isChoosingDestination: $isChoosingDestination,
                isShowingLookup: $isShowingLookup,
                isShowingScript: $isShowingScript
            )

            Divider()

            if model.files.isEmpty {
                EmptyLibraryView { isImporting = true }
            } else {
                AlbumWorkspace(model: model)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            model.importDroppedProviders(providers)
            return true
        }
        .overlay(alignment: .top) {
            if isDropTargeted {
                Text("Drop audio files or folders to import")
                    .font(.headline)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .glassEffect(.regular.tint(.accentColor.opacity(0.25)).interactive(), in: .capsule)
                    .padding(.top, 12)
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct ActionBar: View {
    @ObservedObject var model: AppModel
    @Binding var isImporting: Bool
    @Binding var isChoosingDestination: Bool
    @Binding var isShowingLookup: Bool
    @Binding var isShowingScript: Bool

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 8) {
                GlassActionButton("Import", systemImage: "plus", prominent: true) {
                    isImporting = true
                }
                GlassActionButton("Look Up", systemImage: "magnifyingglass") {
                    isShowingLookup = true
                    Task { await model.lookup() }
                }
                .disabled(model.selectedFiles.isEmpty)
                GlassActionButton("Cover Art", systemImage: "photo.on.rectangle") {
                    Task { await model.downloadCoverArt() }
                }
                .disabled(model.selectedRelease == nil)
                GlassActionButton("Script", systemImage: "chevron.left.forwardslash.chevron.right") {
                    isShowingScript = true
                }
                GlassActionButton("Save", systemImage: "square.and.arrow.down") {
                    Task { await model.saveSelected() }
                }
                .disabled(!model.hasUnsavedChanges || model.selectedFiles.isEmpty)
                GlassActionButton("Organize", systemImage: "folder.badge.gearshape") {
                    if model.destinationDirectory == nil {
                        isChoosingDestination = true
                    } else {
                        Task { await model.organizeSelected() }
                    }
                }
                .disabled(model.selectedFiles.isEmpty)

                Spacer(minLength: 8)

                if let progress = model.progress {
                    ProgressView(value: progress)
                        .frame(width: 90)
                        .accessibilityLabel("Operation progress")
                }
                if model.isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Working")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct GlassActionButton: View {
    let title: String
    let systemImage: String
    let prominent: Bool
    let action: () -> Void

    init(_ title: String, systemImage: String, prominent: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.prominent = prominent
        self.action = action
    }

    var body: some View {
        Group {
            if prominent {
                Button(action: action) {
                    Label(title, systemImage: systemImage)
                }
                .buttonStyle(.glassProminent)
            } else {
                Button(action: action) {
                    Label(title, systemImage: systemImage)
                }
                .buttonStyle(.glass)
            }
        }
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct EmptyLibraryView: View {
    let importAction: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Your library is empty", systemImage: "music.note.list")
        } description: {
            Text("Import audio files or drop a folder to edit metadata, identify releases, and save changes.")
        } actions: {
            Button("Import Audio") { importAction() }
                .buttonStyle(.glassProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct AlbumWorkspace: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AlbumHeader(model: model)
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 12)

            HSplitView {
                TrackListView(model: model)
                    .frame(minWidth: 380)
                MetadataInspector(model: model)
                    .frame(minWidth: 340, idealWidth: 380)
            }
        }
    }
}

private struct AlbumHeader: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 16) {
            ArtworkThumbnail(artwork: model.primarySelectedFile?.artwork.first(of: .front))
                .frame(width: 88, height: 88)
                .clipShape(.rect(cornerRadius: 14))
                .glassEffect(.clear, in: .rect(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 5) {
                Text(model.primarySelectedFile?.metadata.firstValue(for: "album") ?? "Unmatched files")
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                Text(model.primarySelectedFile?.metadata.firstValue(for: "albumartist")
                    ?? model.primarySelectedFile?.metadata.firstValue(for: "artist")
                    ?? "Unknown artist")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 10) {
                    Label("\(model.visibleFiles.count) tracks", systemImage: "music.note")
                    if model.hasUnsavedChanges {
                        Label("Unsaved changes", systemImage: "pencil.circle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                Text(model.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: .rect(cornerRadius: 18))
    }
}

private struct TrackListView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Tracks")
                    .font(.headline)
                Spacer()
                Text("\(model.selectedFileIDs.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            List {
                ForEach(Array(model.visibleFiles.enumerated()), id: \.element.id) { offset, file in
                    TrackDetailRow(file: file, position: offset + 1, isSelected: model.selectedFileIDs.contains(file.id))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.selectedFileIDs = [file.id]
                        }
                        .contextMenu {
                            Button("Select Track") { model.selectedFileIDs = [file.id] }
                            Button("Select Album") {
                                if let group = model.albumGroups.first(where: { $0.fileIDs.contains(file.id) }) {
                                    model.selectAlbum(group)
                                }
                            }
                        }
                }
            }
            .listStyle(.inset)
        }
        .background(.thinMaterial)
    }
}

private struct TrackDetailRow: View {
    let file: AudioFile
    let position: Int
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(file.metadata.firstValue(for: "tracknumber") ?? String(format: "%02d", position))
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
            VStack(alignment: .leading, spacing: 3) {
                Text(file.metadata.firstValue(for: "title") ?? file.url.deletingPathExtension().lastPathComponent)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .lineLimit(1)
                Text(file.metadata.firstValue(for: "artist") ?? file.url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if file.isModified {
                Image(systemName: "pencil.circle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Unsaved changes")
            }
            Text(file.state.rawValue.capitalized)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(file.metadata.firstValue(for: "title") ?? file.url.lastPathComponent)
        .accessibilityValue(file.state.rawValue)
    }
}

private struct MetadataInspector: View {
    @ObservedObject var model: AppModel
    private let fields = [
        ("Title", "title"),
        ("Artist", "artist"),
        ("Album", "album"),
        ("Album Artist", "albumartist"),
        ("Date", "date"),
        ("Genre", "genre"),
        ("Track Number", "tracknumber"),
        ("Disc Number", "discnumber"),
        ("Barcode", "barcode")
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Metadata")
                    .font(.headline)
                if model.selectedFiles.isEmpty {
                    Text("Select a track or album to edit metadata.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Changes apply to all selected tracks.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(fields, id: \.1) { field in
                        MetadataField(
                            label: field.0,
                            value: Binding(
                                get: { model.metadataValue(field.1) },
                                set: { model.setMetadata(field.1, value: $0) }
                            )
                        )
                    }
                    ArtworkInspector(model: model)
                }
            }
            .padding(18)
        }
        .background(.regularMaterial)
    }
}

private struct MetadataField: View {
    let label: String
    @Binding var value: String

    var body: some View {
        TextField(label, text: $value)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel(label)
    }
}

private struct ArtworkInspector: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Artwork")
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 12) {
                ArtworkThumbnail(artwork: model.primarySelectedFile?.artwork.first(of: .front))
                    .frame(width: 96, height: 96)
                VStack(alignment: .leading, spacing: 4) {
                    if let artwork = model.primarySelectedFile?.artwork.first(of: .front) {
                        Text("Front cover")
                        Text("\(artwork.width ?? 0) × \(artwork.height ?? 0)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No front cover")
                            .foregroundStyle(.secondary)
                        Text("Use Cover Art after selecting a MusicBrainz release.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.top, 8)
    }
}

struct ArtworkThumbnail: View {
    let artwork: Artwork?

    var body: some View {
        Group {
            if let data = artwork?.data, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.secondary.opacity(0.12)
                    Image(systemName: "music.note.square")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .clipped()
        .accessibilityLabel(artwork == nil ? "No artwork" : "Album artwork")
    }
}

struct LookupView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedResultID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("MusicBrainz Lookup", systemImage: "magnifyingglass")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(18)
            Divider()

            if model.isWorking && model.matchResults.isEmpty {
                ProgressView("Searching MusicBrainz…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.matchResults.isEmpty {
                ContentUnavailableView("No matches", systemImage: "magnifyingglass", description: Text("Look up an album from the main toolbar."))
            } else {
                List(model.matchResults) { result in
                    Button {
                        selectedResultID = result.id
                        Task { await model.chooseMatch(result) }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: result.id == selectedResultID ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(result.id == selectedResultID ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(result.release.title)
                                    .font(.body.weight(.medium))
                                Text("\(result.release.artistCredit) · \(result.release.date ?? "Date unknown")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("Score \(result.score.total, format: .percent.precision(.fractionLength(0))) · \(result.decision.rawValue.capitalized)")
                                    .font(.caption2)
                                    .foregroundStyle(result.decision == .rejected ? Color.secondary : Color.accentColor)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 3) {
                                Text("\(result.release.trackCount) tracks")
                                Text(result.release.country ?? "Country unknown")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 5)
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Text(model.selectedRelease.map { "Selected: \($0.title)" } ?? "Select a release to load full metadata.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Apply Match") { model.applySelectedRelease(); dismiss() }
                    .buttonStyle(.glassProminent)
                    .disabled(model.selectedRelease == nil)
            }
            .padding(14)
        }
    }
}

struct ScriptView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Script", systemImage: "chevron.left.forwardslash.chevron.right")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(18)
            Divider()
            TextEditor(text: $model.scriptSource)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(12)
                .background(.thinMaterial)
                .accessibilityLabel("Picard script source")
            Divider()
            HStack {
                Text(model.scriptOutput.isEmpty ? "Output will appear here." : model.scriptOutput)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button("Preview") { model.runScript(applying: false) }
                Button("Apply") { model.runScript(applying: true) }
                    .buttonStyle(.glassProminent)
            }
            .padding(14)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Settings", systemImage: "gearshape")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            if let snapshot = model.snapshot {
                Form {
                    Section("MusicBrainz") {
                        LabeledContent("Release country", value: snapshot.configuration.preferredReleaseCountry)
                        LabeledContent("User agent", value: snapshot.configuration.requestUserAgent)
                    }
                    Section("Files") {
                        LabeledContent("Supported formats", value: AudioFormat.allCases.map(\.displayName).joined(separator: ", "))
                        LabeledContent("Application Support", value: snapshot.paths.applicationSupportDirectory.path)
                        LabeledContent("Session", value: snapshot.paths.sessionFile.lastPathComponent)
                    }
                    Section("Liquid Glass") {
                        Text("Controls use native macOS 26 Liquid Glass. Content remains on standard materials for legibility.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
            }
        }
        .padding(20)
    }
}
