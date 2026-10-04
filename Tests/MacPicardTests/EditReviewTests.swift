import Foundation
import PicardFoundation
import PicardFormats
import PicardMusicBrainz
import PicardSessions
import XCTest
@testable import MacPicard

final class EditReviewTests: XCTestCase {
    @MainActor
    func testDisplaySummariesCannotFlattenDifferentValueListsAndMultiTagRemovalIsOneUndo() throws {
        var first = try file("First", number: "1"), second = try file("Second", number: "2")
        var tags = first.metadata; tags.setValues(["Rock; Soul"], for: "genre"); try first.updateMetadata(tags)
        tags = second.metadata; tags.setValues(["Rock", "Soul"], for: "genre"); try second.updateMetadata(tags)
        let model = AppModel(); model.files = [first, second]; model.selectedFileIDs = [first.id, second.id]
        defer { model.sessionSaveTask?.cancel() }
        XCTAssertEqual(model.metadataRows.first { $0.key == "genre" }?.current, "Multiple values")
        model.deleteTags(["title", "artist"])
        XCTAssertTrue(model.files.allSatisfy { $0.metadata.isDeleted("title") && $0.metadata.isDeleted("artist") })
        model.undoMetadataEdit()
        XCTAssertEqual(model.files, [first, second])
    }

    @MainActor
    func testMultiValueEditUndoRedoAndPerTagRestorePreserveDistinctTitles() throws {
        let first = try file("First", number: "1"), second = try file("Second", number: "2")
        let model = AppModel(); model.files = [first, second]; model.selectedFileIDs = [first.id, second.id]
        defer { model.sessionSaveTask?.cancel() }
        model.setTagValues(["Rock", "Soul"], for: "genre")
        XCTAssertEqual(model.file(id: first.id)?.metadata.values(for: "genre"), ["Rock", "Soul"])
        XCTAssertEqual(model.file(id: second.id)?.metadata.firstValue(for: "title"), "Second")
        model.undoMetadataEdit()
        XCTAssertEqual(model.files, [first, second])
        model.redoMetadataEdit()
        XCTAssertEqual(model.file(id: second.id)?.metadata.values(for: "genre"), ["Rock", "Soul"])
        model.deleteTag("artist")
        XCTAssertTrue(model.file(id: first.id)?.metadata.isDeleted("artist") == true)
        model.restoreTag("artist")
        XCTAssertEqual(model.file(id: first.id)?.metadata.values(for: "artist"), ["Artist"])
        XCTAssertEqual(model.file(id: first.id)?.metadata.values(for: "genre"), ["Rock", "Soul"])
        XCTAssertTrue(model.metadataRows.first { $0.key == "genre" }?.changed == true)
        XCTAssertEqual(model.metadataRows.first { $0.key == "title" }?.current, "Multiple values")
    }

    @MainActor
    func testMixedMultiValuesAndEmptyAbsentDeletedAreDistinct() throws {
        var first = try file("First", number: "1"), second = try file("Second", number: "2")
        var tags = first.metadata; tags.setValues(["Artist", "Guest"], for: "artist"); try first.updateMetadata(tags)
        tags = second.metadata; tags.setValue("", for: "comment"); try second.updateMetadata(tags)
        let model = AppModel(); model.files = [first, second]; model.selectedFileIDs = [first.id, second.id]
        defer { model.sessionSaveTask?.cancel() }
        XCTAssertTrue(model.metadataValueIsMixed("artist"))
        XCTAssertEqual(model.metadataRows.first { $0.key == "comment" }?.current, "Multiple values")
        let before = model.files
        _ = model.metadataRows
        XCTAssertEqual(model.files, before)
        model.selectedFileIDs = [second.id]
        XCTAssertEqual(model.metadataRows.first { $0.key == "comment" }?.current, "Empty value")
        model.deleteTag("comment")
        XCTAssertEqual(model.metadataRows.first { $0.key == "comment" }?.current, "Deleted")
        model.restoreTag("comment")
        XCTAssertFalse(model.file(id: second.id)?.metadata.contains("comment") == true)
    }

