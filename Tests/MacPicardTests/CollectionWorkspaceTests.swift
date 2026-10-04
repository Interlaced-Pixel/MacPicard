import PicardFoundation
import SwiftUI
import XCTest
@testable import MacPicard

final class CollectionWorkspaceTests: XCTestCase {
    @MainActor
    func testLargeCollectionEditUpdatesOnlyOneSearchEntryAndPreservesNavigation() throws {
        let model = AppModel()
        model.files = try (0..<2_000).map { index in
            var file = AudioFile(url: URL(fileURLWithPath: "/tmp/collection-\(index).flac"))
            try file.beginLoading()
            try file.finishLoading(metadata: Metadata(fields: ["title": ["Song \(index)"], "artist": ["Artist"], "album": ["Album \(index / 10)"]]),
                                   identity: AudioFileIdentity(resourceIdentifier: nil, byteCount: 1, modificationDate: nil, prefixHash: "fixture"))
            return file
        }
        let groups = model.albumGroups
        let first = try XCTUnwrap(model.files.first)
        model.navigateAlbum(try XCTUnwrap(groups.first))
        XCTAssertTrue(model.selectedFiles.isEmpty, "Browsing must not select an album for batch edits")
        model.selectionChanged([first.id])
        model.setTagValues(["Rock", "Soul"], for: "genre")
        XCTAssertEqual(model.browserIndexUpdates, 2_001)
        XCTAssertEqual(model.albumGroups, groups)
        XCTAssertEqual(model.selectedFileIDs, [first.id])
        model.searchQuery = "Soul"; model.applyBrowserSearch()
        XCTAssertEqual(model.visibleFiles.map(\.id), [first.id])
        model.sessionSaveTask?.cancel(); model.searchTask?.cancel()
    }
    @MainActor
    func testSearchIsDebouncedAndLatestQueryWins() async throws {
        let model = AppModel()
        model.searchQuery = "first"; model.searchQuery = "second"
        XCTAssertEqual(model.appliedSearchQuery, "")
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(model.appliedSearchQuery, "second")
    }
    @MainActor
    func testColumnSortAndToolbarPreferencesRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(); model.browserPreferencesURL = root.appendingPathComponent("browser.json")
        model.browserPreferences.columns[visibility: "album"] = .hidden
        model.browserPreferences.sort = "artist"; model.browserPreferences.descending = true
        model.browserPreferences.toolbarActions.remove("artwork"); model.saveBrowserPreferences()
        let next = AppModel(); next.browserPreferencesURL = model.browserPreferencesURL; next.loadBrowserPreferences()
        XCTAssertEqual(next.browserPreferences.columns[visibility: "album"], .hidden)
        XCTAssertEqual(next.browserPreferences.sort, "artist"); XCTAssertTrue(next.browserPreferences.descending)
        XCTAssertFalse(next.browserPreferences.toolbarActions.contains("artwork"))
    }
}
