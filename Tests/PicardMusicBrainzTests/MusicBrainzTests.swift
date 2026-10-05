import Foundation
import PicardFoundation
import XCTest
@testable import PicardMusicBrainz

final class MusicBrainzTests: XCTestCase {
    func testConcurrentReleaseLookupsCoalesceAndDecodedValuesAreReused() async throws {
        let transport = SlowReleaseTransport(data: Data(Self.releaseResponse.utf8))
        let client = MusicBrainzClient(userAgent: "Tests/1", transport: transport, minimumRequestInterval: .zero)
        let id = "11111111-1111-1111-1111-111111111111"
        try await withThrowingTaskGroup(of: MusicBrainzRelease.self) { group in
            for _ in 0..<8 { group.addTask { try await client.lookupRelease(id: id) } }
            for try await release in group { XCTAssertEqual(release.id, id) }
        }
        _ = try await client.lookupRelease(id: id)
        let count = await transport.count; XCTAssertEqual(count, 1)
        _ = try await client.lookupRelease(id: id, includes: Set(MusicBrainzInclude.allCases))
        let differentIncludes = await transport.count; XCTAssertEqual(differentIncludes, 2)
    }
    func testKnownReleaseIDBypassesSearchWithoutRemovingIdentityChecks() async throws {
        let transport = StubTransport(responses: [Data(Self.releaseResponse.utf8)])
        let client = MusicBrainzClient(userAgent: "Tests/1", transport: transport, minimumRequestInterval: .zero)
        let id = "11111111-1111-1111-1111-111111111111"
        let results = try await client.searchReleases(for: LocalAlbumCandidate(releaseID: id, albumTitle: "Example Album", albumArtist: "Example Artist"))
        _ = try await client.lookupRelease(id: id)
        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 1); XCTAssertEqual(requests[0].url?.lastPathComponent, id)
        XCTAssertEqual(results.first?.id, id)
    }
    func testDecodedCacheHonorsResponseExpiry() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = StubTransport(responses: [Data(Self.releaseResponse.utf8)])
        let client = MusicBrainzClient(userAgent: "Tests/1", transport: transport, cache: MusicBrainzResponseCache(directory: root, lifetime: -1), minimumRequestInterval: .zero)
        _ = try await client.lookupRelease(id: "11111111-1111-1111-1111-111111111111")
        _ = try await client.lookupRelease(id: "11111111-1111-1111-1111-111111111111")
        let requests = await transport.requests(); XCTAssertEqual(requests.count, 2)
    }
    func testDecodedExpiryIsPreservedWhenRawResponseExceedsMemoryCacheBudget() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var json = Self.releaseResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        json.removeLast()
        json.append(",\"ignored\":\"")
        json.append(String(repeating: "x", count: 16 * 1024 * 1024 + 1))
        json.append("\"}")
        let body = Data(json.utf8)
        let transport = StubTransport(responses: [body])
        let cache = MusicBrainzResponseCache(directory: root, lifetime: -1)
        let client = MusicBrainzClient(userAgent: "Tests/1", transport: transport, cache: cache, minimumRequestInterval: .zero)
        _ = try await client.lookupRelease(id: "11111111-1111-1111-1111-111111111111")
        _ = try await client.lookupRelease(id: "11111111-1111-1111-1111-111111111111")
        let requests = await transport.requests(); XCTAssertEqual(requests.count, 2)
    }
    func testCancellingOneSubscriberDoesNotCancelAnother() async throws {
        let transport = SlowReleaseTransport(data: Data(Self.releaseResponse.utf8))
        let client = MusicBrainzClient(userAgent: "Tests/1", transport: transport, minimumRequestInterval: .zero)
        let first = Task { try await client.lookupRelease(id: "11111111-1111-1111-1111-111111111111") }
        for _ in 0..<100 { if await transport.count > 0 { break }; try await Task.sleep(for: .milliseconds(1)) }
        let second = Task { try await client.lookupRelease(id: "11111111-1111-1111-1111-111111111111") }
        try await Task.sleep(for: .milliseconds(5)); first.cancel()
        do { _ = try await first.value; XCTFail("Cancelled subscriber should not receive a result") } catch is CancellationError {}
        let result = try await second.value; XCTAssertEqual(result.tracks.count, 2)
        let count = await transport.count; XCTAssertEqual(count, 1)
    }
    private actor SlowReleaseTransport: MusicBrainzTransport {
        let data: Data
        var count = 0
        init(data: Data) { self.data = data }
        func data(for request: URLRequest) async throws -> MusicBrainzHTTPResponse {
            count += 1; try await Task.sleep(for: .milliseconds(50))
            return MusicBrainzHTTPResponse(statusCode: 200, data: data)
        }
    }
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
        let requests = await transport.requests()
        let items = URLComponents(url: try XCTUnwrap(requests.first?.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items?.first(where: { $0.name == "inc" })?.value, "artist-credits isrcs labels media recordings release-groups")
        XCTAssertEqual(items?.first(where: { $0.name == "fmt" })?.value, "json")
        XCTAssertFalse(requests[0].url!.absoluteString.contains(","))
    }

    func testIncludesDependenciesAndEmptyIncludesAreEncodedCorrectly() async throws {
        let transport = StubTransport(responses: [Data(Self.releaseResponse.utf8)])
        let client = MusicBrainzClient(userAgent: "Tests/1.0", transport: transport, minimumRequestInterval: .zero)
        _ = try await client.lookupRelease(id: " 11111111-1111-1111-1111-111111111111 ", includes: [.isrcs])
        _ = try await client.lookupRelease(id: "11111111-1111-1111-1111-111111111111", includes: [])
        let requests = await transport.requests()
        let first = URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems
        let second = URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(first?.first(where: { $0.name == "inc" })?.value, "isrcs recordings")
        XCTAssertNil(second?.first(where: { $0.name == "inc" }))
    }

    func testInvalidIdentifiersAndBlankQueriesNeverReachTransport() async throws {
        let transport = StubTransport(responses: [Data(Self.releaseResponse.utf8)])
        let client = MusicBrainzClient(userAgent: "Tests/1.0", transport: transport, minimumRequestInterval: .zero)
        for identifier in ["", "release/not-a-uuid", "../artist", "123"] {
            do { _ = try await client.lookupRelease(id: identifier); XCTFail("Expected invalid ID") }
            catch is MusicBrainzError { }
        }
        do { _ = try await client.searchReleases(query: "  "); XCTFail("Expected blank query rejection") }
        catch is MusicBrainzError { }
        let requests = await transport.requests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testMetadataSearchEscapesLuceneReservedCharacters() async throws {
        let transport = StubTransport(responses: [Data(Self.searchResponse.utf8)])
        let client = MusicBrainzClient(userAgent: "Tests/1.0", transport: transport, minimumRequestInterval: .zero)
        _ = try await client.searchReleases(for: LocalAlbumCandidate(albumTitle: "The \"Album\" (Deluxe)", albumArtist: "AC/DC", barcode: "  "))
        let requests = await transport.requests()
        let items = URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items?.first(where: { $0.name == "query" })?.value, #"release:"The \"Album\" \(Deluxe\)" AND artist:"AC\/DC""#)
    }

    func testPermanentErrorsAreNotRetriedAndMalformedJSONIsNotCached() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = ContractTransport(responses: [
            MusicBrainzHTTPResponse(statusCode: 400, data: Data(#"{"error":"invalid inc","help":"help URL"}"#.utf8)),
            MusicBrainzHTTPResponse(statusCode: 200, data: Data("not JSON".utf8)),
            MusicBrainzHTTPResponse(statusCode: 200, data: Data(Self.searchResponse.utf8))
        ])
        let client = MusicBrainzClient(userAgent: "Tests/1.0", transport: transport, cache: MusicBrainzResponseCache(directory: root), minimumRequestInterval: .zero)
        do { _ = try await client.searchReleases(query: "a"); XCTFail("Expected HTTP 400") }
        catch let error as MusicBrainzError { XCTAssertEqual(error, .httpStatus(400, "invalid inc")) }
        do { _ = try await client.searchReleases(query: "a"); XCTFail("Expected decode failure") }
        catch let error as MusicBrainzError { guard case .decoding = error else { return XCTFail("Expected decoding error") } }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        let releases = try await client.searchReleases(query: "a")
        XCTAssertEqual(releases.count, 1)
        let count = await transport.requestCount()
        XCTAssertEqual(count, 3)
    }

    func testRateLimitIsSharedAcrossClientInstances() async throws {
        let transport = ContractTransport(responses: [MusicBrainzHTTPResponse(statusCode: 200, data: Data(Self.searchResponse.utf8))])
        let limiter = APIRequestRateLimiter()
        let clients = (0..<2).map { _ in MusicBrainzClient(userAgent: "Tests/1.0", transport: transport, minimumRequestInterval: .milliseconds(30), rateLimiter: limiter) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<6 { group.addTask { _ = try await clients[index % 2].searchReleases(query: "query \(index)") } }
            try await group.waitForAll()
        }
        let times = await transport.times()
        for pair in zip(times, times.dropFirst()) { XCTAssertGreaterThanOrEqual(pair.0.duration(to: pair.1), .milliseconds(25)) }
    }

    func testLiveReleaseSearchAndDetailLookup() async throws {
        guard ProcessInfo.processInfo.environment["MACPICARD_LIVE_API_TESTS"] == "1" else { throw XCTSkip("Opt-in live API verification") }
        let client = MusicBrainzClient(userAgent: AppConfiguration.defaultUserAgent)
        let results = try await client.searchReleases(for: LocalAlbumCandidate(albumTitle: "Lukas Graham", albumArtist: "Lukas Graham", barcode: "093624920496"))
        XCTAssertFalse(results.isEmpty)
        let release = try await client.lookupRelease(id: "5e0abf8a-c77a-4826-b435-b3c23b22c0b1")
        XCTAssertEqual(release.title, "Lukas Graham")
        XCTAssertEqual(release.tracks.count, 11)
        XCTAssertEqual(release.tracks.first?.title, "7 Years")
        XCTAssertFalse(release.tracks.first?.isrcs.isEmpty ?? true)
    }

    private actor ContractTransport: MusicBrainzTransport {
        let responses: [MusicBrainzHTTPResponse]
        var recordedTimes: [ContinuousClock.Instant] = []
        init(responses: [MusicBrainzHTTPResponse]) { self.responses = responses }
        func data(for request: URLRequest) async throws -> MusicBrainzHTTPResponse {
            let index = min(recordedTimes.count, responses.count - 1)
            recordedTimes.append(.now)
            return responses[index]
        }
        func requestCount() -> Int { recordedTimes.count }
        func times() -> [ContinuousClock.Instant] { recordedTimes }
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

    func testConcurrentSearchesRemainDeterministic() async throws {
        let transport = StubTransport(responses: [Data(Self.searchResponse.utf8)])
        let client = MusicBrainzClient(
            baseURL: URL(string: "https://musicbrainz.example/ws/2")!,
            userAgent: "MacPicardTests/1.0",
            transport: transport,
            minimumRequestInterval: .zero
        )

        let successfulRequests = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for index in 0..<64 {
                group.addTask {
                    do {
                        let results = try await client.searchReleases(query: "release:Concurrent-\(index)")
                        return results.count == 1 && results[0].id == "11111111-1111-1111-1111-111111111111"
                    } catch {
                        return false
                    }
                }
            }

            var count = 0
            for await success in group where success {
                count += 1
            }
            return count
        }

        XCTAssertEqual(successfulRequests, 64)
        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 64)
    }

    func testCancelledRequestPropagatesCancellation() async throws {
        let client = MusicBrainzClient(
            baseURL: URL(string: "https://musicbrainz.example/ws/2")!,
            userAgent: "MacPicardTests/1.0",
            transport: CancellationTransport(),
            minimumRequestInterval: .zero
        )
        let request = Task {
            try await client.searchReleases(query: "release:cancelled")
        }

        try await Task.sleep(for: .milliseconds(20))
        request.cancel()

        do {
            _ = try await request.value
            XCTFail("A cancelled MusicBrainz request must not return a result")
        } catch is CancellationError {
            // Expected cancellation path.
        }
    }

    func testTrackMatcherScalesToAReleaseSizedLibrary() {
        let localTracks = (0..<256).map { index in
            LocalTrackCandidate(
                title: "Track \(index)",
                durationInMilliseconds: 180_000 + index,
                trackNumber: index + 1
            )
        }
        let releaseTracks = (0..<256).map { index in
            MusicBrainzTrack(
                id: "track-\(index)",
                recordingID: "recording-\(index)",
                title: "Track \(index)",
                artistCredit: "Example Artist",
                lengthInMilliseconds: 180_000 + index,
                number: String(index + 1),
                position: index + 1,
                isrcs: []
            )
        }

        let matches = TrackMatcher(minimumSimilarity: 0.50).match(
            localTracks: localTracks,
            releaseTracks: releaseTracks
        )

        XCTAssertEqual(matches.count, 256)
        XCTAssertEqual(Set(matches.compactMap(\.releaseTrackID)).count, 256)
        XCTAssertTrue(matches.allSatisfy { $0.decision != .unmatched })
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

    private struct CancellationTransport: MusicBrainzTransport {
        func data(for request: URLRequest) async throws -> MusicBrainzHTTPResponse {
            try await Task.sleep(for: .seconds(10))
            return MusicBrainzHTTPResponse(
                statusCode: 200,
                data: Data(#"{"releases":[]}"#.utf8)
            )
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