    @MainActor
    func testUndoCannotOverwriteNewerEditsOrASavedBaseline() throws {
        let original = try file("Before", number: "1")
        let model = AppModel(); model.files = [original]; model.selectedFileIDs = [original.id]
        defer { model.sessionSaveTask?.cancel() }
        model.setMetadata("title", value: "Staged")
        var newer = try XCTUnwrap(model.files.first)
        var tags = newer.metadata; tags.setValue("External newer", for: "title"); try newer.updateMetadata(tags)
        model.files = [newer]
        model.undoMetadataEdit()
        XCTAssertEqual(model.files, [newer]); XCTAssertFalse(model.editUndoManager.canUndo)
        model.setMetadata("title", value: "Saved")
        var saved = try XCTUnwrap(model.files.first)
        try saved.beginSaving(); try saved.finishSaving(identity: XCTUnwrap(saved.identity))
        model.files = [saved]
        model.undoMetadataEdit()
        XCTAssertEqual(model.files, [saved]); XCTAssertFalse(model.editUndoManager.canRedo)
    }

    @MainActor
    func testClipboardMergeAndScriptsAreGroupedUndoableEdits() throws {
        let original = try file("Before", number: "1")
        let model = AppModel(); model.files = [original]; model.selectedFileIDs = [original.id]
        defer { model.sessionSaveTask?.cancel() }
        try model.applyTagClipboard(TagClipboard(tags: ["artist": .init(values: ["Other"], deleted: false), "~length": .init(values: ["999"], deleted: false)]))
        model.restoreTag("artist", merging: true)
        XCTAssertEqual(model.files.first?.metadata.values(for: "artist"), ["Other", "Artist"])
        XCTAssertFalse(model.files.first?.metadata.contains("~length") == true)
        model.scriptSource = "$set(title,Scripted)$set(genre,Jazz)"
        model.runScript(applying: true)
        XCTAssertEqual(model.files.first?.metadata.firstValue(for: "title"), "Scripted")
        model.undoMetadataEdit()
        XCTAssertEqual(model.files.first?.metadata.firstValue(for: "title"), "Before")
        XCTAssertFalse(model.files.first?.metadata.contains("genre") == true)
        model.redoMetadataEdit()
        XCTAssertEqual(model.files.first?.metadata.firstValue(for: "genre"), "Jazz")
    }

    @MainActor
    func testPreservedTagsSurviveReviewedMusicBrainzApplication() async throws {
        let original = try file("First", number: "1")
        let model = try await reviewing([original])
        var config = AppConfiguration(); config.autosaveEnabled = false; config.automaticCoverArt = false
        config.editing.preservedTags = ["album", "artist"]
        model.installConfiguration(config)
        defer { model.refreshTask?.cancel(); model.sessionSaveTask?.cancel() }
        XCTAssertTrue(model.applySelectedRelease())
        XCTAssertEqual(model.files.first?.metadata.firstValue(for: "album"), "Before")
        XCTAssertEqual(model.files.first?.metadata.firstValue(for: "musicbrainz_albumid"), "11111111-1111-1111-1111-111111111111")
        model.undoMetadataEdit()
        XCTAssertEqual(model.files.first?.metadata, original.metadata)
    }

