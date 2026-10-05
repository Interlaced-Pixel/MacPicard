import PicardFoundation
import PicardSessions
import SwiftUI
import XCTest
@testable import MacPicard

final class CollectionWorkspaceTests: XCTestCase {
    @MainActor
    func testLargeSavedSelectionRestoresOnlyValidIDs() throws {
        let model = AppModel()
        let files = try (0..<5_000).map { index in
            var file = AudioFile(url: URL(fileURLWithPath: "/tmp/restored-selection-\(index).flac"))
            try file.beginLoading()
            try file.finishLoading(metadata: Metadata(fields: ["title": ["Song \(index)"]]),
                identity: AudioFileIdentity(resourceIdentifier: nil, byteCount: 1, modificationDate: nil, prefixHash: "fixture"))
            return file
        }
        let valid = Set(files.map(\.id)), unknown = UUID()
        let document = SessionDocument(files: files.map { $0.sessionRecord() }, selectedFileIDs: Array(valid.union([unknown])))
        model.restoreSession(LoadedSession(document: document, source: .primary))
        XCTAssertEqual(model.selectedFileIDs, valid)
        XCTAssertFalse(model.selectedFileIDs.contains(unknown))
        model.sessionSaveTask?.cancel()
    }
    @MainActor
    func testIdentityOnlyChangeInvalidatesIndexedFileAndSelection() throws {
        let model = AppModel()
        var file = AudioFile(url: URL(fileURLWithPath: "/tmp/identity-only.flac"))
        try file.beginLoading()
        try file.finishLoading(metadata: Metadata(fields: ["title": ["Original"]]), identity: AudioFileIdentity(resourceIdentifier: "old", byteCount: 1, modificationDate: nil, prefixHash: "old"))
        model.files = [file]; model.selectedFileIDs = [file.id]
        _ = model.selectedFiles
        let groups = model.albumGroups
        let identity = AudioFileIdentity(resourceIdentifier: "new", byteCount: 2, modificationDate: nil, prefixHash: "new")
        try file.updateURL(file.url, identity: identity)
        model.publishFileEdits([file], changedIDs: [file.id])
        XCTAssertEqual(model.file(id: file.id)?.identity, identity)
        XCTAssertEqual(model.selectedFiles.first?.identity, identity)
        XCTAssertEqual(model.albumGroups, groups)
        XCTAssertEqual(model.browserIndexUpdates, 2)
    }
    @MainActor
    func testCachedProjectionReordersEditsUpdatesWidthsAndRespondsToFilters() throws {
        let model = AppModel()
        model.files = try ["Zulu", "Alpha", "Middle"].enumerated().map { index, title in
            var file = AudioFile(url: URL(fileURLWithPath: "/tmp/projection-\(index).flac"))
            try file.beginLoading()
            try file.finishLoading(metadata: Metadata(fields: ["title": [title]]), identity: AudioFileIdentity(resourceIdentifier: nil, byteCount: 1, modificationDate: nil, prefixHash: "test"))
            return file
        }
        let sort = [KeyPathComparator(\CollectionTrack.title)]
        XCTAssertEqual(model.collectionProjection(sortOrder: sort).rows.map(\.title), ["Alpha", "Middle", "Zulu"])
        let first = try XCTUnwrap(model.files.first)
        model.selectedFileIDs = [first.id]
        model.setTagValues(["Aardvark"], for: "title")
        XCTAssertEqual(model.collectionProjection(sortOrder: sort).rows.map(\.title), ["Aardvark", "Alpha", "Middle"])
        model.setTagValues([String(repeating: "Z", count: 100)], for: "title")
        XCTAssertEqual(model.collectionProjection(sortOrder: sort).titleWidth, 420)
        model.setTagValues(["Short"], for: "title")
        XCTAssertEqual(model.collectionProjection(sortOrder: sort).titleWidth, 210)
        model.browserFilter = .modified
        XCTAssertEqual(model.collectionProjection(sortOrder: sort).rows.map(\.id), [first.id])
        model.browserFilter = .all
        XCTAssertEqual(model.collectionProjection(sortOrder: sort).rows.count, 3)
        model.sessionSaveTask?.cancel()
    }
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
    func testSearchAtTenThousandTracksStaysWithinInteractiveBudget() throws {
        let model = AppModel()
        model.files = try (0..<10_000).map { index in
            var file = AudioFile(url: URL(fileURLWithPath: "/tmp/scale-\(index).flac"))
            try file.beginLoading()
            try file.finishLoading(
                metadata: Metadata(fields: [
                    "title": ["Track \(index)"],
                    "artist": ["Artist \(index % 100)"],
                    "album": ["Album \(index / 10)"],
                    "genre": [index == 9_999 ? "Needle" : "Pop"]
                ]),
                identity: AudioFileIdentity(resourceIdentifier: nil, byteCount: 1, modificationDate: nil, prefixHash: "fixture")
            )
            return file
        }

        model.searchQuery = "Needle"
        let clock = ContinuousClock()
        let start = clock.now
        model.applyBrowserSearch()
        let elapsed = start.duration(to: clock.now)

        XCTAssertLessThan(elapsed, .milliseconds(300), "Indexed search exceeded the interactive search budget")
        XCTAssertEqual(model.visibleFiles.count, 1)
        XCTAssertEqual(model.visibleFiles.first?.metadata.firstValue(for: "title"), "Track 9999")
        model.sessionSaveTask?.cancel()
        model.searchTask?.cancel()
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
