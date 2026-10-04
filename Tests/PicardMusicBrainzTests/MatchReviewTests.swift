import Foundation
import XCTest
@testable import PicardMusicBrainz

final class MatchReviewTests: XCTestCase {
    func testReorderedAndIncompleteAlbumsMatchBySongInsteadOfFileOffset() throws {
        let locals = [LocalTrackCandidate(title: "Third", artist: "Artist", trackNumber: 1),
                      LocalTrackCandidate(title: "First", artist: "Artist", trackNumber: 3)]
        let review = try ReleaseMatchReview(release: release([track("a", "First", 1), track("b", "Second", 2), track("c", "Third", 3)]), localTracks: locals)
        XCTAssertEqual(review.assignments[locals[0].id], "c")
        XCTAssertEqual(review.assignments[locals[1].id], "a")
        XCTAssertEqual(review.missingTracks.map(\.id), ["b"])
        XCTAssertTrue(review.unmatchedFileIDs.isEmpty)
    }

    func testBlankAndAmbiguousTracksRequireManualReview() throws {
        let blank = LocalTrackCandidate(title: "", artist: "Artist")
        let locals = [LocalTrackCandidate(title: "Same", artist: "Artist"), blank]
        var review = try ReleaseMatchReview(release: release([track("a", "Same", 1), track("b", "Same", 2)]), localTracks: locals)
        XCTAssertTrue(review.assignments.isEmpty)
        XCTAssertEqual(review.needsReviewCount, 1)
        try review.assign(fileID: locals[0].id, trackID: "b")
        XCTAssertEqual(review.assignments[locals[0].id], "b")
        XCTAssertTrue(review.manualFileIDs.contains(locals[0].id))
        XCTAssertEqual(review.missingTracks.map(\.id), ["a"])
    }

    func testWholeAlbumAssignmentAvoidsGreedyLoss() {
        let locals = [LocalTrackCandidate(title: "Song", durationInMilliseconds: 190_000),
                      LocalTrackCandidate(title: "Song", durationInMilliseconds: 180_000)]
        let remote = [track("a", "Song", 1, duration: 185_000), track("b", "Song", 2, duration: 200_000)]
        let matches = TrackMatcher().match(localTracks: locals, releaseTracks: remote)
        XCTAssertEqual(matches.first { $0.localTrackID == locals[0].id }?.releaseTrackID, "b")
        XCTAssertEqual(matches.first { $0.localTrackID == locals[1].id }?.releaseTrackID, "a")
    }

    func testDiscContextDisambiguatesRepeatedRecordings() throws {
        let first = track("a", "Song", 1, recording: "recording")
        let second = track("b", "Song", 1, recording: "recording")
        let remote = release(media: [MusicBrainzMedium(position: 1, format: "CD", tracks: [first]),
                                     MusicBrainzMedium(position: 2, format: "CD", tracks: [second])])
        let locals = [LocalTrackCandidate(title: "Song", trackNumber: 1, discNumber: 2, recordingID: "recording"),
                      LocalTrackCandidate(title: "Song", trackNumber: 1, discNumber: 1, recordingID: "recording")]
        let review = try ReleaseMatchReview(release: remote, localTracks: locals)
        XCTAssertEqual(review.assignments[locals[0].id], "b")
        XCTAssertEqual(review.assignments[locals[1].id], "a")
        XCTAssertEqual(review.disc(for: "b"), 2)
    }

    func testManualSwapsClearsAndResetNeverDuplicateAReleaseTrack() throws {
        let locals = [LocalTrackCandidate(title: "First", artist: "Artist"), LocalTrackCandidate(title: "Second", artist: "Artist")]
        var review = try ReleaseMatchReview(release: release([track("a", "First", 1), track("b", "Second", 2)]), localTracks: locals)
        try review.assign(fileID: locals[0].id, trackID: "b")
        XCTAssertEqual(review.assignments[locals[1].id], "a")
        XCTAssertEqual(Set(review.assignments.values).count, 2)
        try review.assign(fileID: locals[0].id, trackID: nil)
        XCTAssertTrue(review.unmatchedFileIDs.contains(locals[0].id))
        try review.assign(fileID: locals[0].id, trackID: "a")
        XCTAssertNil(review.assignments[locals[1].id], "Taking an occupied slot with no previous slot leaves its former file unmatched.")
        review.unmatchAll()
        XCTAssertTrue(review.assignments.isEmpty)
        review.resetToSuggestions()
        XCTAssertEqual(review.assignments[locals[0].id], "a")
        XCTAssertEqual(review.assignments[locals[1].id], "b")
    }

    func testLengthMismatchIsNotAutomaticallyAcceptedAndExactIdentifiersWin() throws {
        let local = LocalTrackCandidate(title: "Song", artist: "Artist", durationInMilliseconds: 60_000)
        let remote = release([track("a", "Song", 1, duration: 200_000)])
        let review = try ReleaseMatchReview(release: remote, localTracks: [local])
        XCTAssertTrue(review.assignments.isEmpty)
        let identified = LocalTrackCandidate(title: "Incorrect title", durationInMilliseconds: 60_000, isrcs: ["usaaa1234567"])
        let withISRC = release([MusicBrainzTrack(id: "a", recordingID: "r", title: "Song", artistCredit: "Artist",
            lengthInMilliseconds: 200_000, number: "1", position: 1, isrcs: ["USAAA1234567"])])
        XCTAssertEqual(try ReleaseMatchReview(release: withISRC, localTracks: [identified]).assignments[identified.id], "a")
    }

    func testEmptyReleasesInvalidIDsAndDuplicateIDsAreSafe() throws {
        let local = LocalTrackCandidate(title: "Song")
        var review = try ReleaseMatchReview(release: release([]), localTracks: [local])
        XCTAssertEqual(review.unmatchedFileIDs, [local.id])
        XCTAssertTrue(review.assignments.isEmpty)
        XCTAssertThrowsError(try review.assign(fileID: UUID(), trackID: nil))
        XCTAssertThrowsError(try review.assign(fileID: local.id, trackID: "foreign-track"))
        XCTAssertThrowsError(try ReleaseMatchReview(release: release([track("a", "One", 1), track("a", "Two", 2)]), localTracks: [local]))
        XCTAssertThrowsError(try ReleaseMatchReview(release: release([]), localTracks: [local, local]))
    }

    private func track(_ id: String, _ title: String, _ number: Int, duration: Int? = nil, recording: String? = nil) -> MusicBrainzTrack {
        MusicBrainzTrack(id: id, recordingID: recording, title: title, artistCredit: "Artist", lengthInMilliseconds: duration,
                        number: String(number), position: number, isrcs: [])
    }
    private func release(_ tracks: [MusicBrainzTrack]) -> MusicBrainzRelease {
        release(media: [MusicBrainzMedium(position: 1, format: "Digital Media", tracks: tracks)])
    }
    private func release(media: [MusicBrainzMedium]) -> MusicBrainzRelease {
        MusicBrainzRelease(id: "release", title: "Album", artistCredits: [MusicBrainzArtistCredit(id: nil, name: "Artist")],
                          date: nil, country: nil, barcode: nil, status: nil, releaseGroupID: nil,
                          releaseGroupType: nil, labelNames: [], catalogNumbers: [], media: media)
    }
}
