import Foundation
import XCTest
@testable import PicardFoundation

final class PerformancePersistenceTests: XCTestCase {
    private func fixture(_ artwork: ArtworkCollection = .init()) throws -> AudioFile {
        var file = AudioFile(url: URL(fileURLWithPath: "/tmp/blob-fixture.flac"))
        try file.beginLoading()
        try file.finishLoading(metadata: Metadata(fields: ["title": ["Original"]]), artwork: artwork,
            identity: AudioFileIdentity(resourceIdentifier: nil, byteCount: 1, modificationDate: nil, prefixHash: "test"))
        return file
    }
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    func testArtworkIsDeduplicatedAndCorruptOrMissingReferencesFailClosed() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("session.json"), recovery = root.appendingPathComponent("recovery.json")
        let art = Artwork(mimeType: "image/png", source: .generated, data: Data(repeating: 23, count: 256 * 1024))
        let file = try fixture(.init(images: [art]))
        let document = SessionDocument(files: Array(repeating: file.sessionRecord(), count: 20))
        let store = SessionStore(sessionURL: url, recoveryURL: recovery)
        try await store.save(document)
        let blobDirectory = root.appendingPathComponent("ArtworkBlobs")
        let blobs = try FileManager.default.contentsOfDirectory(at: blobDirectory, includingPropertiesForKeys: nil)
        XCTAssertEqual(blobs.count, 1)
        XCTAssertLessThan(try Data(contentsOf: url).count, 100_000)
        let loaded = try await SessionStore(sessionURL: url, recoveryURL: recovery).load()
        XCTAssertEqual(loaded?.files, document.files)
        try Data([99]).write(to: blobs[0], options: .atomic)
        do { _ = try await SessionStore(sessionURL: url, recoveryURL: recovery).load(); XCTFail("Corrupt blobs must not become empty artwork") } catch {}
        try FileManager.default.removeItem(at: blobs[0])
        do { _ = try await SessionStore(sessionURL: url, recoveryURL: recovery).load(); XCTFail("Missing blobs must not become empty artwork") } catch {}
    }
    func testNavigationWritesOnlySidecarAndOldGenerationsCannotOverrideNewSnapshot() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("session.json"), recovery = root.appendingPathComponent("recovery.json")
        let store = SessionStore(sessionURL: url, recoveryURL: recovery)
        var file = try fixture()
        var document = SessionDocument(files: [file.sessionRecord()])
        try await store.save(document)
        let snapshot = try Data(contentsOf: url)
        document.selectedFileIDs = [file.id]; document.selectedAlbumKey = "Sidecar selection"
        try await store.save(document)
        XCTAssertEqual(try Data(contentsOf: url), snapshot)
        let restarted = SessionStore(sessionURL: url, recoveryURL: recovery)
        let loaded = try await restarted.load()
        XCTAssertEqual(loaded?.selectedFileIDs, [file.id]); XCTAssertEqual(loaded?.selectedAlbumKey, "Sidecar selection")
        var tags = file.metadata; tags.setValue("New snapshot", for: "title"); try file.updateMetadata(tags)
        document.files = [file.sessionRecord()]; document.selectedAlbumKey = "New selection"
        try await store.save(document)
        let newest = try await SessionStore(sessionURL: url, recoveryURL: recovery).load()
        XCTAssertEqual(newest?.selectedAlbumKey, "New selection")
        XCTAssertEqual(newest?.files.first?.metadata.firstValue(for: "title"), "New snapshot")
        try Data("torn navigation".utf8).write(to: url.appendingPathExtension("navigation"))
        let fallback = try await SessionStore(sessionURL: url, recoveryURL: recovery).load()
        XCTAssertEqual(fallback?.files, document.files)
    }
    func testLegacyInlineArtworkRemainsReadableAndConvertsOnNextChangedSave() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("session.json"), recovery = root.appendingPathComponent("recovery.json")
        let art = Artwork(mimeType: "image/png", source: .embedded, data: Data([1, 2, 3]))
        let file = try fixture(.init(images: [art]))
        let legacy = SessionDocument(schemaVersion: 1, files: [file.sessionRecord()])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(legacy).write(to: url)
        let store = SessionStore(sessionURL: url, recoveryURL: recovery)
        let loadedDocument = try await store.load()
        var loaded = try XCTUnwrap(loadedDocument)
        XCTAssertEqual(loaded.schemaVersion, SessionDocument.currentSchemaVersion)
        XCTAssertEqual(loaded.files.first?.artwork, file.artwork)
        loaded.selectedAlbumKey = "Changed"
        try await store.save(loaded)
        XCTAssertTrue(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("blobHash"))
        let roundTrip = try await SessionStore(sessionURL: url, recoveryURL: recovery).load()
        XCTAssertEqual(roundTrip?.files, legacy.files)
    }
    func testBlobPathsCannotEscapeTheirDirectory() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ArtworkBlobStore(directory: root)
        XCTAssertThrowsError(try store.load("../outside"))
        XCTAssertThrowsError(try store.store(Data([1]), hash: String(repeating: "a", count: 64)))
    }
    func testSaveDoesNotReplaceAnExistingFutureArchive() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("future.json")
        let future = SessionDocument(schemaVersion: 99, files: [try fixture().sessionRecord()])
        let data = try JSONEncoder().encode(future); try data.write(to: url)
        let store = SessionStore(sessionURL: url, recoveryURL: root.appendingPathComponent("recovery.json"))
        do { try await store.save(SessionDocument()); XCTFail("A new snapshot must not replace a future archive") } catch {}
        XCTAssertEqual(try Data(contentsOf: url), data)
    }
}
