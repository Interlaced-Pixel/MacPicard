import Foundation
import PicardFormats
import PicardFoundation
import PicardSessions
import XCTest
@testable import MacPicard

final class OrganizationModelTests: XCTestCase {
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
