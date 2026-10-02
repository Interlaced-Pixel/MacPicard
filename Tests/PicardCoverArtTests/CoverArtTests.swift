import Foundation
import XCTest
@testable import PicardCoverArt
import PicardFoundation

final class CoverArtTests: XCTestCase {
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

        let release = try await client.release(identifier: "release-1")
        let artwork = try await client.download(release.images[0], size: .original)

        XCTAssertEqual(release.images[0].primaryType, .front)
        XCTAssertEqual(release.images[0].comment, "Cover")
        XCTAssertEqual(artwork.width, 1)
        XCTAssertEqual(artwork.height, 1)
        XCTAssertEqual(artwork.mimeType, "image/png")
        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 2)
    }

    func testArtworkProcessorResizesAndDeduplicates() throws {
        let data = try XCTUnwrap(Data(base64Encoded: Self.onePixelPNG))
        let resized = try ArtworkProcessor.resize(data, maximumPixelSize: 64, format: .png)
        let info = try ArtworkProcessor.inspect(resized)
        let first = Artwork(type: .front, mimeType: info.mimeType, source: .generated, data: resized)
        let duplicate = Artwork(type: .back, mimeType: info.mimeType, source: .generated, data: resized)

        XCTAssertEqual(info.width, 1)
        XCTAssertEqual(info.height, 1)
        XCTAssertEqual(ArtworkProcessor.deduplicate([first, duplicate]).count, 1)
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

        XCTAssertEqual(collection.images.count, 1)
        XCTAssertEqual(collection.images[0].type, .back)
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

    private static let onePixelPNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
}
