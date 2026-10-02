import Foundation
import PicardFoundation
import XCTest
@testable import PicardMusicBrainz

final class MusicBrainzTests: XCTestCase {
    func testClientBuildsRequestsDecodesAndCachesSearchResults() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let transport = StubTransport(responses: [Data(Self.searchResponse.utf8)])
        let cache = MusicBrainzResponseCache(directory: root)
        let client = MusicBrainzClient(
            baseURL: URL(string: "https://musicbrainz.example/ws/2")!,
            userAgent: "MacPicardTests/1.0",
            authorizationHeader: "Bearer test-token",
            transport: transport,
            cache: cache,
            minimumRequestInterval: .zero
        )

        let first = try await client.searchReleases(query: "release:\"Example Album\"", limit: 10)
        let second = try await client.searchReleases(query: "release:\"Example Album\"", limit: 10)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].id, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(first[0].artistCredit, "Example Artist")
        XCTAssertEqual(first[0].trackCount, 2)

        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 1, "The second identical GET should come from cache")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "User-Agent"), "MacPicardTests/1.0")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        let queryItems = requests[0].url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }
        XCTAssertEqual(queryItems?.first(where: { $0.name == "query" })?.value, "release:\"Example Album\"")
    }

    func testReleaseLookupDecodesMediaTracksAndIdentifiers() async throws {
        let transport = StubTransport(responses: [Data(Self.releaseResponse.utf8)])
        let client = MusicBrainzClient(
            baseURL: URL(string: "https://musicbrainz.example/ws/2")!,
            userAgent: "MacPicardTests/1.0",
            transport: transport,
            minimumRequestInterval: .zero
        )

        let release = try await client.lookupRelease(id: "11111111-1111-1111-1111-111111111111")

        XCTAssertEqual(release.title, "Example Album")
        XCTAssertEqual(release.artistCredit, "Example Artist")
        XCTAssertEqual(release.barcode, "0123456789012")
        XCTAssertEqual(release.catalogNumbers, ["EX-001"])
        XCTAssertEqual(release.media.count, 1)
        XCTAssertEqual(release.media[0].id, "medium-1")
        XCTAssertEqual(release.tracks.count, 2)
        XCTAssertEqual(release.tracks[0].recordingID, "33333333-3333-3333-3333-333333333333")
        XCTAssertEqual(release.tracks[0].isrcs, ["USAAA1234567"])
    }

    func testReleaseMatcherPrioritizesExactIdentifiersAndReportsAmbiguity() throws {
        let local = LocalAlbumCandidate(
            albumTitle: "Example Album",
            albumArtist: "Example Artist",
            barcode: "0123456789012",
            tracks: [
                LocalTrackCandidate(title: "First Song", durationInMilliseconds: 180_000, trackNumber: 1),
                LocalTrackCandidate(title: "Second Song", durationInMilliseconds: 210_000, trackNumber: 2)
            ]
        )
        let exact = MusicBrainzReleaseSummary(
            id: "11111111-1111-1111-1111-111111111111",
            title: "Example Album",
            artistCredit: "Example Artist",
            date: "2026-01-01",
            country: "US",
            barcode: "0123456789012",
            status: "Official",
            releaseGroupID: nil,
            releaseGroupType: "Album",
            labelNames: ["Example Label"],
            catalogNumbers: ["EX-001"],
            mediaCount: 1,
            trackCount: 2,
            searchScore: 100
        )
        let alternative = MusicBrainzReleaseSummary(
            id: "22222222-2222-2222-2222-222222222222",
            title: "Example Album",
            artistCredit: "Example Artist",
            date: "2025-01-01",
            country: "GB",
            barcode: "9999999999999",
            status: "Official",
            releaseGroupID: nil,
            releaseGroupType: "Album",
            labelNames: [],
            catalogNumbers: [],
            mediaCount: 1,
            trackCount: 2,
            searchScore: 100
        )

        let matcher = ReleaseMatcher(preferences: ReleaseMatchPreferences(preferredCountries: ["US"]))
        let result = try XCTUnwrap(matcher.bestMatch(local: local, candidates: [alternative, exact]))

        XCTAssertEqual(result.release.id, exact.id)
        XCTAssertEqual(result.decision, .exact)
        XCTAssertEqual(result.score.identifier, 1)
        XCTAssertGreaterThan(result.margin, 0.02)
    }

    func testTrackMatcherAssignsExactISRCAndLeavesWeakTracksUnmatched() {
        let localExact = LocalTrackCandidate(
            title: "First Song",
            durationInMilliseconds: 180_000,
            trackNumber: 1,
            isrcs: ["USAAA1234567"]
        )
        let localWeak = LocalTrackCandidate(title: "Unknown Song", durationInMilliseconds: 50_000, trackNumber: 2)
        let remote = [
            MusicBrainzTrack(
                id: "track-1",
                recordingID: "recording-1",
                title: "First Song",
                artistCredit: "Example Artist",
                lengthInMilliseconds: 180_000,
                number: "1",
                position: 1,
                isrcs: ["USAAA1234567"]
            ),
            MusicBrainzTrack(
                id: "track-2",
                recordingID: "recording-2",
                title: "Second Song",
                artistCredit: "Example Artist",
                lengthInMilliseconds: 210_000,
                number: "2",
                position: 2,
                isrcs: []
            )
        ]

        let matches = TrackMatcher(minimumSimilarity: 0.50).match(
            localTracks: [localExact, localWeak],
            releaseTracks: remote
        )

        let exact = try! XCTUnwrap(matches.first { $0.localTrackID == localExact.id })
        let weak = try! XCTUnwrap(matches.first { $0.localTrackID == localWeak.id })
        XCTAssertEqual(exact.decision, .exact)
        XCTAssertEqual(exact.releaseTrackID, "track-1")
        XCTAssertEqual(weak.decision, .unmatched)
        XCTAssertNil(weak.releaseTrackID)
    }

    func testFullReleaseMatcherScoresDecodedTracksAndExactAlbumIdentifier() async throws {
        let transport = StubTransport(responses: [Data(Self.releaseResponse.utf8)])
        let client = MusicBrainzClient(
            baseURL: URL(string: "https://musicbrainz.example/ws/2")!,
            userAgent: "MacPicardTests/1.0",
            transport: transport,
            minimumRequestInterval: .zero
        )
        let release = try await client.lookupRelease(id: "11111111-1111-1111-1111-111111111111")
        let local = LocalAlbumCandidate(
            releaseID: release.id,
            albumTitle: release.title,
            albumArtist: release.artistCredit,
            tracks: release.tracks.map {
                LocalTrackCandidate(
                    title: $0.title,
                    artist: $0.artistCredit,
                    durationInMilliseconds: $0.lengthInMilliseconds,
                    trackNumber: Int($0.number)
                )
            }
        )

        let result = try XCTUnwrap(ReleaseMatcher().bestMatch(local: local, candidates: [release]))

        XCTAssertEqual(result.decision, .exact)
        XCTAssertEqual(result.score.identifier, 1)
        XCTAssertGreaterThan(result.score.tracks, 0.95)
        XCTAssertEqual(result.score.duration, 1)
        XCTAssertEqual(result.trackMatches.count, 2)
        XCTAssertTrue(result.trackMatches.allSatisfy { $0.decision == .matched })
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private actor StubTransport: MusicBrainzTransport {
        private let responses: [Data]
        private var index = 0
        private var recordedRequests: [URLRequest] = []

        init(responses: [Data]) {
            self.responses = responses
        }

        func data(for request: URLRequest) async throws -> MusicBrainzHTTPResponse {
            recordedRequests.append(request)
            let response = responses[min(index, responses.count - 1)]
            index += 1
            return MusicBrainzHTTPResponse(statusCode: 200, data: response)
        }

        func requests() -> [URLRequest] {
            recordedRequests
        }
    }

    private static let searchResponse = #"""
    {
      "created": "2026-10-02T00:00:00.000Z",
      "count": 1,
      "offset": 0,
      "releases": [{
        "id": "11111111-1111-1111-1111-111111111111",
        "title": "Example Album",
        "status": "Official",
        "date": "2026-01-01",
        "country": "US",
        "barcode": "0123456789012",
        "score": 100,
        "artist-credit": [{
          "name": "Example Artist",
          "joinphrase": "",
          "artist": {"id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", "name": "Example Artist"}
        }],
        "release-group": {"id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", "primary-type": "Album"},
        "label-info": [{"catalog-number": "EX-001", "label": {"name": "Example Label"}}],
        "media": [{"position": 1, "track-count": 2, "tracks": []}]
      }]
    }
    """#

    private static let releaseResponse = #"""
    {
      "id": "11111111-1111-1111-1111-111111111111",
      "title": "Example Album",
      "status": "Official",
      "date": "2026-01-01",
      "country": "US",
      "barcode": "0123456789012",
      "artist-credit": [{"name": "Example Artist", "joinphrase": "", "artist": {"id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", "name": "Example Artist"}}],
      "release-group": {"id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", "primary-type": "Album"},
        "label-info": [{"catalog-number": "EX-001", "label": {"name": "Example Label"}}],
        "media": [{
        "id": "medium-1",
        "position": 1,
        "format": "CD",
        "track-count": 2,
        "tracks": [
          {"id": "track-1", "number": "1", "position": 1, "title": "First Song", "length": 180000, "artist-credit": [], "recording": {"id": "33333333-3333-3333-3333-333333333333", "title": "First Song", "length": 180000, "isrcs": ["USAAA1234567"]}},
          {"id": "track-2", "number": "2", "position": 2, "title": "Second Song", "length": 210000, "artist-credit": [], "recording": {"id": "44444444-4444-4444-4444-444444444444", "title": "Second Song", "length": 210000, "isrcs": []}}
        ]
      }]
    }
    """#
}
