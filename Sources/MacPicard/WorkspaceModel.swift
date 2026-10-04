import AppKit
import Foundation
import PicardFoundation
import PicardSessions

enum BrowserFilter: String, CaseIterable, Identifiable {
    case all = "All Tracks"
    case modified = "Unsaved Changes"
    case missingArtwork = "Missing Artwork"
    case unidentified = "Not Identified"
    case unavailable = "Unavailable"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .all: "music.note.list"
        case .modified: "pencil.circle"
        case .missingArtwork: "photo"
        case .unidentified: "questionmark.circle"
        case .unavailable: "exclamationmark.triangle"
        }
    }
}

enum AlbumSort: String, CaseIterable, Identifiable {
    case title = "Album Title"
    case artist = "Artist"
    var id: String { rawValue }
}

extension AppModel {
    func flushSession() async throws {
        sessionSaveTask?.cancel()
        guard let sessionManager else { return }
        try await sessionManager.save(makeSessionDocument())
    }
    var activeWorkspace: MusicWorkspace? {
        workspaces.first { $0.id == activeWorkspaceID }
    }

    var libraryDirectory: URL? {
        guard activeWorkspace?.kind == .library else { return nil }
        return workspaceAccess?.url ?? activeWorkspace?.directory
    }

    var orderedAlbumGroups: [AlbumGroup] {
        guard albumSort == .artist else { return albumGroups }
        return albumGroups.sorted {
            if $0.artist == $1.artist { return $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            return $0.artist.localizedStandardCompare($1.artist) == .orderedAscending
        }
    }

    var browserAlbumGroups: [AlbumGroup] {
        orderedAlbumGroups.filter { group in
            group.fileIDs.contains { matchingFileIDs.contains($0) }
        }
    }

    var workspaceFilesCount: Int { files.count }
    var isBusy: Bool { isWorking || isExportingArtwork || isSwitchingWorkspace || isLoading || isPreparingOrganization || fingerprintJobIsScheduled || isCommittingLibraryScan }
    var canEditSelection: Bool {
        !isBusy && !selectedFiles.isEmpty && selectedFiles.allSatisfy {
            [.ready, .changed, .saved].contains($0.state)
        }
    }

    var canOrganizeEntireLibrary: Bool {
        canPerform(.organize, scope: .library)
    }

    var canLookupSelection: Bool {
        guard canEditSelection else { return false }
        let ids = selectedFileIDs
        return albumGroups.contains { ids.isSubset(of: Set($0.fileIDs)) }
    }

    var browsingAllTracks: Bool {
        selectedAlbumID == nil || !appliedSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var displayedAlbum: AlbumGroup? {
        albumGroups.first { $0.id == selectedAlbumID }
    }

    var browserTitle: String {
        if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Search Results" }
        if let selectedArtist { return selectedArtist }
        return displayedAlbum?.title ?? activeWorkspace?.name ?? "All Tracks"
    }

    var browserSubtitle: String {
        if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(visibleFiles.count) matches in \(activeWorkspace?.name ?? "this workspace")"
        }
        return displayedAlbum?.artist ?? "\(albumGroups.count) albums · \(workspaceFilesCount) audio files"
    }

    func matchesBrowser(_ file: AudioFile) -> Bool {
        guard passesFilter(file) else { return false }
        return indexedSearchMatches(file.id)
    }

    func passesFilter(_ file: AudioFile) -> Bool {
        switch browserFilter {
        case .all: true
        case .modified: file.isModified
        case .missingArtwork: file.artwork.first(of: .front) == nil
        case .unidentified: file.metadata.firstValue(for: "musicbrainz_albumid")?.isEmpty != false
        case .unavailable: [.removed, .failed, .unsupported].contains(file.state)
        }
    }

    func browseAllTracks() {
        selectedAlbumID = nil
        selectedArtist = nil
        clearSelection()
        scheduleSessionSave()
    }

    func selectSidebarTrack(_ id: UUID, album: AlbumGroup) {
        selectedAlbumID = album.id
        if NSEvent.modifierFlags.contains(.command) {
            var ids = selectedFileIDs
            if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
            selectionChanged(ids)
        } else if NSEvent.modifierFlags.contains(.shift),
                  let anchor = album.fileIDs.firstIndex(where: { selectedFileIDs.contains($0) }),
                  let end = album.fileIDs.firstIndex(of: id) {
            selectionChanged(Set(album.fileIDs[min(anchor, end)...max(anchor, end)]))
        } else {
            selectionChanged([id])
        }
    }

    func toggleAlbumExpansion(_ id: String) {
        if expandedAlbumIDs.contains(id) { expandedAlbumIDs.remove(id) }
        else { expandedAlbumIDs.insert(id) }
    }

    func expandAllAlbums() { expandedAlbumIDs = Set(browserAlbumGroups.map(\.id)) }
    func collapseAllAlbums() { expandedAlbumIDs.removeAll() }

    func restoreWorkspaces() async throws {
        guard let runtime, let snapshot else { return }
        let store = WorkspaceStore(directory: snapshot.paths.applicationSupportDirectory.appendingPathComponent("Workspaces"))
        workspaceStore = store
        var catalog = try await store.load()
        if catalog.workspaces.isEmpty {
            // Migrate the original single workspace without touching the original files.
            let legacyStore = await runtime.sessionStore
            let legacy = try await SessionManager(store: legacyStore).loadBestAvailable()
            let workspace = MusicWorkspace(name: "My Session", kind: .session)
            catalog = try await store.create(workspace, document: legacy?.document ?? SessionDocument())
        }
        workspaces = catalog.workspaces
        let id = catalog.activeWorkspaceID ?? catalog.workspaces[0].id
        try await loadWorkspace(id)
        startLibraryRefresh()
    }

    func switchWorkspace(_ id: UUID) async {
        guard id != activeWorkspaceID, !isBusy, workspaceStore != nil else { return }
        isSwitchingWorkspace = true
        defer { isSwitchingWorkspace = false }
        do {
            sessionSaveTask?.cancel()
            if let sessionManager { try await sessionManager.save(makeSessionDocument()) }
            try await loadWorkspace(id)
        } catch { present(error) }
    }

    private func loadWorkspace(_ id: UUID) async throws {
        guard let workspaceStore else { return }
        let manager = SessionManager(store: await workspaceStore.sessionStore(for: id))
        // Validate once before replacing the active workspace, then reuse that document.
        let loaded = try await manager.loadBestAvailable()
        let catalog = try await workspaceStore.activate(id)
        stopLibraryMonitoring()
        clearEditHistory()
        playback.stop(clearQueue: true)
        workspaceAccess = nil
        importedAccess.removeAll()
        accessBookmarkKeys.removeAll()
        workspaces = catalog.workspaces
        activeWorkspaceID = id
        monitoringMessage = nil
        sessionManager = manager
        operationHistoryDirectory = await workspaceStore.operationDirectory(for: id)
        await reloadOperationHistory(markInterrupted: true)
        sessionCreatedAt = Date()
        resetWorkspaceSelection()
        files.removeAll()
        statusMessage = "Opened \(activeWorkspace?.name ?? "workspace")."
        errorMessage = nil
        restoreSession(loaded)
        await restoreWorkspaceAccess()
        await restoreCommittedOperationResults()
        restartLibraryMonitoring()
        if activeWorkspace?.kind == .library {
            libraryScanTask?.cancel()
            activeLibraryScan?.cancel()
            libraryScanTask = Task { @MainActor [weak self] in
                // Let the switch complete before starting its first refresh.
                await Task.yield()
                guard let self, !Task.isCancelled else { return }
                while self.isSwitchingWorkspace || self.isLoading {
                    do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                    guard !Task.isCancelled else { return }
                }
                guard self.activeWorkspaceID == id else { return }
                await self.refreshLibrary()
            }
        }
    }

    func createSession(named name: String, copyingCurrent: Bool = false) async {
        guard !isBusy, let workspaceStore else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        isSwitchingWorkspace = true
        defer { isSwitchingWorkspace = false }
        do {
            sessionSaveTask?.cancel()
            if let sessionManager { try await sessionManager.save(makeSessionDocument()) }
            let document = copyingCurrent ? makeSessionDocument() : SessionDocument()
            let workspace = MusicWorkspace(name: name, kind: .session)
            _ = try await workspaceStore.create(workspace, document: document)
            try await loadWorkspace(workspace.id)
        } catch { present(error) }
    }

    func addLibrary(directory: URL) async {
        guard !isBusy, let workspaceStore, let runtime else { return }
        if let existing = workspaces.first(where: {
            $0.kind == .library && $0.directory?.standardizedFileURL == directory.standardizedFileURL
        }) { await switchWorkspace(existing.id); return }
        isSwitchingWorkspace = true
        defer { isSwitchingWorkspace = false }
        let accessed = directory.startAccessingSecurityScopedResource()
        defer { if accessed { directory.stopAccessingSecurityScopedResource() } }
        do {
            guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw SaveError.session("Select a directory for the music library.")
            }
            sessionSaveTask?.cancel()
            if let sessionManager { try await sessionManager.save(makeSessionDocument()) }
            var workspace = MusicWorkspace(name: directory.lastPathComponent, kind: .library, directory: directory)
            workspace.automaticallyRefreshes = configuration.editing.newLibrariesMonitorAutomatically
            try await runtime.bookmarks.save(url: directory, for: "library-\(workspace.id)", readOnly: false)
            _ = try await workspaceStore.create(workspace, document: SessionDocument())
            try await loadWorkspace(workspace.id)
        } catch { present(error) }
    }

