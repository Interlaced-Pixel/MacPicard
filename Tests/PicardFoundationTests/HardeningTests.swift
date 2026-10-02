import Foundation
import XCTest
@testable import PicardFoundation

final class FoundationHardeningTests: XCTestCase {
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
