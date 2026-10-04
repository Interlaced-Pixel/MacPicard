import AppKit
import PicardFormats
import PicardFoundation
import PicardMusicBrainz
import SwiftUI
import UniformTypeIdentifiers


struct SidebarTrackRow: View {
    let file: AudioFile
    let isSelected: Bool
    @ObservedObject var playback: PlaybackController

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: playback.currentTrack?.fileID == file.id && playback.state != .idle ? playback.indicatorSymbol : stateSymbol)
                .foregroundStyle(playback.currentTrack?.fileID == file.id ? Color.accentColor : stateColor)
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .padding(.leading, 26)
        .background(
            isSelected ? Color.accentColor.opacity(0.16) : Color.clear,
            in: .rect(cornerRadius: 8)
        )
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
    @Binding var isShowingLookup: Bool
    @Binding var isShowingScript: Bool
    @Binding var isDropTargeted: Bool
    @ObservedObject var presentation: AppPresentation

    var body: some View {
        VStack(spacing: 0) {
            ActionBar(
                model: model,
                isImporting: $isImporting,
                isShowingLookup: $isShowingLookup,
                isShowingScript: $isShowingScript,
                presentation: presentation
            )

            Divider()

            if model.files.isEmpty {
                EmptyLibraryView(
                    importAction: { isImporting = true },
                    addLibraryAction: { presentation.isAddingLibrary = true }
                )
            } else {
                AlbumWorkspace(model: model, presentation: presentation)
            }
            PlaybackBar(playback: model.playback, presentation: presentation)
            WorkspaceStatusBar(model: model, presentation: presentation)
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            model.importDroppedProviders(providers)
            return true
        }
        .overlay(alignment: .top) {
            if isDropTargeted {
                Text(model.activeWorkspace?.kind == .library ? "Drop to copy and organize in this library" : "Drop audio files or folders to import")
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
    @Binding var isShowingLookup: Bool
    @Binding var isShowingScript: Bool
    @ObservedObject var presentation: AppPresentation
    @State private var isCompact = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 8) {
                Button { presentation.showsSidebar.toggle() } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(.glass)
                .help(presentation.showsSidebar ? "Hide sidebar" : "Show sidebar")
                GlassActionButton("Import", systemImage: "plus", prominent: true) {
                    isImporting = true
                }
                .disabled(model.isBusy)
                .help(model.activeWorkspace?.kind == .library
                      ? "Copy audio into the library and organize by artist and album; keep originals."
                      : "Import audio references into this session without moving files.")
                if model.browserPreferences.toolbarActions.contains("lookup") && !isCompact {
                GlassActionButton("Look Up", systemImage: "magnifyingglass", compact: isCompact) {
                    presentation.showsMatchComparison = true
                    Task { await model.lookup() }
                }
                .disabled(!model.canLookupSelection)
                }
                if model.browserPreferences.toolbarActions.contains("artwork") && !isCompact {
                GlassActionButton("Cover Art", systemImage: "photo.on.rectangle", compact: isCompact) {
                    presentation.isShowingArtwork = true
                }
                .disabled(!model.canEditSelection)
                }
                if model.browserPreferences.toolbarActions.contains("script") && !isCompact {
                GlassActionButton("Script", systemImage: "chevron.left.forwardslash.chevron.right", compact: isCompact) {
                    isShowingScript = true
                }
                .disabled(!model.canEditSelection)
                }
                GlassActionButton("Save", systemImage: "square.and.arrow.down", compact: isCompact) {
                    Task { await model.saveSelected() }
                }
                .disabled(!model.canPerform(.save))
                if model.browserPreferences.toolbarActions.contains("discard") && !isCompact {
                GlassActionButton("Discard", systemImage: "arrow.uturn.backward", compact: isCompact) {
                    presentation.requestDiscard(model.selectedFiles, workspaceID: model.activeWorkspaceID)
                }
                .disabled(!model.canDiscardChanges(model.selectedFileIDs))
                .help("Discard pending tags and artwork; keep audio files unchanged.")
                }
                Menu {
                    Button("Organize Selected Files…") {
                        model.requestOrganizationReview()
                        presentation.isShowingOrganization = true
                    }.disabled(!model.canPerform(.organize))
                    if model.activeWorkspace?.kind == .library {
                        Button("Organize Entire Library…") {
                        model.requestOrganizationReview(entireLibrary: true)
                        presentation.isShowingOrganization = true
                        }.disabled(!model.canPerform(.organize, scope: .library))
                    }
                } label: {
                    Label("Organize", systemImage: "folder.badge.gearshape")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.glass)
                .help("Choose selected files or the entire library, then review paths before moving.")
                Menu {
                    Button("Look Up…") { presentation.showsMatchComparison = true; Task { await model.lookup() } }.disabled(!model.canLookupSelection)
                    Button("Scan Selected Audio…") { model.startFingerprintScan(); presentation.isShowingFingerprints = true }.disabled(model.isBusy || model.selectedFiles.isEmpty)
                    Button("Fingerprint Results…") { presentation.isShowingFingerprints = true }
                    Button("Manage Artwork…") { presentation.isShowingArtwork = true }.disabled(!model.canEditSelection)
                    Button("Edit Script…") { isShowingScript = true }.disabled(!model.canEditSelection)
                    Button("Discard Selected Changes…") { presentation.requestDiscard(model.selectedFiles, workspaceID: model.activeWorkspaceID) }.disabled(!model.canPerform(.discard))
                    Button("All Tags & Changes…") { presentation.isShowingMetadataEditor = true }.disabled(!model.canEditSelection)
                    Button("Activity…") { presentation.isShowingActivity = true }
                    Divider()
                    Menu("Toolbar Items") {
                        ForEach(["lookup", "artwork", "script", "discard"], id: \.self) { key in
                            Toggle(key.capitalized, isOn: Binding(get: { model.browserPreferences.toolbarActions.contains(key) }, set: {
                                if $0 { model.browserPreferences.toolbarActions.insert(key) } else { model.browserPreferences.toolbarActions.remove(key) }
                                model.saveBrowserPreferences()
                            }))
                        }
                    }
                } label: { Image(systemName: "ellipsis") }.buttonStyle(.glass).accessibilityLabel("More actions and toolbar customization")

                Button { presentation.showsInspector.toggle() } label: {
                    Image(systemName: "sidebar.right")
                }
                .buttonStyle(.glass)
                .help(presentation.showsInspector ? "Hide metadata inspector" : "Show metadata inspector")

                Spacer(minLength: 8)

                if !model.selectedFiles.isEmpty {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(model.selectedFiles.count) selected")
                            .font(.caption.weight(.medium))
                        Text(model.selectedFormatSummary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if model.selectedModifiedCount > 0 {
                            Text("\(model.selectedModifiedCount) pending save")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Selection")
                    .accessibilityValue("\(model.selectedFiles.count) selected, \(model.selectedFormatSummary)")

                    Button {
                        model.clearSelection()
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.glass)
                    .help("Clear selection")
                    .accessibilityLabel("Clear selection")
                }

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
        }
        .scrollClipDisabled()
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.bar)
        .onGeometryChange(for: Bool.self) { geometry in geometry.size.width < 1_000 } action: {
            isCompact = $0
        }
    }
}

private struct WorkspaceStatusBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var presentation: AppPresentation

    var body: some View {
        HStack(spacing: 8) {
            if model.isBusy {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: model.errorMessage == nil ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(model.errorMessage == nil ? Color.secondary : .orange)
            }
            Text(model.errorMessage ?? model.statusMessage)
                .lineLimit(2)
                .help(model.errorMessage ?? model.statusMessage)
            Spacer(minLength: 8)
            Button { presentation.isShowingActivity = true } label: { Label("Activity", systemImage: "list.bullet.rectangle") }.buttonStyle(.borderless)
            if let message = model.monitoringMessage {
                Label("Monitor", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange).help(message)
            }
            if model.isScanningLibrary {
                Button("Cancel") { model.cancelLibraryRefresh() }
                    .buttonStyle(.borderless)
            }
            if let progress = model.progress {
                ProgressView(value: progress).frame(width: 90)
            }
            if let workspace = model.activeWorkspace {
                Text(workspace.kind == .library ? "Folder library" : "Session autosaved")
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct GlassActionButton: View {
    let title: String
    let systemImage: String
    let prominent: Bool
    let compact: Bool
    let action: () -> Void

    init(_ title: String, systemImage: String, prominent: Bool = false, compact: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.prominent = prominent
        self.compact = compact
        self.action = action
    }

    var body: some View {
        Group {
            if prominent {
                Button(action: action) {
                    buttonLabel
                }
                .buttonStyle(.glassProminent)
            } else {
                Button(action: action) {
                    buttonLabel
                }
                .buttonStyle(.glass)
            }
        }
        .help(title)
        .accessibilityLabel(title)
    }

    @ViewBuilder private var buttonLabel: some View {
        if compact { Image(systemName: systemImage) }
        else { Label(title, systemImage: systemImage) }
    }
}

private struct EmptyLibraryView: View {
    let importAction: () -> Void
    let addLibraryAction: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Make room for your music", systemImage: "music.note.list")
        } description: {
            Text("Link a music folder to manage it over time, or import files into this session for a tagging task.")
        } actions: {
            Button("Add Music Library…") { addLibraryAction() }
                .buttonStyle(.glassProminent)
            Button("Import Audio…") { importAction() }.buttonStyle(.glass)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct AlbumWorkspace: View {
    @ObservedObject var model: AppModel
    @ObservedObject var presentation: AppPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AlbumHeader(model: model)
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 12)

            HSplitView {
                if presentation.showsMatchComparison {
                    LookupView(model: model, embedded: true, close: { presentation.showsMatchComparison = false })
                        .frame(minWidth: 800)
                } else {
                TrackListView(model: model, presentation: presentation)
                    .frame(minWidth: 440, idealWidth: 560)
                if presentation.showsInspector {
                    MetadataInspector(model: model, presentation: presentation)
                        .frame(minWidth: 390, idealWidth: 460)
                }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct AlbumHeader: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 16) {
            WorkspaceArtwork(model: model)
                .frame(width: 88, height: 88)
                .clipShape(.rect(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 5) {
                Text(model.browserTitle)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                Text(model.browserSubtitle)
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
                    .frame(width: 300, alignment: .trailing)
                    .fixedSize(horizontal: false, vertical: true)
                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                        .frame(width: 300, alignment: .trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .layoutPriority(1)
        }
        .padding(12)
        .background(.regularMaterial, in: .rect(cornerRadius: 18))
    }
}

private struct WorkspaceArtwork: View {
    @ObservedObject var model: AppModel

    private var covers: [Artwork] {
        model.browserAlbumGroups.prefix(4).compactMap { group in
            group.fileIDs.lazy.compactMap { model.file(id: $0)?.artwork.first(of: .front) }.first
        }
    }

    var body: some View {
        if !model.browsingAllTracks, let group = model.displayedAlbum {
            ArtworkThumbnail(artwork: group.fileIDs.lazy.compactMap {
                model.file(id: $0)?.artwork.first(of: .front)
            }.first)
        } else if !covers.isEmpty {
            GeometryReader { geometry in
                let artwork = covers
                let side = (geometry.size.width - 2) / 2
                VStack(spacing: 2) {
                    ForEach(0..<2) { row in
                        HStack(spacing: 2) {
                            ForEach(0..<2) { column in
                                ArtworkThumbnail(artwork: artwork[(row * 2 + column) % artwork.count])
                                    .frame(width: side, height: side)
                            }
                        }
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Collection artwork")
        } else {
            ZStack {
                Color.accentColor.opacity(0.12)
                Image(systemName: "music.note.list")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(.tint)
            }
            .accessibilityLabel("Music collection")
        }
    }
}

private struct TrackListView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var presentation: AppPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tracks")
                        .font(.headline)
                    Text("\(model.visibleFiles.count) visible · \(model.selectedFiles.count) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 6) {
                    Button("Select All") { model.selectAllVisible() }
                        .buttonStyle(.glass)
                        .disabled(model.visibleFiles.isEmpty)
                    Button("Clear") { model.clearSelection() }
                        .buttonStyle(.glass)
                        .disabled(model.selectedFiles.isEmpty)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if model.visibleFiles.isEmpty {
                ContentUnavailableView("No matching tracks", systemImage: "magnifyingglass",
                                       description: Text("Try another search or filter."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
            CollectionTrackTable(model: model, presentation: presentation)
            }
        }
        .background(.thinMaterial)
    }
}

private struct TrackDetailRow: View {
    let file: AudioFile
    let position: Int
    let isSelected: Bool
    @ObservedObject var playback: PlaybackController

    var body: some View {
        HStack(spacing: 12) {
            Text(file.metadata.firstValue(for: "tracknumber") ?? String(format: "%02d", position))
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if playback.currentTrack?.fileID == file.id && playback.state != .idle {
                        Image(systemName: playback.indicatorSymbol)
                            .foregroundStyle(.tint)
                            .font(.caption)
                            .accessibilityLabel(playback.statusDescription)
                    }
                    Text(file.metadata.firstValue(for: "title") ?? file.url.deletingPathExtension().lastPathComponent)
                        .fontWeight(isSelected ? .semibold : .regular)
                        .lineLimit(1)
                    if file.isModified {
                        Image(systemName: "pencil.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .accessibilityLabel("Unsaved changes")
                    }
                }
                Text(file.metadata.firstValue(for: "artist") ?? file.url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            TrackStateBadge(state: file.state)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 4)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(file.metadata.firstValue(for: "title") ?? file.url.lastPathComponent)
        .accessibilityValue(file.state.rawValue)
    }
}

private struct TrackStateBadge: View {
    let state: AudioFileState

    var body: some View {
        Text(label)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12), in: .capsule)
            .accessibilityLabel("Track state")
            .accessibilityValue(label)
    }

    private var label: String {
        state.rawValue.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).capitalized
    }

    private var tint: Color {
        switch state {
        case .changed: return .orange
        case .saved: return .green
        case .failed, .unsupported: return .red
        case .saving, .loading: return .blue
        default: return .secondary
        }
    }
}

private struct MetadataInspector: View {
    @ObservedObject var model: AppModel
    @ObservedObject var presentation: AppPresentation
    private let identityFields = [
        ("Title", "title"),
        ("Artist", "artist"),
        ("Album", "album"),
        ("Album Artist", "albumartist")
    ]
    private let releaseFields = [
        ("Date", "date"),
        ("Genre", "genre"),
        ("Barcode", "barcode")
    ]
    private let numberingFields = [
        ("Track Number", "tracknumber"),
        ("Disc Number", "discnumber")
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
                    Text("Editing \(model.selectedFiles.count) selected \(model.selectedFiles.count == 1 ? "track" : "tracks") · \(model.selectedFormatSummary)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("All Tags & Changes…", systemImage: "tablecells") { presentation.isShowingMetadataEditor = true }
                        .buttonStyle(.glass).disabled(!model.canEditSelection)
                    MetadataFieldGroup(title: "Identity", fields: identityFields, model: model)
                    MetadataFieldGroup(title: "Release", fields: releaseFields, model: model)
                    MetadataFieldGroup(title: "Numbering", fields: numberingFields, model: model)
                    ArtworkInspector(model: model, presentation: presentation)
                    if let file = model.primarySelectedFile {
                        VStack(alignment: .leading, spacing: 4) {
                            AudioFileDetailsView(file: file)
                            Button("Reveal in Finder") { model.revealSelection() }
                        }.padding(.top, 10)
                    }
                }
            }
            .padding(18)
        }
        .background(.regularMaterial)
    }
}

private struct MetadataFieldGroup: View {
    let title: String
    let fields: [(String, String)]
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            ForEach(fields, id: \.1) { field in
                MetadataField(
                    label: field.0,
                    isMixed: model.metadataValueIsMixed(field.1),
                    value: Binding(
                        get: { model.metadataValue(field.1) },
                        set: { model.setMetadata(field.1, value: $0) }
                    )
                )
            }
        }
        .padding(.top, 4)
        .disabled(!model.canEditSelection)
    }
}

private struct MetadataField: View {
    let label: String
    let isMixed: Bool
    @Binding var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            TextField(isMixed ? "Multiple values" : "Enter \(label.lowercased())", text: $value)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(label)
        }
    }
}

private struct ArtworkInspector: View {
    @ObservedObject var model: AppModel
    @ObservedObject var presentation: AppPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Artwork")
                .font(.subheadline.weight(.semibold))
            Button("Manage Artwork…", systemImage: "photo.on.rectangle.angled") { presentation.isShowingArtwork = true }
                .buttonStyle(.glass).disabled(!model.canEditSelection)
            Text("\(model.primarySelectedFile?.artwork.images.count ?? 0) images in preview file").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                ArtworkThumbnail(artwork: model.primarySelectedFile?.artwork.first(of: .front))
                    .frame(width: 96, height: 96)
                VStack(alignment: .leading, spacing: 4) {
                    if let artwork = model.primarySelectedFile?.artwork.first(of: .front) {
                        Text("Front cover")
                        if let width = artwork.width, let height = artwork.height {
                            Text("\(width) × \(height)")
                        }
                        Text(sourceLabel(artwork.source))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No front cover")
                            .foregroundStyle(.secondary)
                        Text("Import images or choose archive artwork in Manage Artwork.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.top, 8)
    }

    private func sourceLabel(_ source: ArtworkSource) -> String {
        switch source {
        case .embedded: return "Embedded"
        case .localFile: return "Local file"
        case .remote: return "Remote"
        case .generated: return "Generated"
        }
    }
}

struct ArtworkThumbnail: View {
    let artwork: Artwork?

    var body: some View {
        ArtworkPreview(image: artwork)
        .clipped()
        .accessibilityLabel(artwork == nil ? "No artwork" : "Album artwork")
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
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.scriptOutput.isEmpty ? "Preview output" : model.scriptOutput)
                    if !model.selectedFiles.isEmpty {
                        Text("Applies to \(model.selectedFiles.count) selected \(model.selectedFiles.count == 1 ? "track" : "tracks")")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button("Preview") { model.runScript(applying: false) }
                    .disabled(model.selectedFiles.isEmpty)
                Button("Apply") { model.runScript(applying: true) }
                    .buttonStyle(.glassProminent)
                    .disabled(model.selectedFiles.isEmpty)
            }
            .padding(14)
        }
    }
}
