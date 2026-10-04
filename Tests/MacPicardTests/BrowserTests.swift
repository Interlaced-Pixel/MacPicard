import Foundation
import PicardFoundation
import PicardSessions
import PicardMusicBrainz
import XCTest
@testable import MacPicard

final class BrowserTests: XCTestCase {
    @MainActor
    func testReleaseMetadataUsesMatchedSongNotSelectionOffsetAndCorrectMBIDs() async throws {
        let data = Data(#"{"id":"11111111-1111-1111-1111-111111111111","title":"Album","artist-credit":[{"name":"Alice"}],"media":[{"position":1,"tracks":[{"id":"track-one","number":"1","position":1,"title":"First Song","artist-credit":[{"name":"Alice"}],"recording":{"id":"recording-one"}},{"id":"track-two","number":"2","position":2,"title":"Second Song","artist-credit":[{"name":"Alice"}],"recording":{"id":"recording-two","isrcs":["USAAA1234567"]}}]}]}"#.utf8)
        let client = MusicBrainzClient(userAgent: "Tests/1.0", transport: ReleaseTransport(data: data), minimumRequestInterval: .zero)
        let model = AppModel(musicBrainzClient: client)
        let file = try audioFile(title: "Second Song", artist: "Alice", album: "Album", track: "2/2")
        model.files = [file]
        model.selectionChanged([file.id])
        let release = try await client.lookupRelease(id: "11111111-1111-1111-1111-111111111111")
        let match = try XCTUnwrap(ReleaseMatcher().rank(local: LocalAlbumCandidate(metadata: file.metadata), candidates: [release.summary]).first)
        model.errorMessage = "Previous API failure"
        await model.chooseMatch(match)
        XCTAssertNil(model.errorMessage, "Successful retries must clear the old error banner")
        model.applySelectedRelease()
        let metadata = try XCTUnwrap(model.files.first?.metadata)
        XCTAssertEqual(metadata.firstValue(for: "title"), "Second Song")
        XCTAssertEqual(metadata.firstValue(for: "musicbrainz_trackid"), "recording-two")
        XCTAssertEqual(metadata.firstValue(for: "musicbrainz_releasetrackid"), "track-two")
        XCTAssertNil(metadata.firstValue(for: "musicbrainz_recordingid"))
        XCTAssertEqual(LocalTrackCandidate(metadata: metadata).recordingID, "recording-two")
    }

    @MainActor
    func testLibraryMatchProposalStagesMatchedMetadataWithoutWritingAudio() async throws {
        let data = Data(#"{"id":"11111111-1111-1111-1111-111111111111","title":"Album","artist-credit":[{"name":"Alice"}],"media":[{"position":1,"tracks":[{"id":"track-one","number":"1","position":1,"title":"First Song","length":180000,"artist-credit":[{"name":"Alice"}],"recording":{"id":"recording-one"}},{"id":"track-two","number":"2","position":2,"title":"Second Song","length":180000,"artist-credit":[{"name":"Alice"}],"recording":{"id":"recording-two"}}]}]}"#.utf8)
        let client = MusicBrainzClient(userAgent: "Tests/1.0", transport: ReleaseTransport(data: data), minimumRequestInterval: .zero)
        let model = AppModel(musicBrainzClient: client)
        let file = try audioFile(title: "Second Song", artist: "Alice", album: "Album", track: "2/2")
        model.files = [file]
        let release = try await client.lookupRelease(id: "11111111-1111-1111-1111-111111111111")
        let local = LocalAlbumCandidate(metadata: file.metadata, tracks: [LocalTrackCandidate(metadata: file.metadata, id: file.id)])
        let result = try XCTUnwrap(ReleaseMatcher().rank(local: local, candidates: [release]).first)
        let proposal = AppModel.LibraryMatchProposal(
            id: "alice\u{1F}album",
            albumTitle: "Album",
            artist: "Alice",
            fileIDs: [file.id],
            result: result,
            release: release,
            status: .matched,
            errorMessage: nil
        )

        XCTAssertEqual(model.applyLibraryMatches([proposal]), 1)
        XCTAssertEqual(model.files.first?.metadata.firstValue(for: "title"), "Second Song")
        XCTAssertEqual(model.files.first?.metadata.firstValue(for: "musicbrainz_trackid"), "recording-two")
        XCTAssertTrue(model.files.first?.isModified == true)
        XCTAssertEqual(model.files.first?.state, .changed)
        model.sessionSaveTask?.cancel()
    }

    private struct ReleaseTransport: MusicBrainzTransport {
        let data: Data
        func data(for request: URLRequest) async throws -> MusicBrainzHTTPResponse {
            MusicBrainzHTTPResponse(statusCode: 200, data: data)
        }
    }

    @MainActor
    func testCollapsedAlbumsAndGlobalSearchAndFilters() throws {
        let model = AppModel()
        let first = try audioFile(title: "First Song", artist: "Alice", album: "One", track: "1/2")
        var second = try audioFile(title: "Second Song", artist: "Bob", album: "Two", track: "2/2")
        var metadata = second.metadata
        metadata.setValue("Edited Song", for: "title")
        try second.updateMetadata(metadata)
        model.files = [second, first]
        XCTAssertTrue(model.expandedAlbumIDs.isEmpty)
        XCTAssertEqual(model.albumGroups.count, 2)
        model.selectAlbum(try XCTUnwrap(model.albumGroups.first(where: { $0.title == "One" })))
        XCTAssertEqual(model.visibleFiles.map(\.id), [first.id])
        model.searchQuery = "bob edited"
        model.applyBrowserSearch()
        XCTAssertEqual(model.visibleFiles.map(\.id), [second.id], "Search must span every album")
        XCTAssertEqual(model.browserAlbumGroups.map(\.title), ["Two"])
        XCTAssertTrue(model.selectedFiles.isEmpty, "Search must not leave hidden tracks selected for editing")
        model.searchQuery = ""
        model.applyBrowserSearch()
        model.browseAllTracks()
        model.browserFilter = .modified
        XCTAssertEqual(model.visibleFiles.map(\.id), [second.id])
        model.selectAlbum(try XCTUnwrap(model.albumGroups.first(where: { $0.title == "One" })))
        XCTAssertTrue(model.selectedFiles.isEmpty, "Album selection must respect the active filter")
        model.browserFilter = .all
        model.expandAllAlbums()
        XCTAssertEqual(model.expandedAlbumIDs.count, 2)
        model.collapseAllAlbums()
        XCTAssertTrue(model.expandedAlbumIDs.isEmpty)
    }

    @MainActor
    func testMixedFieldsIncludeMissingValuesAndTracksSortNumerically() throws {
        let model = AppModel()
        let first = try audioFile(title: "One", artist: "Alice", album: "Album", track: "1/12")
        let second = try audioFile(title: "Ten", artist: "Alice", album: "Album", track: "10/12")
        var third = try audioFile(title: "Two", artist: "Alice", album: "Album", track: "2/12")
        var metadata = third.metadata
        metadata.setValue("Pop", for: "genre")
        try third.updateMetadata(metadata)
        model.files = [second, third, first]
        XCTAssertEqual(model.visibleFiles.map(\.id), [first.id, third.id, second.id])
        model.selectAllVisible()
        XCTAssertTrue(model.metadataValueIsMixed("genre"))
        XCTAssertEqual(model.metadataValue("genre"), "")
        XCTAssertFalse(model.metadataValueIsMixed("artist"))
        XCTAssertEqual(model.metadataValue("artist"), "Alice")
    }

    @MainActor
    func testBatchScriptEvaluatesEachTrackAndLookupRejectsMixedAlbums() throws {
        let model = AppModel()
        let first = try audioFile(title: "One", artist: "Alice", album: "Album One", track: "1")
        let second = try audioFile(title: "Two", artist: "Bob", album: "Album Two", track: "1")
        model.files = [first, second]
        model.selectAllVisible()
        XCTAssertFalse(model.canLookupSelection)
        model.scriptSource = "$set(title,%title% edited)"
        model.runScript(applying: true)
        XCTAssertEqual(model.file(id: first.id)?.metadata.firstValue(for: "title"), "One edited")
        XCTAssertEqual(model.file(id: second.id)?.metadata.firstValue(for: "title"), "Two edited")
        model.selectionChanged([first.id])
        XCTAssertTrue(model.canLookupSelection)
    }

    @MainActor
    func testSwitchingSessionsPreservesPendingEditsAndCollapsedState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacPicard-browser-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(directory: root)
        let first = MusicWorkspace(name: "Original", kind: .session)
        let second = MusicWorkspace(name: "Other", kind: .session)
        var file = try audioFile(title: "Before", artist: "Alice", album: "Album", track: "1")
        var metadata = file.metadata
        metadata.setValue("Pending", for: "title")
        try file.updateMetadata(metadata)
        _ = try await store.create(first, document: SessionDocument(files: [file.sessionRecord()]))
        let catalog = try await store.create(second, document: SessionDocument())
        let model = AppModel()
        model.workspaceStore = store
        model.workspaces = catalog.workspaces
        model.activeWorkspaceID = first.id
        model.sessionManager = SessionManager(store: await store.sessionStore(for: first.id))
        model.files = [file]
        model.expandAllAlbums()
        model.playback.enqueue([PlaybackTrack(file)])
        await model.switchWorkspace(second.id)
        XCTAssertTrue(model.files.isEmpty)
        XCTAssertTrue(model.playback.queue.isEmpty, "Workspace switching must release the previous library's playback access")
        await model.switchWorkspace(first.id)
        XCTAssertEqual(model.files.first?.metadata.firstValue(for: "title"), "Pending")
        XCTAssertTrue(model.files.first?.isModified == true)
        XCTAssertTrue(model.expandedAlbumIDs.isEmpty)
    }

    @MainActor
    func testFolderLibraryRestoresAccessAndEditsAfterRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacPicard-library-integration-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let music = root.appendingPathComponent("Music/Album", isDirectory: true)
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        let source = music.appendingPathComponent("track.flac")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
                             "anullsrc=r=44100:cl=mono", "-t", "0.1", "-c:a", "flac", source.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw XCTSkip("ffmpeg is required to create an audio fixture") }

