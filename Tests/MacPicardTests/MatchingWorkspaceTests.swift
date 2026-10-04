import PicardFoundation
import PicardMusicBrainz
import PicardSessions
import XCTest
@testable import MacPicard

final class MatchingWorkspaceTests: XCTestCase {
    @MainActor
    func testCancellingReadJobStopsRequestWithoutApplyingOrPublishingAFailure() async throws {
        let transport = CancellableMatchingTransport()
        let model = AppModel(musicBrainzClient: MusicBrainzClient(userAgent: "Tests/1.0", transport: transport, minimumRequestInterval: .zero))
        let workspace = MusicWorkspace(name: "Fixture", kind: .library, directory: URL(fileURLWithPath: "/tmp"))
        let file = try fixture(); model.files = [file]; model.workspaces = [workspace]; model.activeWorkspaceID = workspace.id
        model.startLibraryMatch(threshold: 0.85)
        for _ in 0..<100 {
            if await transport.started { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        model.cancelLibraryMatch(); await model.libraryMatchTask?.value
        XCTAssertFalse(model.isWorking); XCTAssertEqual(model.files, [file]); XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.libraryMatchRun?.proposals.isEmpty == true)
    }
    func testReleaseReferenceAcceptsOnlyReleaseUUIDOrOfficialSecureReleaseURL() throws {
        let id = "11111111-1111-1111-1111-111111111111"
        XCTAssertEqual(try ReleaseReference.identifier(id), id)
        XCTAssertEqual(try ReleaseReference.identifier("https://musicbrainz.org/release/\(id)/"), id)
        for text in ["http://musicbrainz.org/release/\(id)", "https://evil.test/release/\(id)", "https://musicbrainz.org/recording/\(id)", "https://musicbrainz.org@evil.test/release/\(id)", "not an ID"] {
            XCTAssertThrowsError(try ReleaseReference.identifier(text))
        }
    }
    @MainActor
    func testReadJobCheckpointRestoresWithoutApplyingAndRejectsNewerEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = MatchingFixtureTransport()
        let client = MusicBrainzClient(userAgent: "Tests/1.0", transport: transport, minimumRequestInterval: .zero)
        let model = AppModel(musicBrainzClient: client)
        let file = try fixture()
        let workspace = MusicWorkspace(name: "Fixture", kind: .library, directory: root)
        model.workspaces = [workspace]; model.activeWorkspaceID = workspace.id; model.files = [file]
        model.reviewCheckpointURL = root.appendingPathComponent("review.json")
        await model.matchEntireLibrary()
        XCTAssertEqual(model.files, [file], "Read jobs never stage tags")
        let proposal = try XCTUnwrap(model.libraryMatchRun?.proposals.first)
        XCTAssertTrue(model.isEligibleLibraryProposal(proposal))
        XCTAssertEqual(model.libraryMatchRun?.autoApplyThreshold, 0.85)
        let checkpoint = try await ReviewCheckpointStore.shared.load(try XCTUnwrap(model.reviewCheckpointURL))
        XCTAssertEqual(checkpoint.workspaceID, workspace.id)
        XCTAssertEqual(checkpoint.run.proposals.count, 1)
        let restarted = AppModel(musicBrainzClient: client)
        restarted.workspaces = [workspace]; restarted.activeWorkspaceID = workspace.id; restarted.files = [file]; restarted.reviewCheckpointURL = model.reviewCheckpointURL
        await restarted.restoreReviewCheckpoint()
        XCTAssertEqual(restarted.files, [file]); XCTAssertTrue(restarted.isEligibleLibraryProposal(proposal))
        restarted.selectionChanged([file.id]); restarted.setMetadata("genre", value: "Newer")
        XCTAssertFalse(restarted.isEligibleLibraryProposal(proposal))
        XCTAssertEqual(restarted.applyLibraryMatches([proposal]), 0)
        restarted.sessionSaveTask?.cancel(); model.sessionSaveTask?.cancel()
    }
    @MainActor
    func testResumeSkipsUnchangedCompletedReadResultsAndRejectIsPersisted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = MatchingFixtureTransport()
        let model = AppModel(musicBrainzClient: MusicBrainzClient(userAgent: "Tests/1.0", transport: transport, minimumRequestInterval: .zero))
        let workspace = MusicWorkspace(name: "Fixture", kind: .library, directory: root)
        model.workspaces = [workspace]; model.activeWorkspaceID = workspace.id; model.files = [try fixture()]; model.reviewCheckpointURL = root.appendingPathComponent("review.json")
        await model.matchEntireLibrary()
        let before = await transport.count
        await model.runLibraryMatch(threshold: 0.85, resume: true)
        let after = await transport.count
        XCTAssertEqual(before, after)
        let id = try XCTUnwrap(model.libraryMatchRun?.proposals.first?.id)
        model.setProposalStatus(id, .rejected)
        await model.reviewCheckpointTask?.value
        let saved = try await ReviewCheckpointStore.shared.load(try XCTUnwrap(model.reviewCheckpointURL))
        XCTAssertEqual(saved.run.proposals.first?.status, .rejected)
        XCTAssertTrue(model.libraryMatchRun?.highConfidence.isEmpty == true)
        XCTAssertEqual(model.applyLibraryMatches(model.libraryMatchRun?.proposals ?? []), 0)
    }
    @MainActor
    func testRegroupingIsStagedAndUndoPreservesDistinctSongNames() throws {
        let model = AppModel(); let file = try fixture()
        model.files = [file]; model.selectionChanged([file.id])
        model.regroupSelected(album: "New group", artist: "Other")
        XCTAssertEqual(model.files.first?.metadata.firstValue(for: "title"), "Song")
        XCTAssertEqual(model.files.first?.metadata.firstValue(for: "album"), "New group")
        model.undoMetadataEdit(); XCTAssertEqual(model.files, [file]); model.sessionSaveTask?.cancel()
    }
    private func fixture() throws -> AudioFile {
        var file = AudioFile(url: URL(fileURLWithPath: "/tmp/\(UUID()).flac"))
        try file.beginLoading()
        try file.finishLoading(metadata: Metadata(fields: ["title": ["Song"], "album": ["Album"], "artist": ["Artist"], "tracknumber": ["1"], "musicbrainz_albumid": [MatchingFixtureTransport.releaseID]]), identity: AudioFileIdentity(resourceIdentifier: nil, byteCount: 1, modificationDate: nil, prefixHash: "fixture"), durationInMilliseconds: 180_000)
        return file
    }
}

private actor MatchingFixtureTransport: MusicBrainzTransport {
    static let releaseID = "11111111-1111-1111-1111-111111111111"
    var count = 0
    func data(for request: URLRequest) async throws -> MusicBrainzHTTPResponse {
        count += 1
        let release = #"{"id":"11111111-1111-1111-1111-111111111111","title":"Album","artist-credit":[{"name":"Artist"}],"cover-art-archive":{"artwork":true},"media":[{"position":1,"tracks":[{"id":"track","number":"1","position":1,"title":"Song","length":180000,"artist-credit":[{"name":"Artist"}],"recording":{"id":"22222222-2222-2222-2222-222222222222"}}]}]}"#
        let data = request.url?.lastPathComponent == "release" ? "{\"releases\":[\(release)]}" : release
        return MusicBrainzHTTPResponse(statusCode: 200, data: Data(data.utf8))
    }
}

private actor CancellableMatchingTransport: MusicBrainzTransport {
    var started = false
    func data(for request: URLRequest) async throws -> MusicBrainzHTTPResponse {
        started = true
        try await Task.sleep(for: .seconds(30))
        return MusicBrainzHTTPResponse(statusCode: 200, data: Data())
    }
}
