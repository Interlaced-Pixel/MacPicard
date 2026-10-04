import Foundation
import PicardFoundation
import PicardSessions

extension AppModel {
    func requestOrganizationReview(entireLibrary: Bool = false) {
        organizationRequestedIDs = nil
        organizationScopeLabel = entireLibrary ? "Entire library" : "Selection"
        organizationEntireLibraryRequested = entireLibrary
    }

    func requestOrganizationReview(ids: Set<UUID>, label: String) {
        organizationRequestedIDs = ids; organizationScopeLabel = label
        organizationEntireLibraryRequested = false
    }

    func beginOrganizationReview(entireLibrary: Bool = false) {
        let explicit = organizationRequestedIDs
        let targets = explicit.map { ids in files.filter { ids.contains($0.id) } } ?? (entireLibrary && activeWorkspace?.kind == .library ? files : selectedFiles)
        guard !isBusy, !targets.isEmpty else { return }
        cancelOrganizationReview()
        organizationRequestedIDs = explicit
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
              (organizationRequestedIDs.map { Set(organizationFiles.map(\.id)) == $0 } ?? (organizationTargetsEntireLibrary
                ? Set(organizationFiles.map(\.id)) == Set(files.map(\.id))
                : Set(organizationFiles.map(\.id)) == selectedFileIDs)),
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
        organizationRequestedIDs = nil
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
            let journal = FileOperationRecord(workspaceID: activeWorkspaceID ?? UUID(), kind: .organize,
                items: review.rows.filter { $0.status == .move }.compactMap { row in
                    review.files.first { $0.id == row.id }.map { FileOperationItem(file: $0, destination: row.destination) }
                })
            try await persistOperation(journal)
            let journalURL = operationHistoryDirectory?.appendingPathComponent(journal.id.uuidString).appendingPathExtension("json")
            if let playingID = playback.currentTrack?.fileID,
               review.plan.operations.contains(where: { $0.fileID == playingID }) { playback.stop() }
            let result = try await organizationCoordinator.executeReview(review, journal: journal, journalURL: journalURL)
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
            errorMessage = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
            do { try await flushSession() }
            catch {
                // Disk moves completed: keep the new paths, never pretend the old locations still exist.
                errorMessage = "Files moved, but the library could not be saved: \(error.localizedDescription)"
                try? await sessionManager?.saveRecovery(makeSessionDocument())
                await reloadOperationHistory()
                return false
            }
            // The coordinator's journal contains intermediate paths; retain it
            // until all workspace changes above have reached disk.
            await reloadOperationHistory()
            if var completed = operationHistory.first(where: { $0.id == journal.id }) {
                completed.state = .completed; completed.finishedAt = Date()
                try await persistOperation(completed)
            }
            statusMessage = "Moved \(result.report.movedFileIDs.count) files. Tags and artwork were not written."
            return true
        } catch {
            await reloadOperationHistory(markInterrupted: true)
            organizationReview = nil
            organizationError = error.localizedDescription + " Update the preview before trying again."
            statusMessage = "Organization did not complete. Review the error before retrying."
            return false
        }
    }
}