        let paths = AppPaths(applicationSupportDirectory: root.appendingPathComponent("Support"))
        let runtime = PicardRuntime(paths: paths)
        _ = try await runtime.start()
        let catalogDirectory = paths.applicationSupportDirectory.appendingPathComponent("Workspaces")
        let model = AppModel()
        model.runtime = runtime
        model.workspaceStore = WorkspaceStore(directory: catalogDirectory)
        await model.createSession(named: "Tagging")
        await model.addLibrary(directory: music.deletingLastPathComponent())
        await model.libraryScanTask?.value
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.activeWorkspace?.kind, .library)
        XCTAssertNotNil(model.workspaceAccess, "The selected folder must retain security-scoped access")
        let file = try XCTUnwrap(model.files.first)
        model.selectionChanged([file.id])
        model.setMetadata("title", value: "Pending Library Title")
        try await model.flushSession()
        let libraryID = try XCTUnwrap(model.activeWorkspaceID)

        let restarted = AppModel()
        restarted.runtime = PicardRuntime(paths: paths)
        restarted.workspaceStore = WorkspaceStore(directory: catalogDirectory)
        await restarted.switchWorkspace(libraryID)
        await restarted.libraryScanTask?.value
        XCTAssertNil(restarted.errorMessage)
        XCTAssertNotNil(restarted.workspaceAccess)
        XCTAssertEqual(restarted.files.first?.id, file.id)
        XCTAssertEqual(restarted.files.first?.metadata.firstValue(for: "title"), "Pending Library Title")
        XCTAssertTrue(restarted.files.first?.isModified == true)
        XCTAssertTrue(restarted.expandedAlbumIDs.isEmpty)
        model.sessionSaveTask?.cancel()
        restarted.sessionSaveTask?.cancel()
    }

    private func audioFile(title: String, artist: String, album: String, track: String) throws -> AudioFile {
        var file = AudioFile(url: URL(fileURLWithPath: "/tmp/\(UUID()).flac"))
        try file.beginLoading()
        try file.finishLoading(
            metadata: Metadata(fields: ["title": [title], "artist": [artist], "album": [album], "tracknumber": [track]]),
            identity: AudioFileIdentity(resourceIdentifier: nil, byteCount: 1, modificationDate: nil, prefixHash: "fixture")
        )
        return file
    }
}