    func relinkLibrary(directory: URL) async {
        guard !isBusy, var workspace = activeWorkspace, workspace.kind == .library,
              let workspaceStore, let runtime else { return }
        let accessed = directory.startAccessingSecurityScopedResource()
        defer { if accessed { directory.stopAccessingSecurityScopedResource() } }
        do {
            guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw SaveError.session("Select a directory for the music library.")
            }
            try await runtime.bookmarks.save(url: directory, for: "library-\(workspace.id)", readOnly: false)
            if let previous = workspace.directory { rebaseLibraryFiles(from: previous, to: directory) }
            workspace.directory = directory
            workspaces = try await workspaceStore.update(workspace).workspaces
            workspaceAccess = try? await runtime.bookmarks.resolve(key: "library-\(workspace.id)")
            restartLibraryMonitoring()
            await refreshLibrary()
        } catch { present(error) }
    }

    func renameWorkspace(_ workspace: MusicWorkspace, to name: String) async {
        guard let workspaceStore, !isBusy else { return }
        var renamed = workspace
        renamed.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !renamed.name.isEmpty else { return }
        do { workspaces = try await workspaceStore.update(renamed).workspaces }
        catch { present(error) }
    }

    func removeWorkspace(_ workspace: MusicWorkspace) async {
        guard let workspaceStore, !isBusy else { return }
        isSwitchingWorkspace = true
        defer { isSwitchingWorkspace = false }
        do {
            try await flushSession()
            if workspace.id == activeWorkspaceID {
                let nextID: UUID
                if let next = workspaces.first(where: { $0.id != workspace.id }) { nextID = next.id }
                else {
                    let next = MusicWorkspace(name: "My Session", kind: .session)
                    _ = try await workspaceStore.create(next, document: SessionDocument())
                    nextID = next.id
                }
                try await loadWorkspace(nextID)
            }
            workspaces = try await workspaceStore.remove(workspace.id).workspaces
            statusMessage = "Removed \(workspace.name). Its audio files and saved workspace were kept."
        }
        catch { present(error) }
    }

    func setAutomaticRefresh(_ enabled: Bool) async {
        guard let workspaceStore, var workspace = activeWorkspace, !isBusy else { return }
        workspace.automaticallyRefreshes = enabled
        do { workspaces = try await workspaceStore.update(workspace).workspaces; restartLibraryMonitoring() }
        catch { present(error) }
    }

    func refreshLibrary(automatic: Bool = false, affectedPaths: Set<URL>? = nil) async {
        guard !isBusy, let workspace = activeWorkspace, workspace.kind == .library,
              let directory = workspaceAccess?.url ?? workspace.directory else { return }
        // Monitoring stays out of the foreground while the user is listening
        // or performing another operation. Manual refresh remains explicit.
        if automatic && monitoringMustWait { return }
        if activeLibraryScanID != nil {
            if automatic { return }
            // A deliberate refresh preempts a quiet scan; its stale completion
            // is discarded by the scan ID as well as cancellation.
            activeLibraryScan?.cancel()
        }
        let scanID = UUID()
        activeLibraryScanID = scanID
        cancelledLibraryScanID = nil
        var scanRecord = automatic ? nil : FileOperationRecord(workspaceID: workspace.id, kind: .scan,
            items: files.map { FileOperationItem(file: $0) })
        if !automatic {
            isWorking = true
            isScanningLibrary = true
            progress = 0
            errorMessage = nil
            statusMessage = "Scanning \(workspace.name)…"
        }
        defer {
            if !automatic {
                isWorking = false
                isScanningLibrary = false
            }
            if activeLibraryScanID == scanID { activeLibraryScan = nil; activeLibraryScanID = nil }
            if activeLibraryScanID == nil { isCommittingLibraryScan = false }
            if !automatic { progress = nil }
        }
        do {
            if let scanRecord { try await persistOperation(scanRecord) }
            // Refresh a lost/stale security scope before reading the library.
            if (workspaceAccess == nil || !FileManager.default.isReadableFile(atPath: directory.path)), let runtime {
                workspaceAccess = try? await runtime.bookmarks.resolve(key: "library-\(workspace.id)")
            }
            let directory = workspaceAccess?.url ?? directory
            if directory != workspace.directory, let previous = workspace.directory {
                rebaseLibraryFiles(from: previous, to: directory)
                libraryMonitor = nil
            }
            let existing = files
            let scanner = libraryScanner
            let workspaceID = workspace.id
            guard cancelledLibraryScanID != scanID else { throw CancellationError() }
            let scan: Task<LibraryScanResult, Error>
            if automatic {
                scan = Task(priority: .utility) {
                    try await scanner.scan(
                        directory: directory,
                        existing: existing,
                        excludingRelativePaths: workspace.excludedRelativePaths,
                        affectedPaths: affectedPaths,
                        progress: nil
                    )
                }
            } else {
                scan = Task(priority: .userInitiated) { [weak self] in
                    try await scanner.scan(
                        directory: directory,
                        existing: existing,
                        excludingRelativePaths: workspace.excludedRelativePaths,
                        progress: { [weak self] value in
                            guard let self else { return }
                            await self.updateSaveProgress(value)
                        }
                    )
                }
            }
            activeLibraryScan = scan
            let report = try await scan.value
            guard cancelledLibraryScanID != scanID else { throw CancellationError() }
            try Task.checkCancellation()
            guard activeWorkspaceID == workspaceID, activeLibraryScanID == scanID else { return }
            installLibraryMonitorIfNeeded()
            // Do not commit a quiet pass while a user operation is in flight.
            if automatic && monitoringMustWait {
                enqueueLibraryChanges(.init(paths: affectedPaths ?? [], requiresFullScan: affectedPaths == nil))
                return
            }
            let merged = report.merging(baseline: existing, current: files)
            let warnings = report.failures + report.conflicts.map {
                "\($0) changed on disk; your pending edits were preserved."
            }
            let warning = warnings.isEmpty ? nil : warnings.prefix(3).joined(separator: "\n")
            if automatic && warning != monitoringMessage { monitoringMessage = warning }
            let changed = merged != files
            // Most monitoring passes are no-ops. Do not publish the same graph,
            // touch the status bar, or autosave in that case.
            if automatic && !changed { return }
            isCommittingLibraryScan = true
            if changed {
                files = merged
                scanPublicationCount += 1
                selectedFileIDs.formIntersection(Set(files.map(\.id)))
            }
            var updated = activeWorkspace ?? workspace
            updated.directory = directory
            updated.lastScannedAt = Date()
            if let workspaceStore { workspaces = try await workspaceStore.update(updated).workspaces }
            if !automatic { errorMessage = warning }
            try await flushSession()
            if var record = scanRecord {
                record.items = merged.map { file in
                    var item = FileOperationItem(file: file)
                    item.state = [.failed, .removed].contains(file.state) ? .failed : .completed
                    item.message = file.lastError ?? (file.state == .removed ? "File unavailable." : "")
                    return item
                }
                record.state = record.items.contains { $0.state == .failed } ? .failed : .completed
                record.finishedAt = Date()
                try await persistOperation(record)
                scanRecord = record
                statusMessage = "\(files.count) files · \(report.addedCount) added · \(report.updatedCount) refreshed"
                if report.missingCount > 0 { statusMessage += " · \(report.missingCount) unavailable" }
            }
        } catch is CancellationError {
            guard activeWorkspaceID == workspace.id, activeLibraryScanID == scanID else { return }
            if var record = scanRecord {
                record.state = .interrupted; record.message = "Refresh cancelled. Refresh Again starts a fresh read-only check."
                try? await persistOperation(record)
            }
            if !automatic { statusMessage = "Library refresh cancelled." }
        } catch {
            guard activeWorkspaceID == workspace.id, activeLibraryScanID == scanID else { return }
            if var record = scanRecord {
                record.state = .failed; record.message = error.localizedDescription
                try? await persistOperation(record)
            }
            if automatic {
                let message = "Library unavailable. Reconnect its folder in the library menu. \(error.localizedDescription)"
                if monitoringMessage != message { monitoringMessage = message }
                workspaceAccess = nil
                libraryMonitor = nil
            } else {
                present(error)
                statusMessage = "Library unavailable. Reconnect its folder and refresh."
            }
        }
    }

    func cancelLibraryRefresh() {
        cancelledLibraryScanID = activeLibraryScanID
        activeLibraryScan?.cancel()
    }

    private func startLibraryRefresh() {
        refreshTask?.cancel()
        refreshTask = Task(priority: .utility) { @MainActor [weak self] in
            while !Task.isCancelled {
                let seconds = max(60, self?.configuration.editing.monitoringIntervalSeconds ?? 300)
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                if self.activeWorkspace?.automaticallyRefreshes == true {
                    self.enqueueLibraryChanges(.init(paths: [], requiresFullScan: true))
                }
            }
        }
    }

    var monitoringMustWait: Bool {
        isBusy || playback.transportIsActive || files.contains(where: \.isModified)
            || matchReview != nil || organizationReview != nil
    }

    func stopLibraryMonitoring() {
        monitoringGeneration = UUID()
        libraryMonitor = nil
        refreshTask?.cancel()
        monitoringDebounceTask?.cancel()
        libraryScanTask?.cancel()
        activeLibraryScan?.cancel()
        activeLibraryScan = nil
        activeLibraryScanID = nil
        pendingLibraryPaths.removeAll()
        monitoringNeedsFullScan = false
    }

    func restartLibraryMonitoring() {
        stopLibraryMonitoring()
        startLibraryRefresh()
        installLibraryMonitorIfNeeded()
    }

    private func installLibraryMonitorIfNeeded() {
        guard libraryMonitor == nil else { return }
        guard let workspace = activeWorkspace, workspace.kind == .library, workspace.automaticallyRefreshes,
              let directory = libraryDirectory else { return }
        let generation = monitoringGeneration
        do {
            libraryMonitor = try LibraryDirectoryMonitor(directory: directory) { [weak self] hint in
                Task { @MainActor [weak self] in
                    guard let self, self.monitoringGeneration == generation,
                          self.activeWorkspaceID == workspace.id else { return }
                    self.enqueueLibraryChanges(hint)
                }
            }
        } catch { monitoringMessage = error.localizedDescription }
    }

    func enqueueLibraryChanges(_ hint: LibraryChangeHint) {
        guard activeWorkspace?.automaticallyRefreshes == true else { return }
        pendingLibraryPaths.formUnion(hint.paths)
        monitoringNeedsFullScan = monitoringNeedsFullScan || hint.requiresFullScan || pendingLibraryPaths.count > 512
        if monitoringNeedsFullScan { pendingLibraryPaths.removeAll() }
        monitoringDebounceTask?.cancel()
        let generation = monitoringGeneration
        monitoringDebounceTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            while !Task.isCancelled {
                guard let self, self.monitoringGeneration == generation else { return }
                if self.monitoringMustWait || self.activeLibraryScanID != nil {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    continue
                }
                let paths = self.monitoringNeedsFullScan ? nil : self.pendingLibraryPaths
                self.pendingLibraryPaths.removeAll()
                self.monitoringNeedsFullScan = false
                await self.refreshLibrary(automatic: true, affectedPaths: paths)
                return
            }
        }
    }

    func rememberImportAccess(_ urls: [URL]) async throws {
        guard let runtime else { return }
        for url in urls {
            if importedAccess.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) { continue }
            let key = "import-\(UUID())"
            try await runtime.bookmarks.save(url: url, for: key, readOnly: false)
            accessBookmarkKeys.append(key)
            if let access = try? await runtime.bookmarks.resolve(key: key) { importedAccess.append(access) }
        }
    }

    private func restoreWorkspaceAccess() async {
        guard let runtime else { return }
        if let workspace = activeWorkspace, workspace.kind == .library {
            do {
                workspaceAccess = try await runtime.bookmarks.resolve(key: "library-\(workspace.id)")
                if let previous = workspace.directory, let current = workspaceAccess?.url {
                    rebaseLibraryFiles(from: previous, to: current)
                }
            }
            catch {
                if workspace.directory.map({ FileManager.default.isReadableFile(atPath: $0.path) }) != true {
                    errorMessage = "Reconnect this library's folder to restore access."
                }
            }
        }
        for key in accessBookmarkKeys {
            if let access = try? await runtime.bookmarks.resolve(key: key) { importedAccess.append(access) }
        }
        // Earlier builds stored an individual bookmark for each imported file.
        if accessBookmarkKeys.isEmpty, activeWorkspace?.kind == .session {
            for file in files {
                if let access = try? await runtime.bookmarks.resolve(key: file.id.uuidString) {
                    importedAccess.append(access)
                    accessBookmarkKeys.append(file.id.uuidString)
                }
            }
        }
    }

    private func rebaseLibraryFiles(from oldRoot: URL, to newRoot: URL) {
        let prefix = oldRoot.standardizedFileURL.path + "/"
        guard oldRoot.standardizedFileURL != newRoot.standardizedFileURL else { return }
        files = files.map { file in
            guard file.url.standardizedFileURL.path.hasPrefix(prefix) else { return file }
            var relocated = file
            let relative = String(file.url.standardizedFileURL.path.dropFirst(prefix.count))
            try? relocated.updateURL(newRoot.appendingPathComponent(relative))
            return relocated
        }
    }

    func revealSelection() {
        NSWorkspace.shared.activateFileViewerSelecting(selectedFiles.map(\.url))
    }

    func revealFiles(_ files: [AudioFile]) {
        NSWorkspace.shared.activateFileViewerSelecting(files.map(\.url))
    }

    func revealLibrary() {
        if let directory = workspaceAccess?.url ?? activeWorkspace?.directory {
            NSWorkspace.shared.activateFileViewerSelecting([directory])
        }
    }
}
