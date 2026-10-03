import Foundation
import PicardSessions

extension AppModel {
    var removalActionTitle: String {
        activeWorkspace?.kind == .library ? "Remove from Library…" : "Remove from Session…"
    }

    func canTrash(_ ids: Set<UUID>) -> Bool {
        guard !isBusy, let directory = libraryDirectory else { return false }
        let targets = contextFiles(ids)
        return !targets.isEmpty && targets.allSatisfy {
            LibraryPaths.relativePath(of: $0.url, in: directory) != nil
                && [.ready, .changed, .saved].contains($0.state)
        }
    }

    func removeFiles(_ ids: Set<UUID>, movingToTrash: Bool = false, confirmed: Bool = false) async {
        guard confirmed, !isBusy, !contextFiles(ids).isEmpty else { return }
        let targets = contextFiles(ids)
        if movingToTrash && !canTrash(ids) {
            errorMessage = "Only files stored inside the current Music Library can be moved to Trash."
            return
        }
        isWorking = true
        errorMessage = nil
        statusMessage = movingToTrash ? "Moving library files to Trash…" : "Removing library items…"
        defer { isWorking = false }
        if let current = playback.currentTrack?.fileID, ids.contains(current) { playback.stop() }
        var removedIDs = movingToTrash ? Set<UUID>() : Set(targets.map(\.id))
        var failures: [String] = []
        do {
            if movingToTrash, let directory = libraryDirectory {
                let result = try await LibraryTrashCoordinator().trash(targets, in: directory, confirmed: true)
                removedIDs = result.trashedFileIDs
                failures = result.failures
            }
            if var workspace = activeWorkspace, workspace.kind == .library, let directory = libraryDirectory {
                let paths = targets.filter { removedIDs.contains($0.id) }
                    .compactMap { LibraryPaths.relativePath(of: $0.url, in: directory) }
                workspace.excludedRelativePaths.formUnion(paths)
                guard let workspaceStore else { throw SaveError.session("The library catalog is unavailable.") }
                workspaces = try await workspaceStore.update(workspace).workspaces
            }
            for entry in playback.queue.filter({ removedIDs.contains($0.track.fileID) }) { playback.removeEntry(entry.id) }
            files.removeAll { removedIDs.contains($0.id) }
            selectionChanged(selectedFileIDs.subtracting(removedIDs))
            if !albumGroups.contains(where: { $0.id == selectedAlbumID }) { selectedAlbumID = nil }
            try await flushSession()
            statusMessage = movingToTrash
                ? "Moved \(removedIDs.count) files to Trash. They can be recovered in Finder."
                : "Removed \(removedIDs.count) items. Audio files were kept on disk."
            if !failures.isEmpty { statusMessage += " \(failures.count) failed." }
            errorMessage = failures.isEmpty ? nil : failures.prefix(3).joined(separator: "\n")
        } catch {
            // A disk Trash action cannot be undone by a failed catalog write.
            // Keep its records and report the real outcome rather than success.
            if movingToTrash {
                for index in files.indices where removedIDs.contains(files[index].id) { files[index].markRemoved() }
                statusMessage = "\(removedIDs.count) files moved to Trash; library persistence failed."
            }
            present(error)
        }
    }

    func restoreExcludedLibraryItems() async {
        guard !isBusy, var workspace = activeWorkspace, workspace.kind == .library,
              !workspace.excludedRelativePaths.isEmpty, let workspaceStore else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            workspace.excludedRelativePaths.removeAll()
            workspaces = try await workspaceStore.update(workspace).workspaces
            isWorking = false
            await refreshLibrary()
        } catch { present(error) }
    }
}
