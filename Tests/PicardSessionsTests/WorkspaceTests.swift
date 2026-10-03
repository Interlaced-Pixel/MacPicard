import Foundation
import PicardFormats
import PicardFoundation
import XCTest
@testable import PicardSessions

final class WorkspaceTests: XCTestCase {
    func testIndependentWorkspaceDocumentsSurviveRestartAndRename() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(directory: root)
        let first = MusicWorkspace(name: "Tagging", kind: .session)
        let second = MusicWorkspace(name: "Music", kind: .library, directory: root)
        let file = AudioFile(url: root.appendingPathComponent("test.flac"))
        let document = SessionDocument(files: [file.sessionRecord()], selectedFileIDs: [file.id],
                                       selectedAlbumKey: "album", accessBookmarkKeys: ["folder-access"])
        _ = try await store.create(first, document: document)
        _ = try await store.create(second, document: SessionDocument())
        var renamed = first
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
        _ = try await reopened.remove(second.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        let retained = try await secondStore.load()
        XCTAssertNotNil(retained, "Removing a workspace must retain its saved document.")
        do {
            _ = try await reopened.remove(first.id)
            XCTFail("The active workspace must not be removed")
        } catch {}
    }

    func testConcurrentWorkspaceCreationDoesNotLoseEntries() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(directory: root)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<12 {
                group.addTask {
                    _ = try await store.create(MusicWorkspace(name: "Session \(index)", kind: .session),
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
