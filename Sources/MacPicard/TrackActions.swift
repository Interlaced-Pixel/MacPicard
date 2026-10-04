import AppKit
import PicardFoundation
import SwiftUI

extension AppModel {
    func album(containing id: UUID) -> AlbumGroup? { albumGroups.first { $0.fileIDs.contains(id) } }

    func contextFileIDs(for id: UUID) -> Set<UUID> {
        selectedFileIDs.contains(id) ? selectedFileIDs : [id]
    }

    func contextFiles(_ ids: Set<UUID>) -> [AudioFile] {
        orderedAlbumGroups.flatMap(\.fileIDs).filter { ids.contains($0) }.compactMap { file(id: $0) }
    }

    func canEdit(_ ids: Set<UUID>) -> Bool {
        let targets = contextFiles(ids)
        return !isBusy && !targets.isEmpty && targets.allSatisfy { [.ready, .changed, .saved].contains($0.state) }
    }

    func canPlay(_ file: AudioFile) -> Bool {
        ![.removed, .unsupported, .loading, .saving].contains(file.state)
            && FileManager.default.isReadableFile(atPath: file.url.path)
    }

    func playTrack(_ id: UUID) {
        guard let file = file(id: id), canPlay(file) else { return }
        // A track starts at the clicked song, then continues in its album's numeric order.
        let albumFiles = album(containing: id)?.fileIDs.compactMap { self.file(id: $0) } ?? [file]
        playback.play(albumFiles.filter { canPlay($0) }.map(PlaybackTrack.init), startingAt: id)
    }

    func playAlbum(_ group: AlbumGroup) {
        playback.play(group.fileIDs.compactMap { file(id: $0) }.filter { canPlay($0) }.map(PlaybackTrack.init))
    }

    func enqueueTracks(_ ids: Set<UUID>, next: Bool) {
        playback.enqueue(contextFiles(ids).filter { canPlay($0) }.map(PlaybackTrack.init), next: next)
    }

    func copyFilePaths(_ ids: Set<UUID>) {
        let paths = contextFiles(ids).map(\.url.path).joined(separator: "\n")
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths, forType: .string)
    }

    func canLookUp(_ ids: Set<UUID>) -> Bool {
        canEdit(ids) && albumGroups.contains { ids.isSubset(of: Set($0.fileIDs)) }
    }

    func canGetArtwork(_ ids: Set<UUID>) -> Bool {
        guard canEdit(ids) else { return false }
        if ids == selectedFileIDs { return canDownloadCoverArt }
        let releases = Set(contextFiles(ids).map { $0.metadata.firstValue(for: "musicbrainz_albumid") ?? "" })
        return releases.count == 1 && releases.first?.isEmpty == false
    }
}

/// Both lists use the same actions. Playback keeps the clicked song as its anchor;
/// editing actions retain a multi-selection only when that anchor is selected.
struct TrackContextMenu: View {
    @ObservedObject var model: AppModel
    @ObservedObject var presentation: AppPresentation
    @ObservedObject var playback: PlaybackController
    let fileID: UUID

    init(model: AppModel, presentation: AppPresentation, fileID: UUID) {
        self.model = model; self.presentation = presentation; self.fileID = fileID
        playback = model.playback
    }

    var body: some View {
        if let file = model.file(id: fileID) {
            let ids = model.contextFileIDs(for: fileID)
            let targets = model.contextFiles(ids)
            Button("Play", systemImage: "play.fill") { model.playTrack(fileID) }
                .disabled(!model.canPlay(file))
            if playback.currentTrack?.fileID == fileID {
                Button(playback.transportIsActive ? "Pause" : "Resume", systemImage: playback.transportIsActive ? "pause.fill" : "play.fill") {
                    playback.togglePlayPause()
                }
            }
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                model.enqueueTracks(ids, next: true)
            }.disabled(!targets.contains(where: model.canPlay))
            Button("Add to Queue", systemImage: "text.badge.plus") { model.enqueueTracks(ids, next: false) }
                .disabled(!targets.contains(where: model.canPlay))
            if let album = model.album(containing: fileID) {
                Button("Play Album", systemImage: "play.square.stack") { model.playAlbum(album) }
                    .disabled(!album.fileIDs.compactMap { model.file(id: $0) }.contains(where: model.canPlay))
            }
            Divider()
            MetadataContextActions(model: model, presentation: presentation, ids: ids)
            Divider()
            Button("Select This Track", systemImage: "checkmark.circle") { model.selectionChanged([fileID]) }
            if let album = model.album(containing: fileID) {
                Button("Select Album", systemImage: "rectangle.stack") { model.selectAlbum(album) }
            }
            Button(targets.count > 1 ? "Reveal Selected Files in Finder" : "Reveal in Finder", systemImage: "folder") {
                model.revealFiles(targets)
            }
            Button(targets.count > 1 ? "Copy File Paths" : "Copy File Path", systemImage: "doc.on.doc") {
                model.copyFilePaths(ids)
            }
            Divider()
            LibraryRemovalActions(model: model, presentation: presentation, ids: ids)
        }
    }
}

