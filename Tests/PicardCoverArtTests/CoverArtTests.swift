import Foundation
import XCTest
@testable import PicardCoverArt
import PicardFoundation

final class CoverArtTests: XCTestCase {
    func testTemporaryServerFailureRetriesButPermanentErrorsDoNot() async throws {
        let json = Data(#"{"images":[]}"#.utf8)
        let transport = HTTPSequenceTransport(responses: [
            CoverArtHTTPResponse(statusCode: 500, headers: ["Retry-After": "0.001"], data: Data()),
            CoverArtHTTPResponse(statusCode: 200, data: json)
        ])
        let client = CoverArtClient(userAgent: "Tests/1.0", transport: transport, minimumRequestInterval: .zero, rateLimiter: APIRequestRateLimiter())
        let release = try await client.release(identifier: Self.releaseID)
        XCTAssertTrue(release.images.isEmpty)
        let attempts = await transport.requests()
        XCTAssertEqual(attempts.count, 2)

        let permanent = HTTPSequenceTransport(responses: [CoverArtHTTPResponse(statusCode: 404, data: Data())])
        let missing = CoverArtClient(userAgent: "Tests/1.0", transport: permanent, minimumRequestInterval: .zero, rateLimiter: APIRequestRateLimiter())
        do { _ = try await missing.release(identifier: Self.releaseID); XCTFail("Expected HTTP 404") }
        catch let error as CoverArtError { guard case .httpStatus(404, _) = error else { return XCTFail("Expected HTTP 404") } }
        let permanentAttempts = await permanent.requests()
        XCTAssertEqual(permanentAttempts.count, 1)
    }

    func testStringImageIdentifiersAndReleaseGroupEndpoint() async throws {
        let transport = StubTransport(responses: [Data(#"{"images":[{"id":"19383654919","types":["Front"],"image":"https://coverartarchive.org/release/album/front.jpg"}]}"#.utf8)])
        let client = CoverArtClient(userAgent: "Tests/1.0", transport: transport, minimumRequestInterval: .zero)
        let release = try await client.releaseGroup(identifier: Self.releaseID.uppercased())
        XCTAssertEqual(release.images.first?.id, "19383654919")
        let requests = await transport.requests()
        XCTAssertEqual(requests.first?.url?.path, "/release-group/\(Self.releaseID)")
        do { _ = try await client.release(identifier: "../invalid"); XCTFail("Expected invalid MBID") }
        catch let error as CoverArtError { XCTAssertEqual(error, .invalidIdentifier) }
        let afterInvalid = await transport.requests()
        XCTAssertEqual(afterInvalid.count, 1)
    }

    func testMalformedImagesAreNotCachedAndCanBeRetriedExplicitly() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = StubTransport(responses: [Data("not an image".utf8), try XCTUnwrap(Data(base64Encoded: Self.onePixelPNG))])
        let client = CoverArtClient(userAgent: "Tests/1.0", transport: transport, cacheDirectory: directory, minimumRequestInterval: .zero)
        let image = CoverArtImage(id: "1", types: [.front], imageURL: URL(string: "https://images.example/front.png")!)
        do { _ = try await client.download(image); XCTFail("Expected invalid image") }
        catch let error as CoverArtError { guard case .invalidImage = error else { return XCTFail("Expected invalid image") } }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        let artwork = try await client.download(image)
        XCTAssertEqual(artwork.width, 1)
        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 2)
    }

    func testLegacyArchiveImageAndThumbnailURLsUseHTTPS() async throws {
        let imageData = try XCTUnwrap(Data(base64Encoded: Self.onePixelPNG))
        let transport = StubTransport(responses: [
            Data(#"{"images":[{"id":19383654919,"types":["Front"],"image":"http://coverartarchive.org/release/album/19383654919.jpg","thumbnails":{"250":"http://coverartarchive.org/release/album/19383654919-250.jpg","500":"http://archive.org/download/album/cover-500.jpg","1200":"http://ia800123.us.archive.org/items/album/cover-1200.jpg"}}]}"#.utf8),
            imageData
        ])
        let client = CoverArtClient(userAgent: "MacPicardTests/1.0", transport: transport, minimumRequestInterval: .zero)

        let release = try await client.release(identifier: Self.releaseID)
        let image = try XCTUnwrap(release.images.first)
        XCTAssertEqual(image.imageURL.absoluteString, "https://coverartarchive.org/release/album/19383654919.jpg")
        for size in CoverArtImageSize.allCases {
            XCTAssertEqual(image.url(for: size).scheme, "https")
            let artwork = try await client.download(image, size: size)
            XCTAssertEqual(artwork.width, 1)
            XCTAssertEqual(artwork.source, .remote(image.url(for: size)))
        }
        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 5)
        XCTAssertTrue(requests.allSatisfy { $0.url?.scheme == "https" })
    }

    func testPreviouslyCachedHTTPArchiveLinksAreUpgraded() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let response = Data(#"{"images":[{"id":1,"types":["Front"],"image":"http://coverartarchive.org/release/album/front.jpg"}]}"#.utf8)
        let firstTransport = StubTransport(responses: [response])
        let first = CoverArtClient(userAgent: "MacPicardTests/1.0", transport: firstTransport, cacheDirectory: directory, minimumRequestInterval: .zero)
        _ = try await first.release(identifier: Self.releaseID)

        let secondTransport = StubTransport(responses: [Data()])
        let restored = CoverArtClient(userAgent: "MacPicardTests/1.0", transport: secondTransport, cacheDirectory: directory, minimumRequestInterval: .zero)
        let release = try await restored.release(identifier: Self.releaseID)
        XCTAssertEqual(release.images.first?.imageURL.scheme, "https")
        let requests = await secondTransport.requests()
        XCTAssertTrue(requests.isEmpty, "The old cached JSON should work without deleting the cache.")
    }

    func testURLPolicyPreservesPathsQueriesAndRequestHeaders() throws {
        let original = URL(string: "http://archive.org:80/download/album/front%20cover.jpg?token=a%2Fb&size=1200#cover")!
        var request = URLRequest(url: original)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 12
        request.setValue("MacPicardTests/1.0", forHTTPHeaderField: "User-Agent")
        let secured = try CoverArtURLPolicy.secureRequest(request)
        XCTAssertEqual(secured.url?.absoluteString, "https://archive.org/download/album/front%20cover.jpg?token=a%2Fb&size=1200#cover")
        XCTAssertEqual(secured.httpMethod, "HEAD")
        XCTAssertEqual(secured.timeoutInterval, 12)
        XCTAssertEqual(secured.value(forHTTPHeaderField: "User-Agent"), "MacPicardTests/1.0")

        let https = URL(string: "https://images.example:8443/front.jpg?size=1200")!
        XCTAssertEqual(try CoverArtURLPolicy.secureURL(https), https)
    }

    func testUnsafeArtworkURLsAreRejectedBeforeTransport() async throws {
        let urls = [
            "http://images.example/front.jpg",
            "http://archive.org.evil.example/front.jpg",
            "http://evilarchive.org/front.jpg",
            "http://archive.org:8080/front.jpg",
            "https://user:password@archive.org/front.jpg",
            "file:///tmp/front.jpg",
            "ftp://archive.org/front.jpg",
            "/relative/front.jpg"
        ]
        let transport = StubTransport(responses: [Data()])
        let client = CoverArtClient(userAgent: "MacPicardTests/1.0", transport: transport, minimumRequestInterval: .zero)
        for value in urls {
            let image = CoverArtImage(id: "1", types: [.front], imageURL: URL(string: value)!)
            do {
                _ = try await client.download(image)
                XCTFail("Unsafe URL was accepted: \(value)")
            } catch let error as CoverArtError {
                switch error {
                case .insecureURL, .invalidURL: break
                default: XCTFail("Unexpected error: \(error)")
                }
            }
        }
        let requests = await transport.requests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testRedirectDelegateUpgradesArchiveDowngradesAndRejectsOtherHTTPHosts() async throws {
        let session = URLSession.shared
        let source = URL(string: "https://coverartarchive.org/release/album/front")!
        let task = session.dataTask(with: source)
        defer { task.cancel() }
        let response = try XCTUnwrap(HTTPURLResponse(url: source, statusCode: 307, httpVersion: nil, headerFields: nil))
        for (target, expected) in [
            ("http://archive.org/download/album/front.jpg", "https://archive.org/download/album/front.jpg"),
            ("http://ia800123.us.archive.org/items/album/front.jpg", "https://ia800123.us.archive.org/items/album/front.jpg"),
            ("https://images.example/front.jpg", "https://images.example/front.jpg"),
            ("http://images.example/front.jpg", nil),
            ("http://archive.org.evil.example/front.jpg", nil)
        ] as [(String, String?)] {
            let redirected: URLRequest? = await withCheckedContinuation { continuation in
                CoverArtRedirectDelegate.shared.urlSession(
                    session, task: task, willPerformHTTPRedirection: response,
                    newRequest: URLRequest(url: URL(string: target)!),
                    completionHandler: { continuation.resume(returning: $0) }
                )
            }
            XCTAssertEqual(redirected?.url?.absoluteString, expected)
        }
    }

    /// Opt in explicitly; ordinary unit tests must not depend on Internet Archive availability.
    func testLiveLukasGrahamCoverArtDownload() async throws {
        guard ProcessInfo.processInfo.environment["MACPICARD_LIVE_COVER_ART_TEST"] == "1" else {
            throw XCTSkip("Set MACPICARD_LIVE_COVER_ART_TEST=1 to check the real archive.")
        }
        let client = CoverArtClient(userAgent: "MacPicardTests/0.1.0 (cover art integration test)")
        let release = try await client.release(identifier: "5e0abf8a-c77a-4826-b435-b3c23b22c0b1")
        let image = try XCTUnwrap(release.images.first(where: { $0.types.contains(.front) }))
        XCTAssertEqual(image.imageURL.scheme, "https")
        let artwork = try await client.download(image, size: .thumbnail1200)
        XCTAssertGreaterThan(artwork.data?.count ?? 0, 0)
        XCTAssertGreaterThan(artwork.width ?? 0, 0)
        XCTAssertGreaterThan(artwork.height ?? 0, 0)
        guard case let .remote(url) = artwork.source else { return XCTFail("Expected remote artwork") }
        XCTAssertEqual(url.scheme, "https")
    }

    func testLiveLukasGrahamReleaseGroupLookup() async throws {
        guard ProcessInfo.processInfo.environment["MACPICARD_LIVE_COVER_ART_TEST"] == "1" else {
            throw XCTSkip("Set MACPICARD_LIVE_COVER_ART_TEST=1 to check the real archive.")
        }
        let client = CoverArtClient(userAgent: AppConfiguration.defaultUserAgent)
        let group = try await client.releaseGroup(identifier: "0198c1e1-d8eb-4cd2-a7c6-65127ef77142")
        XCTAssertFalse(group.images.isEmpty)
        XCTAssertTrue(group.images.allSatisfy { $0.imageURL.scheme == "https" })
    }

    func testCoverArtClientDecodesReleaseImagesAndDownloadsArtwork() async throws {
        let imageData = try XCTUnwrap(Data(base64Encoded: Self.onePixelPNG))
        let transport = StubTransport(responses: [
            Data(#"{"images":[{"id":1,"types":["Front"],"comment":"Cover","approved":true,"image":"https://images.example/front.jpg","thumbnails":{"250":"https://images.example/front-250.jpg"}}]}"#.utf8),
            imageData
        ])
        let client = CoverArtClient(
            baseURL: URL(string: "https://coverart.example")!,
            userAgent: "MacPicardTests/1.0",
            transport: transport,
            minimumRequestInterval: .zero
        )

        let release = try await client.release(identifier: Self.releaseID)
        let artwork = try await client.download(release.images[0], size: .original)

        XCTAssertEqual(release.images[0].primaryType, .front)
        XCTAssertEqual(release.images[0].comment, "Cover")
        XCTAssertEqual(artwork.width, 1)
        XCTAssertEqual(artwork.height, 1)
        XCTAssertEqual(artwork.mimeType, "image/png")
        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Accept"), "image/*")
    }

    func testArtworkProcessorResizesAndDeduplicates() throws {
        let data = try XCTUnwrap(Data(base64Encoded: Self.onePixelPNG))
        let resized = try ArtworkProcessor.resize(data, maximumPixelSize: 64, format: .png)
        let info = try ArtworkProcessor.inspect(resized)
        let first = Artwork(type: .front, mimeType: info.mimeType, source: .generated, data: resized)
        let duplicate = Artwork(type: .back, mimeType: info.mimeType, source: .generated, data: resized)

        XCTAssertEqual(info.width, 1)
        XCTAssertEqual(info.height, 1)
        XCTAssertEqual(ArtworkProcessor.deduplicate([first, duplicate, first]).count, 2, "Different image roles must survive deduplication")
    }

    func testLocalArtworkFinderClassifiesAndDeduplicatesFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = try XCTUnwrap(Data(base64Encoded: Self.onePixelPNG))
        try data.write(to: directory.appendingPathComponent("front.png"))
        try data.write(to: directory.appendingPathComponent("back.png"))
        try data.write(to: directory.appendingPathComponent("cover-copy.png"))

        let collection = try LocalArtworkFinder().discover(in: directory)

        XCTAssertEqual(collection.images.count, 2)
        XCTAssertEqual(collection.images[0].type, .back)
        XCTAssertTrue(collection.images.allSatisfy { $0.width == 1 && $0.height == 1 })
    }

    private actor StubTransport: CoverArtTransport {
        private let responses: [Data]
        private var index = 0
        private var recordedRequests: [URLRequest] = []

        init(responses: [Data]) { self.responses = responses }

        func data(for request: URLRequest) async throws -> CoverArtHTTPResponse {
            recordedRequests.append(request)
            let data = responses[min(index, responses.count - 1)]
            index += 1
            return CoverArtHTTPResponse(statusCode: 200, data: data)
        }

        func requests() -> [URLRequest] { recordedRequests }
    }

    private actor HTTPSequenceTransport: CoverArtTransport {
        private let responses: [CoverArtHTTPResponse]
        private var recordedRequests: [URLRequest] = []
        init(responses: [CoverArtHTTPResponse]) { self.responses = responses }
        func data(for request: URLRequest) async throws -> CoverArtHTTPResponse {
            recordedRequests.append(request)
            return responses[min(recordedRequests.count - 1, responses.count - 1)]
        }
        func requests() -> [URLRequest] { recordedRequests }
    }

    private static let onePixelPNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    private static let releaseID = "5e0abf8a-c77a-4826-b435-b3c23b22c0b1"
}
