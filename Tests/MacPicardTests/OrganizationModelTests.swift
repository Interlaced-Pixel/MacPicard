import Foundation
import PicardFormats
import PicardFoundation
import PicardSessions
import XCTest
@testable import MacPicard

final class OrganizationModelTests: XCTestCase {
    @MainActor func testManualRefreshCancellationPublishesNoPartialSnapshot() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try audio("source.mp3", in: root)
        let model = libraryModel(root, files: [file])
        for index in 0..<50 { try FileManager.default.copyItem(at: file.url, to: root.appendingPathComponent("\(index).mp3")) }
        let refresh = Task { @MainActor in await model.refreshLibrary() }
        while !model.isScanningLibrary { await Task.yield() }
        XCTAssertNotNil(model.progress)
        model.cancelLibraryRefresh()
        await refresh.value
        XCTAssertEqual(model.files, [file])
        XCTAssertEqual(model.statusMessage, "Library refresh cancelled.")
        XCTAssertNil(model.progress)
        XCTAssertFalse(model.isBusy)
    }

    @MainActor func testSaveHistoryPersistsPerFileResultsWithoutRetryingSuccesses() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try folder("Library", in: root)
        let source = library.appendingPathComponent("first.flac")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono", "-t", "0.1", "-c:a", "flac", source.path]
        process.standardOutput = Pipe(); process.standardError = Pipe(); try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let second = library.appendingPathComponent("second.flac")
        try FileManager.default.copyItem(at: source, to: second)
        let loader = AudioFileCoordinator()
        var firstFile = try await loader.load(url: source), secondFile = try await loader.load(url: second)
        var tags = firstFile.metadata; tags.setValue("Saved title", for: "title"); try firstFile.updateMetadata(tags)
        tags = secondFile.metadata; tags.setValue("Failed draft", for: "title"); try secondFile.updateMetadata(tags)
        let model = libraryModel(library, files: [firstFile, secondFile])
        model.saveCoordinator = AudioSaveCoordinator()
        let store = WorkspaceStore(directory: root.appendingPathComponent("Workspaces"))
        let workspace = try XCTUnwrap(model.activeWorkspace)
        _ = try await store.create(workspace, document: model.makeSessionDocument())
        model.workspaceStore = store
        model.sessionManager = SessionManager(store: await store.sessionStore(for: workspace.id))
        model.operationHistoryDirectory = await store.operationDirectory(for: workspace.id)
        // Replace only the owned fixture, exercising the external-change guard.
        var bytes = try Data(contentsOf: second); bytes.append(0)
        try bytes.write(to: second, options: .atomic)
        await model.saveFiles(model.files)
        XCTAssertEqual(model.lastSaveOutcomes.map(\.saved), [true, false])
        let read = try await FormatEngine().read(url: source)
        XCTAssertEqual(read.metadata.firstValue(for: "title"), "Saved title")
        XCTAssertEqual(try Data(contentsOf: second), bytes)
        let history = try await OperationHistoryStore().load(directory: try XCTUnwrap(model.operationHistoryDirectory), workspaceID: workspace.id)
        let record = try XCTUnwrap(history.first)
        XCTAssertEqual(record.state, .failed)
        XCTAssertEqual(record.items.map(\.state), [.completed, .failed])
        XCTAssertEqual(model.retryableSaveIDs(record), [secondFile.id])
        let loaded = try await model.sessionManager?.loadBestAvailable()
        XCTAssertEqual(loaded?.document.files.first?.state, .saved)
        XCTAssertEqual(loaded?.document.files.last?.metadata.firstValue(for: "title"), "Failed draft")
        XCTAssertFalse(model.isWritingAudio)
        let restarted = libraryModel(library, files: try XCTUnwrap(loaded).document.files.map { AudioFile.restore(from: $0) })
        restarted.activeWorkspaceID = workspace.id
        XCTAssertEqual(restarted.retryableSaveIDs(record), [secondFile.id], "Retries must survive JSON date epoch round trips")
        if let output = ProcessInfo.processInfo.environment["MACPICARD_PHASE9_GUI_DIRECTORY"] {
            let guiRoot = URL(fileURLWithPath: output)
            guard guiRoot.path.hasPrefix("/tmp/MacPicard-phase9-ui."), FileManager.default.fileExists(atPath: guiRoot.path) else {
                return XCTFail("GUI validation needs an existing, owned temporary directory")
            }
            let guiLibrary = try folder("Audio", in: guiRoot)
            var guiFiles: [AudioFile] = []
            for file in model.files {
                let target = guiLibrary.appendingPathComponent(file.url.lastPathComponent)
                try FileManager.default.copyItem(at: file.url, to: target)
                var copied = file; try copied.updateURL(target, identity: AudioFileIdentity.capture(url: target))
                guiFiles.append(copied)
            }
            var guiWorkspace = MusicWorkspace(name: "Phase 9 Validation", kind: .library, directory: guiLibrary)
            guiWorkspace.automaticallyRefreshes = true
            let guiStore = WorkspaceStore(directory: guiRoot.appendingPathComponent("State/Workspaces"))
            let guiDocument = SessionDocument(files: guiFiles.map { $0.sessionRecord() }, selectedFileIDs: [guiFiles[1].id])
            _ = try await guiStore.create(guiWorkspace, document: guiDocument)
            var guiRecord = FileOperationRecord(workspaceID: guiWorkspace.id, kind: .save, items: guiFiles.enumerated().map { offset, file in
                var item = FileOperationItem(file: file)
                item.state = offset == 0 ? .completed : .failed
                item.result = offset == 0 ? file : nil
                item.message = offset == 0 ? "Saved" : "The source changed outside MacPicard. It was not overwritten."
                return item
            })
            guiRecord.state = .failed
            try await OperationHistoryStore().save(guiRecord, directory: await guiStore.operationDirectory(for: guiWorkspace.id))
        }
    }

    @MainActor func testRealNotificationsCoalesceIntoOneLibraryPublication() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try audio("source.mp3", in: root)
        let model = libraryModel(root, files: [file])
        model.restartLibraryMonitoring()
        defer { model.stopLibraryMonitoring() }
        let nested = try folder("Artist/Album", in: root)
        for index in 0..<20 {
            try FileManager.default.copyItem(at: file.url, to: nested.appendingPathComponent("\(index).mp3"))
        }
        // Wait for the actual recursive event stream and debounce, not an
        // injected notification. The invalid audio yields real per-file errors.
        for _ in 0..<80 {
            if model.files.count == 21 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(model.files.count, 21)
        XCTAssertEqual(model.scanPublicationCount, 1)
        XCTAssertEqual(model.file(id: file.id), file)
        let publications = model.scanPublicationCount, indexUpdates = model.browserIndexUpdates
        let activityCount = model.activity.count
        for _ in 0..<3 { await model.refreshLibrary(automatic: true) }
        XCTAssertEqual(model.scanPublicationCount, publications)
        XCTAssertEqual(model.browserIndexUpdates, indexUpdates)
        XCTAssertEqual(model.activity.count, activityCount, "Repeated failures must not flood Activity")
    }

    @MainActor func testMonitoringBurstCoalescesAndWaitsForEditsButManualRefreshWorks() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try audio("source.mp3", in: root)
        let model = libraryModel(root, files: [file])
        defer { model.stopLibraryMonitoring(); model.sessionSaveTask?.cancel() }
        let workspaceStore = WorkspaceStore(directory: root.appendingPathComponent("Workspaces"))
        _ = try await workspaceStore.create(try XCTUnwrap(model.activeWorkspace), document: model.makeSessionDocument())
        model.workspaceStore = workspaceStore
        let sessionStore = await workspaceStore.sessionStore(for: try XCTUnwrap(model.activeWorkspaceID))
        model.sessionManager = SessionManager(store: sessionStore)
        let originalWrites = await sessionStore.writeCount
        for _ in 0..<5 { await model.refreshLibrary(automatic: true) }
        XCTAssertEqual(model.scanPublicationCount, 0)
        XCTAssertEqual(model.browserIndexUpdates, 1)
        let noOpWrites = await sessionStore.writeCount
        XCTAssertEqual(noOpWrites, originalWrites)
        for _ in 0..<100 { model.enqueueLibraryChanges(.init(paths: [file.url])) }
        try await Task.sleep(for: .milliseconds(2300))
        XCTAssertEqual(model.scanPublicationCount, 0)
        model.setTagValues(["Pending"], for: "title")
        let newURL = root.appendingPathComponent("new.mp3")
        try FileManager.default.copyItem(at: file.url, to: newURL)
        for _ in 0..<100 { model.enqueueLibraryChanges(.init(paths: [newURL])) }
        try await Task.sleep(for: .milliseconds(2300))
        XCTAssertEqual(model.files.count, 1, "Pending edits defer monitoring")
        await model.refreshLibrary()
        XCTAssertEqual(model.files.count, 2, "Manual refresh remains effective")
        XCTAssertEqual(model.file(id: file.id)?.metadata.firstValue(for: "title"), "Pending")
        XCTAssertFalse(model.isWorking)
    }

    @MainActor func testFailedSaveHistoryRetryRequiresUnchangedBaseline() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var file = try audio("source.mp3", in: root)
        var tags = file.metadata; tags.setValue("Draft", for: "title"); try file.updateMetadata(tags)
        let model = libraryModel(root, files: [file])
        var item = FileOperationItem(file: file); item.state = .failed
        let record = FileOperationRecord(workspaceID: try XCTUnwrap(model.activeWorkspaceID), kind: .save, items: [item])
        XCTAssertEqual(model.retryableSaveIDs(record), [file.id])
        model.setTagValues(["Newer Draft"], for: "title")
        XCTAssertTrue(model.retryableSaveIDs(record).isEmpty)
        model.sessionSaveTask?.cancel()
    }

    @MainActor
    func testLibraryDefaultsToItsRootAndNeitherPreviewNorUnconfirmedExecutionMovesFiles() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try folder("Library", in: root), other = try folder("Other", in: root)
        let file = try audio("source.mp3", in: library)
        let model = libraryModel(library, files: [file])
        model.destinationDirectory = other
        model.beginOrganizationReview(); await model.refreshOrganizationPreview()
        XCTAssertEqual(model.organizationDirectory, library)
        let review = try XCTUnwrap(model.organizationReview)
        XCTAssertTrue(model.canExecuteOrganization)
        let unconfirmed = await model.executeOrganization(reviewID: review.id)
        XCTAssertFalse(unconfirmed)
        let wrongID = await model.executeOrganization(reviewID: UUID(), confirmed: true)
        XCTAssertFalse(wrongID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: other.path), [])
        model.cancelOrganizationReview()
        XCTAssertNil(model.organizationReview)
    }

    @MainActor
    func testEntireLibraryOrganizationIncludesFilesOutsideCurrentSelection() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try folder("Library", in: root)
        let first = try audio("first.mp3", in: library), second = try audio("second.mp3", in: library)
        let model = libraryModel(library, files: [first, second])
        model.selectedFileIDs = [first.id]
        model.searchQuery = "first"

        XCTAssertTrue(model.canOrganizeEntireLibrary)
        XCTAssertEqual(model.commandFileIDs(.library), [first.id, second.id])
        model.beginOrganizationReview(entireLibrary: true)
        await model.refreshOrganizationPreview()

        XCTAssertTrue(model.organizationTargetsEntireLibrary)
        XCTAssertEqual(model.organizationFiles.map(\.id), [first.id, second.id])
        XCTAssertEqual(model.organizationReview?.rows.map(\.id), [first.id, second.id])
    }

    @MainActor
    func testNoOpMonitoringDoesNotChangeForegroundStatusOrSelection() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try audio("source.mp3", in: root)
        let model = libraryModel(root, files: [file])
        model.statusMessage = "Editing title"
        model.errorMessage = "An earlier foreground warning"
        await model.refreshLibrary(automatic: true)
        XCTAssertEqual(model.files, [file])
        XCTAssertEqual(model.selectedFileIDs, [file.id])
        XCTAssertEqual(model.statusMessage, "Editing title")
        XCTAssertEqual(model.errorMessage, "An earlier foreground warning")
        XCTAssertNil(model.progress)
        XCTAssertFalse(model.isWorking)
    }

    @MainActor
    func testSessionWithoutDestinationShowsNoExecutablePreviewAndFolderChoiceNeverMoves() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = try folder("Destination", in: root), file = try audio("source.mp3", in: root)
        let model = AppModel(); model.files = [file]; model.selectedFileIDs = [file.id]
        model.beginOrganizationReview(); await model.refreshOrganizationPreview()
        XCTAssertNil(model.organizationDirectory); XCTAssertFalse(model.canExecuteOrganization)
        await model.chooseOrganizationDirectory(.success([destination]))
        await model.refreshOrganizationPreview()
        XCTAssertTrue(model.canExecuteOrganization)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
    }

    @MainActor
    func testReviewedMovePreservesEditsPersistsNewPathsAndExcludedItems() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try folder("Library", in: root)
        var first = try audio("first.mp3", in: library), second = try audio("second.mp3", in: library)
        var tags = first.metadata; tags.setValue("Pending title", for: "title"); try first.updateMetadata(tags)
        let model = libraryModel(library, files: [first, second])
        let store = SessionStore(sessionURL: root.appendingPathComponent("session.json"), recoveryURL: root.appendingPathComponent("recovery.json"))
        model.sessionManager = SessionManager(store: store)
        model.beginOrganizationReview(); model.organizationExcludedIDs = [second.id]
        await model.refreshOrganizationPreview()
        let review = try XCTUnwrap(model.organizationReview)
        let destination = try XCTUnwrap(review.rows.first { $0.id == first.id }?.destination)
        let moved = await model.executeOrganization(reviewID: review.id, confirmed: true)
        XCTAssertTrue(moved)
        let relocated = try XCTUnwrap(model.file(id: first.id))
        XCTAssertEqual(relocated.url, destination); XCTAssertTrue(relocated.isModified)
        XCTAssertEqual(relocated.metadata, first.metadata); XCTAssertEqual(relocated.originalMetadata, first.originalMetadata)
        XCTAssertEqual(try Data(contentsOf: destination), Data("first.mp3".utf8))
        XCTAssertEqual(model.file(id: second.id), second)
        let persisted = try await store.load()
        XCTAssertEqual(persisted?.files.first { $0.id == first.id }?.url, destination)
        XCTAssertEqual(persisted?.files.first { $0.id == first.id }?.metadata, first.metadata)
        XCTAssertFalse(model.isExecutingOrganization); XCTAssertNil(model.organizationReview)
    }

    @MainActor
    func testNewerMetadataSelectionOrWorkspaceInvalidatesReview() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try folder("Library", in: root), original = try audio("source.mp3", in: library)
        let model = libraryModel(library, files: [original])
        model.beginOrganizationReview(); await model.refreshOrganizationPreview()
        let review = try XCTUnwrap(model.organizationReview)
        var edited = original; var tags = edited.metadata; tags.setValue("Newer", for: "title"); try edited.updateMetadata(tags)
        model.files = [edited]
        XCTAssertFalse(model.canExecuteOrganization)
        let applied = await model.executeOrganization(reviewID: review.id, confirmed: true)
        XCTAssertFalse(applied); XCTAssertEqual(model.files, [edited])
        model.files = [original]; model.selectedFileIDs = []
        XCTAssertFalse(model.canExecuteOrganization)
        model.selectedFileIDs = [original.id]; model.activeWorkspaceID = UUID()
        XCTAssertFalse(model.canExecuteOrganization)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.url.path))
    }

    @MainActor
    func testNamingPolicyAndExclusionsInvalidateOldPreviewAndTagScriptIsIndependent() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try folder("Library", in: root), file = try audio("source.mp3", in: library)
        let model = libraryModel(library, files: [file])
        model.scriptSource = "$set(title,Do not apply this)"
        model.beginOrganizationReview(); await model.refreshOrganizationPreview()
        XCTAssertTrue(model.canExecuteOrganization)
        XCTAssertEqual(model.file(id: file.id)?.metadata, file.metadata)
        model.organizationConflictPolicy = .numbered; XCTAssertFalse(model.canExecuteOrganization)
        await model.refreshOrganizationPreview(); XCTAssertTrue(model.canExecuteOrganization)
        model.organizationNamingScript = "Another/%filename%"; XCTAssertFalse(model.canExecuteOrganization)
        await model.refreshOrganizationPreview(); XCTAssertTrue(model.canExecuteOrganization)
        model.organizationExcludedIDs = [file.id]; XCTAssertFalse(model.canExecuteOrganization)
        await model.refreshOrganizationPreview(); XCTAssertEqual(model.organizationReview?.moveCount, 0)
        XCTAssertEqual(model.scriptSource, "$set(title,Do not apply this)")
    }

    @MainActor
    func testOutsideLibraryRequiresExplicitAcknowledgmentBeyondMoveConfirmation() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try folder("Library", in: root), outside = try folder("Outside", in: root)
        let file = try audio("source.mp3", in: library), model = libraryModel(library, files: [])
        model.files = [file]; model.selectedFileIDs = [file.id]
        model.beginOrganizationReview(); model.organizationDirectory = outside
        await model.refreshOrganizationPreview()
        let review = try XCTUnwrap(model.organizationReview)
        XCTAssertEqual(model.organizationOutsideLibraryCount, 1)
        let refused = await model.executeOrganization(reviewID: review.id, confirmed: true)
        XCTAssertFalse(refused); XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
        let moved = await model.executeOrganization(reviewID: review.id, confirmed: true, allowOutsideLibrary: true)
        XCTAssertTrue(moved)
        XCTAssertNotNil(model.file(id: file.id))
        XCTAssertTrue(try XCTUnwrap(model.file(id: file.id)).url.path.hasPrefix(outside.path + "/"))
    }

    @MainActor
    func testPersistenceFailureAbortsBeforeAnyDiskMoves() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try folder("Library", in: root), file = try audio("source.mp3", in: library)
        let blocker = root.appendingPathComponent("blocker"); try Data([1]).write(to: blocker)
        let store = SessionStore(sessionURL: blocker.appendingPathComponent("session.json"), recoveryURL: root.appendingPathComponent("recovery.json"))
        let model = libraryModel(library, files: [file]); model.sessionManager = SessionManager(store: store)
        model.beginOrganizationReview(); await model.refreshOrganizationPreview()
        let review = try XCTUnwrap(model.organizationReview)
        let moved = await model.executeOrganization(reviewID: review.id, confirmed: true)
        XCTAssertFalse(moved); XCTAssertNotNil(model.organizationError)
        XCTAssertEqual(model.files, [file]); XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: library.path), ["source.mp3"])
    }

    @MainActor
    func testNewlyOrganizedDestinationsAreRemovedFromPersistedLibraryExclusions() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try folder("Library", in: root), file = try audio("source.mp3", in: library)
        let model = libraryModel(library, files: [file]), catalogStore = WorkspaceStore(directory: root.appendingPathComponent("Workspaces"))
        var workspace = try XCTUnwrap(model.activeWorkspace); workspace.excludedRelativePaths = ["Renamed.mp3", "Other.mp3"]
        _ = try await catalogStore.create(workspace, document: SessionDocument())
        model.workspaces = [workspace]; model.workspaceStore = catalogStore
        model.beginOrganizationReview(); model.organizationNamingScript = "Renamed"
        await model.refreshOrganizationPreview()
        let review = try XCTUnwrap(model.organizationReview)
        let moved = await model.executeOrganization(reviewID: review.id, confirmed: true)
        XCTAssertTrue(moved)
        XCTAssertEqual(model.activeWorkspace?.excludedRelativePaths, ["Other.mp3"])
        let catalog = try await WorkspaceStore(directory: root.appendingPathComponent("Workspaces")).load()
        XCTAssertEqual(catalog.workspaces.first?.excludedRelativePaths, ["Other.mp3"])
    }

    @MainActor
    func testRealAudioMoveKeepsPendingBaselineAndSupportsSubsequentTagSaveAndRefresh() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try folder("Library", in: root), url = library.appendingPathComponent("source.flac")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono", "-t", "1", "-c:a", "flac", "-metadata", "title=Original", url.path]
        process.standardOutput = Pipe(); process.standardError = Pipe(); try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        var file = try await AudioFileCoordinator().load(url: url)
        let before = try Data(contentsOf: url)
        var tags = file.metadata; tags.setValue("Renamed", for: "title"); try file.updateMetadata(tags)
        let model = libraryModel(library, files: [file])
        model.beginOrganizationReview(); model.organizationNamingScript = "%title%"
        await model.refreshOrganizationPreview()
        let review = try XCTUnwrap(model.organizationReview)
        let moved = await model.executeOrganization(reviewID: review.id, confirmed: true)
        XCTAssertTrue(moved)
        await model.refreshLibrary()
        let relocated = try XCTUnwrap(model.file(id: file.id))
        XCTAssertEqual(relocated.url.lastPathComponent, "Renamed.flac")
        XCTAssertEqual(relocated.metadata.firstValue(for: "title"), "Renamed")
        XCTAssertEqual(relocated.originalMetadata.firstValue(for: "title"), "Original")
        XCTAssertEqual(try Data(contentsOf: relocated.url), before)
        XCTAssertTrue(try AudioFileIdentity.capture(url: relocated.url).matches(relocated.identity))
        var discarded = relocated; try discarded.discardChanges()
        XCTAssertEqual(discarded.metadata.firstValue(for: "title"), "Original")
        XCTAssertEqual(discarded.url, relocated.url)
        let saved = try await AudioSaveCoordinator().save(relocated)
        let read = try await FormatEngine().read(url: saved.url)
        XCTAssertEqual(read.metadata.firstValue(for: "title"), "Renamed")
        XCTAssertFalse(saved.isModified)
    }

    @MainActor private func libraryModel(_ library: URL, files: [AudioFile]) -> AppModel {
        let model = AppModel(), workspace = MusicWorkspace(name: "Test Library", kind: .library, directory: library)
        model.workspaces = [workspace]; model.activeWorkspaceID = workspace.id
        model.files = files; model.selectedFileIDs = Set(files.map(\.id))
        return model
    }
    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacPicard-organization-model-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func folder(_ name: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(name); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    private func audio(_ name: String, in root: URL) throws -> AudioFile {
        let url = root.appendingPathComponent(name); try Data(name.utf8).write(to: url)
        var file = AudioFile(url: url); try file.beginLoading()
        try file.finishLoading(metadata: Metadata(fields: ["artist": ["Artist"], "album": ["Album"], "title": ["Title"], "tracknumber": ["1"]]), identity: AudioFileIdentity.capture(url: url))
        return file
    }
}