    @MainActor
    func testDiscardConfirmationRestoresTagsDeletionsAndArtworkAndKeepsOtherEdits() async throws {
        var first = try file("First", number: "1")
        var second = try file("Second", number: "2")
        var metadata = first.metadata
        metadata.delete("artist"); metadata.setValue("Pending", for: "title"); metadata.setValues(["One", "Two"], for: "genre")
        try first.updateMetadata(metadata)
        try first.updateArtwork(ArtworkCollection(images: [Artwork(mimeType: "image/png", source: .generated, data: Data([1]))]))
        metadata = second.metadata; metadata.setValue("Other pending", for: "title"); try second.updateMetadata(metadata)
        let model = AppModel(); model.files = [first, second]
        defer { model.sessionSaveTask?.cancel() }
        await model.discardChanges([first.id])
        XCTAssertTrue(model.file(id: first.id)?.isModified == true)
        await model.discardChanges([first.id], confirmed: true)
        let reverted = try XCTUnwrap(model.file(id: first.id))
        XCTAssertEqual(reverted.metadata, first.originalMetadata)
        XCTAssertEqual(reverted.artwork, first.originalArtwork)
        XCTAssertEqual(reverted.identity, first.identity)
        XCTAssertFalse(reverted.isModified)
        XCTAssertEqual(model.file(id: second.id)?.metadata.firstValue(for: "title"), "Other pending")
    }

    @MainActor
    func testDiscardMissingAndFailedItemsKeepsTheirAvailabilityState() async throws {
        var missing = try file("Missing", number: "1")
        var tags = missing.metadata; tags.setValue("Pending", for: "title"); try missing.updateMetadata(tags)
        missing.markRemoved()
        var failed = try file("Failed", number: "2")
        tags = failed.metadata; tags.setValue("Pending", for: "title"); try failed.updateMetadata(tags)
        failed.markFailure(SaveError.session("Unavailable"))
        let model = AppModel(); model.files = [missing, failed]
        await model.discardChanges([missing.id, failed.id], confirmed: true)
        XCTAssertEqual(model.file(id: missing.id)?.state, .removed)
        XCTAssertEqual(model.file(id: failed.id)?.state, .failed)
        XCTAssertEqual(model.file(id: failed.id)?.lastError, failed.lastError)
        XCTAssertFalse(model.hasUnsavedChanges)
    }

