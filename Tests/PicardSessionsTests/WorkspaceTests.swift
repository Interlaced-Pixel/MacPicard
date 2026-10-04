import Foundation
import PicardFormats
import PicardFoundation
import XCTest
@testable import PicardSessions

final class WorkspaceTests: XCTestCase {
    func testLegacySessionsMigrateWithoutMovingAudioOrRewritingSavedEdits() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeFixture(in: root)
        let sourceBytes = try Data(contentsOf: source)
        var file = try await AudioFileCoordinator().load(url: source)
        var tags = file.metadata
        tags.setValue("Pending title", for: "title")
        try file.updateMetadata(tags)
        var library = MusicWorkspace(name: "Album Repair")
        library.automaticallyRefreshes = false
        library.excludedRelativePaths = ["Hidden/track.flac"]
        var catalog = WorkspaceCatalog()
        catalog.schemaVersion = 1
        catalog.workspaces = [library]
        catalog.activeWorkspaceID = library.id
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(catalog)) as? [String: Any])
        var items = try XCTUnwrap(json["workspaces"] as? [[String: Any]])
        items[0]["kind"] = "session"
        items[0].removeValue(forKey: "directory")
        json["workspaces"] = items
        let catalogURL = root.appendingPathComponent("workspaces.json")
        try JSONSerialization.data(withJSONObject: json).write(to: catalogURL)
        let store = WorkspaceStore(directory: root)
        let documentStore = await store.sessionStore(for: library.id)
        let document = SessionDocument(files: [file.sessionRecord()], selectedFileIDs: [file.id], accessBookmarkKeys: ["old-source-access"])
        try await documentStore.save(document)
        var recovery = document
        recovery.selectedAlbumKey = "recover-this-album"
        try await documentStore.saveRecovery(recovery)
        let documentURL = root.appendingPathComponent(library.id.uuidString).appendingPathComponent("session.json")
        let recoveryURL = documentURL.deletingLastPathComponent().appendingPathComponent("recovery.json")
        let savedBytes = try Data(contentsOf: documentURL)
        let recoveryBytes = try Data(contentsOf: recoveryURL)
        let migrated = try await store.load()
        let entry = try XCTUnwrap(migrated.workspaces.first)
        XCTAssertEqual(migrated.schemaVersion, 2)
        XCTAssertEqual(migrated.activeWorkspaceID, library.id)
        XCTAssertEqual(entry.id, library.id)
        XCTAssertEqual(entry.name, library.name)
        XCTAssertEqual(entry.kind, .library)
        XCTAssertFalse(entry.automaticallyRefreshes)
        XCTAssertEqual(entry.excludedRelativePaths, library.excludedRelativePaths)
        let folder = try XCTUnwrap(entry.directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
        XCTAssertEqual(try Data(contentsOf: documentURL), savedBytes)
        XCTAssertEqual(try Data(contentsOf: recoveryURL), recoveryBytes)
        let restored = try await documentStore.load()
        XCTAssertEqual(restored?.files.first?.url, source)
        XCTAssertEqual(restored?.files.first?.metadata.firstValue(for: "title"), "Pending title")
        XCTAssertEqual(restored?.accessBookmarkKeys, ["old-source-access"])
        let catalogBytes = try Data(contentsOf: catalogURL)
        let reopened = try await WorkspaceStore(directory: root).load()
        XCTAssertEqual(reopened, migrated)
        XCTAssertEqual(try Data(contentsOf: catalogURL), catalogBytes, "Migration must not repeat on every launch.")
    }

    func testInvalidCatalogMigrationLeavesOriginalCatalogUntouched() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var catalog = WorkspaceCatalog()
        catalog.schemaVersion = 1
        catalog.workspaces = [MusicWorkspace(name: "Invalid", directory: URL(string: "https://example.com/music")!)]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let bytes = try encoder.encode(catalog)
        let url = root.appendingPathComponent("workspaces.json")
        try bytes.write(to: url)
        do { _ = try await WorkspaceStore(directory: root).load(); XCTFail("Remote folders cannot become libraries") }
        catch {}
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testIncrementalScanReadsOnlyHintedFileAndPreservesUnambiguousRename() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try makeFixture(in: root)
        let other = root.appendingPathComponent("other.flac")
        try FileManager.default.copyItem(at: first, to: other)
        let scanner = LibraryScanner()
        let initial = try await scanner.scan(directory: root, existing: [])
        XCTAssertEqual(initial.metadataReadCount, 2)
        let unchanged = try await scanner.scan(directory: root, existing: initial.files, affectedPaths: [first])
        XCTAssertEqual(unchanged.inspectedFileCount, 1)
        XCTAssertEqual(unchanged.metadataReadCount, 0)
        XCTAssertEqual(Set(unchanged.files.map(\.id)), Set(initial.files.map(\.id)))
        var pending = try XCTUnwrap(initial.files.first { $0.url == first })
        var tags = pending.metadata; tags.setValue("Keep this draft", for: "title")
        try pending.updateMetadata(tags)
        let renamed = root.appendingPathComponent("renamed.flac")
        try FileManager.default.moveItem(at: first, to: renamed)
        let baseline = initial.files.map { $0.id == pending.id ? pending : $0 }
        let report = try await scanner.scan(directory: root, existing: baseline, affectedPaths: [renamed])
        XCTAssertEqual(report.files.count, 2)
        let found = try XCTUnwrap(report.files.first { $0.id == pending.id })
        XCTAssertEqual(found.url, renamed)
        XCTAssertEqual(found.metadata.firstValue(for: "title"), "Keep this draft")
        XCTAssertTrue(found.isModified)
        XCTAssertEqual(report.metadataReadCount, 0)
    }

    func testScanDeltaCannotOverwriteNewerEditsImportsOrRemovals() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeFixture(in: root)
        let scanner = LibraryScanner()
        let initial = try await scanner.scan(directory: root, existing: [])
        let baseline = initial.files
        _ = try await FormatEngine().write(url: source, metadata: Metadata(fields: ["title": ["External"]]), artwork: ArtworkCollection())
        let newURL = root.appendingPathComponent("new.flac")
        try FileManager.default.copyItem(at: source, to: newURL)
        let report = try await scanner.scan(directory: root, existing: baseline)
        var current = baseline
        var tags = current[0].metadata; tags.setValue("Newer local edit", for: "title")
        try current[0].updateMetadata(tags)
        var imported = try XCTUnwrap(report.files.first { $0.url == newURL })
        tags = imported.metadata; tags.setValue("Imported draft", for: "title")
        try imported.updateMetadata(tags); current.append(imported)
        let merged = report.merging(baseline: baseline, current: current)
        XCTAssertEqual(merged, current)
        XCTAssertEqual(report.merging(baseline: baseline, current: [imported]), [imported], "Removed items must not be resurrected")
    }

    func testRepeatedMissingFileScanIsANoOpAndOfflineRootPreservesSnapshot() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeFixture(in: root)
        let scanner = LibraryScanner()
        let initial = try await scanner.scan(directory: root, existing: [])
        try FileManager.default.removeItem(at: source)
        let missing = try await scanner.scan(directory: root, existing: initial.files)
        let repeated = try await scanner.scan(directory: root, existing: missing.files)
        XCTAssertEqual(repeated.missingCount, 0)
        XCTAssertEqual(repeated.files, missing.files)
        do { _ = try await scanner.scan(directory: root.appendingPathComponent("offline"), existing: initial.files); XCTFail("Expected unavailable root") }
        catch { XCTAssertEqual(initial.files.count, 1) }
    }

    func testRealRecursiveFilesystemNotification() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let received = expectation(description: "Recursive FSEvents change")
        received.assertForOverFulfill = false
        let monitor = try LibraryDirectoryMonitor(directory: root) { hint in
            if hint.requiresFullScan || hint.paths.contains(where: { $0.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path) }) { received.fulfill() }
        }
        let nested = root.appendingPathComponent("Artist/Album")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("change hint, not audio".utf8).write(to: nested.appendingPathComponent("track.mp3"))
        await fulfillment(of: [received], timeout: 12)
        withExtendedLifetime(monitor) {}
    }

    func testIndependentWorkspaceDocumentsSurviveRestartAndRename() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(directory: root)
        let first = MusicWorkspace(name: "Tagging")
        let second = MusicWorkspace(name: "Music", kind: .library, directory: root)
        let file = AudioFile(url: root.appendingPathComponent("test.flac"))
        let document = SessionDocument(createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                       savedAt: Date(timeIntervalSince1970: 1_700_000_001),
                                       files: [file.sessionRecord()], selectedFileIDs: [file.id],
                                       selectedAlbumKey: "album", accessBookmarkKeys: ["folder-access"])
        let created = try await store.create(first, document: document)
        _ = try await store.create(second, document: SessionDocument())
        var renamed = try XCTUnwrap(created.workspaces.first)
        renamed.name = "Album Repair"
        _ = try await store.update(renamed)
        _ = try await store.activate(first.id)

        let reopened = WorkspaceStore(directory: root)
        let catalog = try await reopened.load()
        let firstStore = await reopened.sessionStore(for: first.id)
        let secondStore = await reopened.sessionStore(for: second.id)
        let firstDocument = try await firstStore.load()
        let secondDocument = try await secondStore.load()
        XCTAssertEqual(catalog.activeWorkspaceID, first.id)
        XCTAssertEqual(catalog.workspaces.first?.name, "Album Repair")
        XCTAssertEqual(firstDocument, document)
        XCTAssertEqual(secondDocument?.files.count, 0)
        do {
            _ = try await reopened.remove(first.id)
            XCTFail("Switch away before removing an active library when another library exists")
        } catch {}
        _ = try await reopened.remove(second.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        let retained = try await secondStore.load()
        XCTAssertNotNil(retained, "Removing a workspace must retain its saved document.")
        let empty = try await reopened.remove(first.id)
        XCTAssertTrue(empty.workspaces.isEmpty)
        XCTAssertNil(empty.activeWorkspaceID)
        let retainedFirst = try await firstStore.load()
        XCTAssertEqual(retainedFirst, document)
    }

    func testConcurrentWorkspaceCreationDoesNotLoseEntries() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(directory: root)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<12 {
                group.addTask {
                    _ = try await store.create(MusicWorkspace(name: "Library \(index)"),
                                               document: SessionDocument())
                }
            }
            try await group.waitForAll()
        }
        let catalog = try await WorkspaceStore(directory: root).load()
        XCTAssertEqual(catalog.workspaces.count, 12)
        XCTAssertEqual(Set(catalog.workspaces.map(\.id)).count, 12)
    }

    func testScanPreservesEditsAndIdentityAndRestoresMissingFiles() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeFixture(in: root)
        let scanner = LibraryScanner()
        let initial = try await scanner.scan(directory: root, existing: [])
        XCTAssertEqual(initial.addedCount, 1)
        var file = try XCTUnwrap(initial.files.first)
        var metadata = file.metadata
        metadata.setValue("Pending Title", for: "title")
        try file.updateMetadata(metadata)
        let unchanged = try await scanner.scan(directory: root, existing: [file])
        XCTAssertEqual(unchanged.files.first?.id, file.id)
        XCTAssertEqual(unchanged.files.first?.metadata.firstValue(for: "title"), "Pending Title")
        XCTAssertTrue(unchanged.files.first?.isModified == true)

        let bytes = try Data(contentsOf: source)
        try FileManager.default.removeItem(at: source)
        let missing = try await scanner.scan(directory: root, existing: unchanged.files)
        XCTAssertEqual(missing.missingCount, 1)
        XCTAssertEqual(missing.files.first?.state, .removed)
        XCTAssertTrue(missing.files.first?.isModified == true)
        try bytes.write(to: source)
        let restored = try await scanner.scan(directory: root, existing: missing.files)
        XCTAssertEqual(restored.files.first?.id, file.id)
        XCTAssertEqual(restored.files.first?.state, .changed)
        XCTAssertEqual(restored.files.first?.metadata.firstValue(for: "title"), "Pending Title")
    }

    func testRefreshDetectsNewFilesAndExternalEditsWithoutOverwritingPendingTags() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeFixture(in: root)
        let scanner = LibraryScanner()
        let initial = try await scanner.scan(directory: root, existing: [])
        var pending = try XCTUnwrap(initial.files.first)
        var metadata = pending.metadata
        metadata.setValue("Local edit", for: "title")
        try pending.updateMetadata(metadata)
        let engine = FormatEngine()
        _ = try await engine.write(url: source, metadata: Metadata(fields: ["title": ["Disk edit"]]),
                                   artwork: ArtworkCollection())
        let second = root.appendingPathComponent("second.flac")
        try FileManager.default.copyItem(at: source, to: second)
        let report = try await scanner.scan(directory: root, existing: [pending])
        XCTAssertEqual(report.addedCount, 1)
        XCTAssertEqual(report.conflicts.count, 1)
        XCTAssertEqual(report.files.first(where: { $0.id == pending.id })?.metadata.firstValue(for: "title"), "Local edit")

        let unmodifiedReport = try await scanner.scan(directory: root, existing: initial.files)
        XCTAssertEqual(unmodifiedReport.updatedCount, 1)
        XCTAssertEqual(unmodifiedReport.files.first(where: { $0.id == pending.id })?.metadata.firstValue(for: "title"), "Disk edit")
    }

    func testOfflineRootFailsAndEnumerationDeduplicatesAndSkipsSymlinks() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeFixture(in: root)
        let hidden = root.appendingPathComponent(".hidden.flac")
        try FileManager.default.copyItem(at: source, to: hidden)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.flac"), withDestinationURL: source)
        let scanner = LibraryScanner()
        let expanded = try await scanner.expand([root, source])
        XCTAssertEqual(expanded, [source.resolvingSymlinksInPath().standardizedFileURL])
        do {
            _ = try await scanner.scan(directory: root.appendingPathComponent("offline"), existing: [])
            XCTFail("An offline folder must fail instead of returning an empty library")
        } catch {}
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacPicard-workspace-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeFixture(in root: URL) throws -> URL {
        let output = root.appendingPathComponent("track.flac")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
                             "anullsrc=r=44100:cl=mono", "-t", "0.1", "-c:a", "flac", output.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw XCTSkip("ffmpeg is required to create an audio fixture") }
        return output
    }
}
