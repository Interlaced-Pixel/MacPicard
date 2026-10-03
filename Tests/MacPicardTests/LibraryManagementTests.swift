import Foundation
import PicardFormats
import PicardFoundation
import PicardSessions
import XCTest
@testable import MacPicard

final class LibraryManagementTests: XCTestCase {
    @MainActor
    func testLibraryFolderImportCopiesDeduplicatesAndSurvivesSourceRemovalAndRestart() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = try directory(in: root, name: "Sources")
        let source = try fixture(in: sources)
        let (model, workspace, store) = try await libraryModel(in: root)
        defer { model.sessionSaveTask?.cancel(); model.libraryScanTask?.cancel() }
        await model.importURLs(expanding: [sources, source])
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.files.count, 1)
        let file = try XCTUnwrap(model.files.first)
        XCTAssertEqual(LibraryPaths.relativePath(of: file.url, in: try XCTUnwrap(workspace.directory)), "Artist/Album/01 - Song.flac")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        await model.importURLs(expanding: [source])
        XCTAssertEqual(model.files.count, 1)
        XCTAssertEqual(model.files.first?.id, file.id)
        XCTAssertTrue(model.statusMessage.contains("already in the library"))
        XCTAssertTrue(model.accessBookmarkKeys.isEmpty, "Managed copies must not depend on access to the source folder.")
        try FileManager.default.removeItem(at: sources)
        let document = try await store.sessionStore(for: workspace.id).load()
        XCTAssertEqual(document?.files.first?.url, file.url)
        let reloaded = try await LibraryScanner().scan(directory: try XCTUnwrap(workspace.directory), existing: [file])
        XCTAssertEqual(reloaded.files.first?.id, file.id)
        XCTAssertEqual(reloaded.missingCount, 0)
    }

    @MainActor
    func testSessionImportReferencesOriginalsAndRemovalDoesNotDeleteThem() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root)
        let original = try Data(contentsOf: source)
        let model = AppModel(audioCoordinator: AudioFileCoordinator())
        defer { model.sessionSaveTask?.cancel() }
        let session = MusicWorkspace(name: "Tagging", kind: .session)
        model.workspaces = [session]; model.activeWorkspaceID = session.id
        await model.importURLs(expanding: [source])
        XCTAssertEqual(model.files.first?.url, source)
        let ids = Set(model.files.map(\.id))
        XCTAssertFalse(model.canTrash(ids), "Session originals must not expose the library Trash action.")
        await model.removeFiles(ids)
        XCTAssertEqual(model.files.count, 1, "Removal requires confirmation.")
        await model.removeFiles(ids, confirmed: true)
        XCTAssertTrue(model.files.isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    @MainActor
    func testRemovedLibraryTracksStayExcludedAfterRefreshAndRestartAndCanBeRestored() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root)
        let (model, workspace, store) = try await libraryModel(in: root)
        defer { model.sessionSaveTask?.cancel(); model.libraryScanTask?.cancel(); model.playback.stop(clearQueue: true) }
        await model.importURLs(expanding: [source])
        let file = try XCTUnwrap(model.files.first)
        model.playback.enqueue([PlaybackTrack(file)])
        await model.removeFiles([file.id], confirmed: true)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.files.isEmpty)
        XCTAssertTrue(model.playback.queue.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
        await model.refreshLibrary()
        XCTAssertTrue(model.files.isEmpty, "Refresh must not bring removed items back.")
        let reloadedStore = WorkspaceStore(directory: root.appendingPathComponent("Catalog"))
        let catalog = try await reloadedStore.load()
        let saved = try XCTUnwrap(catalog.workspaces.first)
        XCTAssertEqual(saved.excludedRelativePaths, ["Artist/Album/01 - Song.flac"])
        let storedSession = try await store.sessionStore(for: workspace.id).load()
        let staleFile = AudioFile.restore(from: file.sessionRecord())
        let scan = try await LibraryScanner().scan(directory: try XCTUnwrap(saved.directory), existing: [staleFile],
                                                   excludingRelativePaths: saved.excludedRelativePaths)
        XCTAssertTrue(scan.files.isEmpty, "Exclusions also prune stale recovery-session records.")
        XCTAssertTrue(storedSession?.files.isEmpty == true)
        let reopened = AppModel()
        reopened.workspaces = catalog.workspaces; reopened.activeWorkspaceID = saved.id
        reopened.restoreSession(LoadedSession(document: SessionDocument(files: [file.sessionRecord()], selectedFileIDs: [file.id]), source: .recovery))
        XCTAssertTrue(reopened.files.isEmpty, "Removed tracks must stay hidden before the first scan, even with a stale recovery document.")
        XCTAssertTrue(reopened.selectedFileIDs.isEmpty)
        await model.restoreExcludedLibraryItems()
        XCTAssertEqual(model.files.count, 1)
        XCTAssertTrue(model.activeWorkspace?.excludedRelativePaths.isEmpty == true)
    }

    @MainActor
    func testExplicitReimportRestoresAnExcludedItemWithoutCopyingAgain() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root)
        let (model, _, _) = try await libraryModel(in: root)
        defer { model.sessionSaveTask?.cancel(); model.libraryScanTask?.cancel() }
        await model.importURLs(expanding: [source])
        let file = try XCTUnwrap(model.files.first)
        await model.removeFiles([file.id], confirmed: true)
        await model.importURLs(expanding: [source])
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.files.count, 1)
        XCTAssertEqual(model.files.first?.url, file.url)
        XCTAssertTrue(model.activeWorkspace?.excludedRelativePaths.isEmpty == true)
        await model.refreshLibrary()
        XCTAssertEqual(model.files.count, 1)
    }

    @MainActor
    func testUnconfirmedTrashLeavesFilesAndLibraryCatalogUntouched() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root)
        let (model, _, _) = try await libraryModel(in: root)
        defer { model.sessionSaveTask?.cancel(); model.libraryScanTask?.cancel() }
        await model.importURLs(expanding: [source])
        let file = try XCTUnwrap(model.files.first)
        XCTAssertTrue(model.canTrash([file.id]))
        await model.removeFiles([file.id], movingToTrash: true)
        XCTAssertEqual(model.files.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
        XCTAssertTrue(model.activeWorkspace?.excludedRelativePaths.isEmpty == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    @MainActor
    func testTrashFailureRetainsChangedFilesInTheLibrary() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root)
        let (model, _, _) = try await libraryModel(in: root)
        defer { model.sessionSaveTask?.cancel(); model.libraryScanTask?.cancel() }
        await model.importURLs(expanding: [source])
        let file = try XCTUnwrap(model.files.first)
        var changed = file
        var metadata = changed.metadata
        metadata.setValue("Externally changed", for: "title")
        try changed.updateMetadata(metadata)
        _ = try await AudioSaveCoordinator().save(changed)
        await model.removeFiles([file.id], movingToTrash: true, confirmed: true)
        XCTAssertEqual(model.files.count, 1)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.activeWorkspace?.excludedRelativePaths.isEmpty == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    @MainActor
    func testRemovingCurrentAndLastLibraryLeavesMusicAndRetainsRecoveryDocument() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root)
        let (model, workspace, store) = try await libraryModel(in: root)
        defer { model.sessionSaveTask?.cancel(); model.libraryScanTask?.cancel() }
        await model.importURLs(expanding: [source])
        let file = try XCTUnwrap(model.files.first)
        model.setMetadata("title", value: "Pending before library removal")
        await model.removeWorkspace(workspace)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.workspaces.count, 1)
        XCTAssertEqual(model.activeWorkspace?.kind, .session)
        XCTAssertTrue(model.files.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let retained = try await store.sessionStore(for: workspace.id).load()
        XCTAssertEqual(retained?.files.first?.metadata.firstValue(for: "title"), "Pending before library removal")
    }

    func testLegacyWorkspaceCatalogDecodesWithoutExclusionField() throws {
        let original = MusicWorkspace(name: "Existing", kind: .library, directory: URL(fileURLWithPath: "/tmp/Library"))
        let data = try JSONEncoder().encode(original)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "excludedRelativePaths")
        let restored = try JSONDecoder().decode(MusicWorkspace.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(restored, original)
        XCTAssertTrue(restored.excludedRelativePaths.isEmpty)
    }

    @MainActor
    private func libraryModel(in root: URL) async throws -> (AppModel, MusicWorkspace, WorkspaceStore) {
        let directory = try directory(in: root, name: "Library")
        let store = WorkspaceStore(directory: root.appendingPathComponent("Catalog"))
        let workspace = MusicWorkspace(name: "Music Library", kind: .library, directory: directory)
        let catalog = try await store.create(workspace, document: SessionDocument())
        let model = AppModel(audioCoordinator: AudioFileCoordinator())
        model.workspaceStore = store; model.workspaces = catalog.workspaces; model.activeWorkspaceID = workspace.id
        model.sessionManager = SessionManager(store: await store.sessionStore(for: workspace.id))
        return (model, workspace, store)
    }

    private func directory(in parent: URL = FileManager.default.temporaryDirectory, name: String = "MacPicard-management-tests-\(UUID())") throws -> URL {
        let result = parent.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }

    private func fixture(in root: URL) throws -> URL {
        let output = root.appendingPathComponent("source.flac")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono",
                             "-t", "0.1", "-c:a", "flac", "-metadata", "artist=Artist", "-metadata", "album=Album",
                             "-metadata", "title=Song", "-metadata", "track=1", output.path]
        process.standardOutput = Pipe(); process.standardError = Pipe()
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw XCTSkip("ffmpeg is needed for real audio fixtures") }
        return output
    }
}