    @MainActor
    func testFailedDiscardPersistenceKeepsPendingEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacPicard-discard-failure-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blocker = root.appendingPathComponent("not-a-directory")
        try Data([1]).write(to: blocker)
        let store = SessionStore(sessionURL: blocker.appendingPathComponent("session.json"), recoveryURL: root.appendingPathComponent("recovery.json"))
        var pending = try file("Before", number: "1")
        var tags = pending.metadata; tags.setValue("Pending", for: "title"); try pending.updateMetadata(tags)
        let model = AppModel(); model.sessionManager = SessionManager(store: store); model.files = [pending]
        await model.discardChanges([pending.id], confirmed: true)
        XCTAssertEqual(model.files, [pending])
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.hasUnsavedChanges)
    }

    @MainActor
    func testDiscardIsPersistedAndDoesNotUndoAlreadySavedTagsOrWriteAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacPicard-discard-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("song.flac")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono",
                             "-t", "1", "-c:a", "flac", "-metadata", "title=Loaded", url.path]
        process.standardOutput = Pipe(); process.standardError = Pipe()
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw XCTSkip("FFmpeg is required for the isolated audio fixture") }
        var loaded = try await AudioFileCoordinator().load(url: url)
        XCTAssertEqual(loaded.durationInMilliseconds, 1_000)
        var tags = loaded.metadata; tags.setValue("Saved to disk", for: "title"); try loaded.updateMetadata(tags)
        var saved = try await AudioSaveCoordinator().save(loaded)
        let bytes = try Data(contentsOf: url)
        tags = saved.metadata; tags.setValue("Unsaved", for: "title"); try saved.updateMetadata(tags)
        let store = SessionStore(sessionURL: root.appendingPathComponent("session.json"), recoveryURL: root.appendingPathComponent("recovery.json"))
        let model = AppModel(); model.sessionManager = SessionManager(store: store); model.files = [saved]
        await model.discardChanges([saved.id], confirmed: true)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        let savedDocument = try await store.load()
        let document = try XCTUnwrap(savedDocument)
        let restored = AudioFile.restore(from: try XCTUnwrap(document.files.first))
        XCTAssertEqual(restored.metadata.firstValue(for: "title"), "Saved to disk")
        XCTAssertFalse(restored.isModified)
        XCTAssertEqual(restored.durationInMilliseconds, 1_000)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(restored.sessionRecord())) as? [String: Any])
        json.removeValue(forKey: "durationInMilliseconds")
        let legacy = try JSONDecoder().decode(AudioFileSessionRecord.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.durationInMilliseconds, "Old sessions remain compatible.")
    }

    @MainActor
    func testReviewedAssignmentsApplyCorrectDiscTotalsAndLeaveUnmatchedFilesUntouched() async throws {
        let first = try file("First", number: "9")
        let second = try file("Second", number: "1")
        let extra = try file("Bonus", number: "10", duration: 10_000)
        let model = try await reviewing([extra, second, first])
        defer { model.sessionSaveTask?.cancel() }
        XCTAssertEqual(model.matchReview?.assignments.count, 2)
        XCTAssertFalse(model.hasUnsavedChanges, "Loading and reviewing must not mutate tags.")
        model.assignReviewTrack(fileID: first.id, trackID: "two")
        XCTAssertEqual(model.matchReview?.assignments[second.id], "one")
        let expected = model.reviewedMetadata(for: first.id)
        XCTAssertTrue(model.applySelectedRelease())
        let tags = try XCTUnwrap(model.file(id: first.id)?.metadata)
        XCTAssertEqual(tags, expected)
        XCTAssertEqual(tags.firstValue(for: "title"), "Second")
        XCTAssertEqual(tags.firstValue(for: "tracknumber"), "1")
        XCTAssertEqual(tags.firstValue(for: "discnumber"), "2")
        XCTAssertEqual(tags.firstValue(for: "totaldiscs"), "2")
        XCTAssertEqual(tags.firstValue(for: "totaltracks"), "1")
        XCTAssertEqual(tags.firstValue(for: "musicbrainz_releasetrackid"), "two")
        XCTAssertEqual(tags.firstValue(for: "musicbrainz_trackid"), "recording-two")
        XCTAssertEqual(model.file(id: extra.id), extra, "Unassigned extra files must not receive even album tags.")
        XCTAssertNil(model.matchReview)
    }

    @MainActor
    func testCancelledReviewAndUnmatchAllLeaveFilesUnchanged() async throws {
        let original = try file("First", number: "1")
        let model = try await reviewing([original])
        model.resetReviewAssignments(unmatchAll: true)
        XCTAssertFalse(model.canApplyReleaseReview)
        XCTAssertFalse(model.applySelectedRelease())
        model.cancelMatchReview()
        XCTAssertEqual(model.files, [original])
        XCTAssertNil(model.selectedRelease)
    }

    @MainActor
    func testStaleReviewCannotOverwriteNewerEditsAndDiscardClearsIt() async throws {
        let original = try file("First", number: "1")
        let model = try await reviewing([original])
        defer { model.sessionSaveTask?.cancel() }
        model.setMetadata("title", value: "Newer user edit")
        XCTAssertFalse(model.canApplyReleaseReview)
        XCTAssertFalse(model.applySelectedRelease())
        XCTAssertEqual(model.files.first?.metadata.firstValue(for: "title"), "Newer user edit")
        await model.discardChanges([original.id], confirmed: true)
        XCTAssertNil(model.matchReview)
        XCTAssertEqual(model.files.first?.metadata.firstValue(for: "title"), "First")
    }

    @MainActor
    func testFilenameFallbackSuggestionsDoNotChangeLocalMetadata() async throws {
        let unnamed = try file("", number: "", name: "02 - First.flac")
        let model = try await reviewing([unnamed])
        XCTAssertEqual(model.matchReview?.localTracks.first?.title, "First")
        XCTAssertEqual(model.matchReview?.assignments[unnamed.id], "one")
        XCTAssertEqual(model.files.first?.metadata.firstValue(for: "title"), "")
    }

    @MainActor
    func testSearchRefinementDoesNotEditFilesOrReuseAnOldReview() async throws {
        var original = try file("First", number: "1")
        var tags = original.metadata; tags.setValue("old-group", for: "musicbrainz_releasegroupid"); try original.updateMetadata(tags)
        let transport = SearchFixtureTransport()
        let client = MusicBrainzClient(userAgent: "Tests/1.0", transport: transport, minimumRequestInterval: .zero)
        let model = AppModel(musicBrainzClient: client); model.files = [original]; model.selectionChanged([original.id])
        defer { model.sessionSaveTask?.cancel() }
        await model.lookup(albumTitle: "New Album", albumArtist: "New Artist")
        XCTAssertEqual(model.files, [original])
        XCTAssertEqual(model.matchResults.count, 1)
        XCTAssertFalse(model.matchResults[0].score.identifierMismatch)
        XCTAssertNil(model.matchReview)
        XCTAssertNil(model.errorMessage)
        let recorded = await transport.lastRequest()
        let request = try XCTUnwrap(recorded)
        let items = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items?.first { $0.name == "query" }?.value, #"release:"New Album" AND artist:"New Artist""#)
    }

    @MainActor
    private func reviewing(_ files: [AudioFile]) async throws -> AppModel {
        let client = MusicBrainzClient(userAgent: "Tests/1.0", transport: ReleaseFixtureTransport(), minimumRequestInterval: .zero)
        let model = AppModel(musicBrainzClient: client); model.files = files; model.selectionChanged(Set(files.map(\.id)))
        let release = try await client.lookupRelease(id: "11111111-1111-1111-1111-111111111111")
        let result = try XCTUnwrap(ReleaseMatcher().rank(local: LocalAlbumCandidate(metadata: files[0].metadata), candidates: [release.summary]).first)
        await model.chooseMatch(result)
        XCTAssertNil(model.errorMessage)
        model.sessionSaveTask?.cancel()
        return model
    }

    private func file(_ title: String, number: String, duration: Int = 180_000, name: String? = nil) throws -> AudioFile {
        var result = AudioFile(url: URL(fileURLWithPath: "/tmp/\(name ?? UUID().uuidString + ".flac")"))
        try result.beginLoading()
        try result.finishLoading(metadata: Metadata(fields: ["title": [title], "artist": ["Artist"], "album": ["Before"], "tracknumber": [number]]),
            identity: AudioFileIdentity(resourceIdentifier: nil, byteCount: 1, modificationDate: nil, prefixHash: "test"), durationInMilliseconds: duration)
        return result
    }

    private struct ReleaseFixtureTransport: MusicBrainzTransport {
        func data(for request: URLRequest) async throws -> MusicBrainzHTTPResponse {
            MusicBrainzHTTPResponse(statusCode: 200, data: Data(#"{"id":"11111111-1111-1111-1111-111111111111","title":"Release","artist-credit":[{"name":"Artist"}],"media":[{"position":1,"tracks":[{"id":"one","number":"1","position":1,"title":"First","length":180000,"artist-credit":[{"name":"Artist"}],"recording":{"id":"recording-one"}}]},{"position":2,"tracks":[{"id":"two","number":"1","position":1,"title":"Second","length":180000,"artist-credit":[{"name":"Artist"}],"recording":{"id":"recording-two"}}]}]}"#.utf8))
        }
    }

    private actor SearchFixtureTransport: MusicBrainzTransport {
        var request: URLRequest?
        func data(for request: URLRequest) async throws -> MusicBrainzHTTPResponse {
            self.request = request
            return MusicBrainzHTTPResponse(statusCode: 200, data: Data(#"{"releases":[{"id":"11111111-1111-1111-1111-111111111111","title":"New Album","artist-credit":[{"name":"New Artist"}],"track-count":2,"release-group":{"id":"new-group"}}]}"#.utf8))
        }
        func lastRequest() -> URLRequest? { request }
    }
}
