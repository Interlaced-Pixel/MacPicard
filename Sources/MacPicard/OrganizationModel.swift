import Foundation
import PicardFoundation
import PicardSessions

extension AppModel {
    func requestOrganizationReview(entireLibrary: Bool = false) {
        organizationEntireLibraryRequested = entireLibrary
    }

    func beginOrganizationReview(entireLibrary: Bool = false) {
        let targets = entireLibrary && activeWorkspace?.kind == .library ? files : selectedFiles
        guard canPerform(.organize, scope: entireLibrary ? .library : .selection), !targets.isEmpty else { return }
        cancelOrganizationReview()
        organizationTargetsEntireLibrary = entireLibrary && activeWorkspace?.kind == .library
        organizationFiles = targets
        organizationWorkspaceID = activeWorkspaceID
        organizationLibraryRoot = libraryDirectory
        organizationDirectory = libraryDirectory ?? destinationDirectory
        organizationConflictPolicy = .stop
        organizationExcludedIDs = []
        organizationError = nil
    }

    func refreshOrganizationPreview() async {
        guard !isWorking, !isLoading, !isSwitchingWorkspace, !organizationFiles.isEmpty else { return }
        let generation = UUID()
        organizationGeneration = generation
        organizationReview = nil
        organizationError = nil
        guard let directory = organizationDirectory else { isPreparingOrganization = false; return }
        isPreparingOrganization = true
        let targets = organizationFiles
        let naming = organizationNamingScript
        let policy = organizationConflictPolicy
        let excluded = organizationExcludedIDs
        defer { if generation == organizationGeneration { isPreparingOrganization = false } }
        do {
            let review = try await organizationCoordinator.preview(files: targets, directory: directory,
                namingScript: naming, policy: policy, excludedIDs: excluded)
            guard generation == organizationGeneration, !Task.isCancelled else { return }
            organizationReview = review
        } catch is CancellationError { }
        catch {
            guard generation == organizationGeneration else { return }
            organizationError = error.localizedDescription
        }
    }

    /// Selecting a folder only updates the preview. It can never initiate a move.
    func chooseOrganizationDirectory(_ result: Result<[URL], Error>) async {
        guard !isWorking else { return }
        do {
            guard let directory = try result.get().first else { return }
            let generation = organizationGeneration
            let workspaceID = organizationWorkspaceID
            let accessed = directory.startAccessingSecurityScopedResource()
            defer { if accessed { directory.stopAccessingSecurityScopedResource() } }
            try await rememberImportAccess([directory])
            guard generation == organizationGeneration, workspaceID == activeWorkspaceID else { return }
            organizationDirectory = directory
            destinationDirectory = directory
        } catch { organizationError = error.localizedDescription }
    }

    var organizationInputsAreCurrent: Bool {
        guard let review = organizationReview,
              organizationWorkspaceID == activeWorkspaceID,
              organizationLibraryRoot == libraryDirectory,
              (organizationTargetsEntireLibrary
                ? Set(organizationFiles.map(\.id)) == Set(files.map(\.id))
                : Set(organizationFiles.map(\.id)) == selectedFileIDs),
              organizationFiles.allSatisfy({ file(id: $0.id) == $0 }),
              organizationDirectory == review.directory,
              organizationNamingScript == review.namingScript,
              organizationConflictPolicy == review.policy,
              organizationExcludedIDs == review.excludedIDs else { return false }
        return true
    }

    var canExecuteOrganization: Bool {
        !isBusy && organizationInputsAreCurrent && organizationReview?.canExecute == true
    }

    var organizationOutsideLibraryCount: Int {
        guard let root = organizationLibraryRoot else { return 0 }
        return organizationReview?.rows.count {
            $0.status == .move && $0.destination.map { LibraryPaths.relativePath(of: $0, in: root) == nil } == true
        } ?? 0
    }

    func cancelOrganizationReview() {
        organizationGeneration = UUID()
        organizationReview = nil
        organizationFiles.removeAll()
        organizationTargetsEntireLibrary = false
        organizationError = nil
        isPreparingOrganization = false
    }

    @discardableResult
    func executeOrganization(reviewID: UUID, confirmed: Bool = false, allowOutsideLibrary: Bool = false) async -> Bool {
        guard confirmed, canExecuteOrganization, let review = organizationReview, review.id == reviewID,
              organizationOutsideLibraryCount == 0 || allowOutsideLibrary else { return false }
        isWorking = true
        isExecutingOrganization = true
        errorMessage = nil
        organizationError = nil
        statusMessage = "Organizing \(review.moveCount) reviewed files…"
        defer { isWorking = false; isExecutingOrganization = false }
        do {
            // Verify workspace persistence before changing any paths on disk.
            try await flushSession()
            guard organizationInputsAreCurrent else { throw SaveError.session("The files changed. Close and reopen Organize.") }
            if let playingID = playback.currentTrack?.fileID,
               review.plan.operations.contains(where: { $0.fileID == playingID }) { playback.stop() }
            let result = try await organizationCoordinator.executeReview(review)
            clearEditHistory()
            let relocated = Dictionary(uniqueKeysWithValues: result.files.map { ($0.id, $0) })
            files = files.map { relocated[$0.id] ?? $0 }
            var warnings = result.warnings
            if var workspace = activeWorkspace, let root = organizationLibraryRoot {
                let newPaths = result.report.destinations.values.compactMap { LibraryPaths.relativePath(of: $0, in: root) }
                let previous = workspace.excludedRelativePaths
                workspace.excludedRelativePaths.subtract(newPaths)
                if previous != workspace.excludedRelativePaths {
                    if let index = workspaces.firstIndex(where: { $0.id == workspace.id }) { workspaces[index] = workspace }
                    do {
                        if let workspaceStore { workspaces = try await workspaceStore.update(workspace).workspaces }
                    } catch { warnings.append("Files moved, but updated library exclusions could not be saved: \(error.localizedDescription)") }
                }
            }
            cancelMatchReview()
            cancelOrganizationReview()
            statusMessage = "Moved \(result.report.movedFileIDs.count) files. Tags and artwork were not written."
            errorMessage = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
            do { try await flushSession() }
            catch {
                // Disk moves completed: keep the new paths, never pretend the old locations still exist.
                errorMessage = "Files moved, but the workspace could not be saved: \(error.localizedDescription)"
                try? await sessionManager?.saveRecovery(makeSessionDocument())
            }
            return true
        } catch {
            organizationReview = nil
            organizationError = error.localizedDescription + " Update the preview before trying again."
            statusMessage = "Organization did not complete. Review the error before retrying."
            return false
        }
    }
}
