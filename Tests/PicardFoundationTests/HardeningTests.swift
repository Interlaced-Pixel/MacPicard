import Foundation
import XCTest
@testable import PicardFoundation

final class FoundationHardeningTests: XCTestCase {
    func testArtworkHashCacheDoesNotPoisonIndependentCopies() throws {
        let original = Artwork(mimeType: "image/png", source: .embedded, data: Data([1, 2, 3]))
        let originalHash = try XCTUnwrap(original.contentHash)
        var copy = original
        copy.data = Data([4, 5, 6])
        XCTAssertNotEqual(copy.contentHash, originalHash)
        XCTAssertEqual(original.contentHash, originalHash)
        copy.data = nil
        XCTAssertNil(copy.contentHash)
        XCTAssertEqual(original.contentHash, originalHash)
    }
    func testIdentityMatchesJSONTimestampPrecisionButRejectsRealChanges() throws {
        let precise = Date(timeIntervalSinceReferenceDate: 813_152_099.1234567)
        let identity = AudioFileIdentity(resourceIdentifier: "inode", byteCount: 123,
                                         modificationDate: precise, prefixHash: "hash")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let restored = try decoder.decode(AudioFileIdentity.self, from: encoder.encode(identity))
        XCTAssertTrue(identity.matches(restored))
        XCTAssertFalse(identity.matches(nil))
        XCTAssertFalse(identity.matches(AudioFileIdentity(resourceIdentifier: "inode", byteCount: 124,
                                                          modificationDate: precise, prefixHash: "hash")))
        XCTAssertFalse(identity.matches(AudioFileIdentity(resourceIdentifier: "inode", byteCount: 123,
                                                          modificationDate: precise, prefixHash: "changed")))
        XCTAssertFalse(identity.matches(AudioFileIdentity(resourceIdentifier: "replaced", byteCount: 123,
                                                          modificationDate: precise, prefixHash: "hash")))
        XCTAssertFalse(identity.matches(AudioFileIdentity(resourceIdentifier: "inode", byteCount: 123,
                                                          modificationDate: precise.addingTimeInterval(0.001), prefixHash: "hash")))
        let data = try encoder.encode(SessionDocument(createdAt: precise, savedAt: precise))
        XCTAssertEqual(try SessionMigrator.migrate(data), data, "Current sessions must not be reserialized during migration")
    }

    func testPrepareRejectsAnApplicationSupportPathOccupiedByAFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacPicard-path-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let occupiedPath = root.appendingPathComponent("occupied")
        try Data("not a directory".utf8).write(to: occupiedPath)
        let paths = AppPaths(applicationSupportDirectory: occupiedPath)

        XCTAssertThrowsError(try paths.prepare()) { error in
            guard case PicardError.fileSystem = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testSecurityScopedBookmarkRoundTripPreservesTheSelectedURL() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacPicard-bookmark-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("selection.txt")
        try Data("bookmark".utf8).write(to: file)
        let store = SecurityScopedBookmarkStore(
            fileURL: root.appendingPathComponent("bookmarks.json")
        )

        do {
            try await store.save(url: file, for: "selection", readOnly: true)
            let access = try await store.resolve(key: "selection")
            defer { access.stopAccessing() }
            XCTAssertEqual(access.url.standardizedFileURL, file.standardizedFileURL)
        } catch {
            throw XCTSkip("The host does not grant security-scoped bookmarks for temporary URLs: \(error)")
        }
    }
}