struct AlbumContextMenu: View {
    @ObservedObject var model: AppModel
    @ObservedObject var presentation: AppPresentation
    let group: AppModel.AlbumGroup

    var body: some View {
        let ids = Set(group.fileIDs).intersection(model.matchingFileIDs)
        let targets = model.contextFiles(ids)
        Button("Play Album", systemImage: "play.fill") { model.playAlbum(group) }
            .disabled(!group.fileIDs.compactMap { model.file(id: $0) }.contains(where: model.canPlay))
        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { model.enqueueTracks(ids, next: true) }
            .disabled(!targets.contains(where: model.canPlay))
        Button("Add to Queue", systemImage: "text.badge.plus") { model.enqueueTracks(ids, next: false) }
            .disabled(!targets.contains(where: model.canPlay))
        Divider()
        Button("Open Album", systemImage: "rectangle.stack") { model.selectAlbum(group) }
        Button(model.expandedAlbumIDs.contains(group.id) ? "Collapse Tracks" : "Expand Tracks", systemImage: "list.bullet") {
            model.toggleAlbumExpansion(group.id)
        }
        Divider()
        MetadataContextActions(model: model, presentation: presentation, ids: ids)
        Divider()
        Button("Reveal Album Files in Finder", systemImage: "folder") { model.revealFiles(targets) }
        Button("Copy File Paths", systemImage: "doc.on.doc") { model.copyFilePaths(ids) }
        Divider()
        LibraryRemovalActions(model: model, presentation: presentation, ids: ids)
    }
}

private struct LibraryRemovalActions: View {
    @ObservedObject var model: AppModel
    @ObservedObject var presentation: AppPresentation
    let ids: Set<UUID>

    var body: some View {
        Button(model.removalActionTitle, systemImage: "minus.circle", role: .destructive) {
            presentation.requestRemoval(ids, workspaceID: model.activeWorkspaceID)
        }.disabled(model.isBusy || ids.isEmpty)
        if model.activeWorkspace?.kind == .library {
            Button("Move Library Files to Trash…", systemImage: "trash", role: .destructive) {
                presentation.requestRemoval(ids, workspaceID: model.activeWorkspaceID, trash: true)
            }.disabled(!model.canTrash(ids))
        }
    }
}

private struct MetadataContextActions: View {
    @ObservedObject var model: AppModel
    @ObservedObject var presentation: AppPresentation
    let ids: Set<UUID>

    var body: some View {
        Button("Edit Metadata", systemImage: "slider.horizontal.3") {
            model.selectionChanged(ids)
            presentation.showsInspector = true
        }.disabled(!model.canEdit(ids))
        Button("Look Up on MusicBrainz…", systemImage: "magnifyingglass") {
            model.selectionChanged(ids)
            presentation.isShowingLookup = true
            Task { await model.lookup() }
        }.disabled(!model.canLookUp(ids))
        Button("Download Cover Art", systemImage: "photo.on.rectangle") {
            model.selectionChanged(ids)
            Task { await model.downloadCoverArt() }
        }.disabled(!model.canGetArtwork(ids))
        Button("Script Editor…", systemImage: "chevron.left.forwardslash.chevron.right") {
            model.selectionChanged(ids)
            presentation.isShowingScript = true
        }.disabled(!model.canEdit(ids))
        Button("Save Changed Tags", systemImage: "square.and.arrow.down") {
            model.selectionChanged(ids)
            Task { await model.saveSelected() }
        }.disabled(!model.canEdit(ids) || !model.contextFiles(ids).contains(where: \.isModified))
        Button("Discard Unsaved Changes…", systemImage: "arrow.uturn.backward") {
            presentation.requestDiscard(model.contextFiles(ids), workspaceID: model.activeWorkspaceID)
        }.disabled(!model.canDiscardChanges(ids))
        Button("Organize Files…", systemImage: "folder.badge.gearshape") {
            model.selectionChanged(ids)
            presentation.isChoosingDestination = true
        }.disabled(!model.canEdit(ids))
    }
}
