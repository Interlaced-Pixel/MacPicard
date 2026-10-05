import CoreGraphics
import Foundation
import ImageIO
import PicardFoundation
import UniformTypeIdentifiers
import XCTest
@testable import PicardCoverArt

final class ArtworkManagementTests: XCTestCase {
    func testThumbnailRequestsShareOneDecodeAndRespectPixelSize() async throws {
        let artwork = Artwork(mimeType: "image/png", source: .generated, data: try png())
        let cache = ArtworkThumbnailCache()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<10 { group.addTask {
                let raster = try await cache.thumbnail(artwork, pixels: 6)
                XCTAssertEqual(raster.image.width, 6); XCTAssertEqual(raster.image.height, 4)
            } }
            try await group.waitForAll()
        }
        let decodes = await cache.decodeCount
        XCTAssertEqual(decodes, 1)
        _ = try await cache.thumbnail(artwork, pixels: 6)
        let stillOne = await cache.decodeCount; XCTAssertEqual(stillOne, 1)
        let larger = try await cache.thumbnail(artwork, pixels: 12)
        XCTAssertEqual(larger.image.width, 12)
        let differentSize = await cache.decodeCount; XCTAssertEqual(differentSize, 2)
        let malformed = Artwork(mimeType: "image/png", source: .embedded, data: Data("invalid".utf8))
        do { _ = try await cache.thumbnail(malformed, pixels: 6); XCTFail("No raster for invalid data") } catch {}
    }
    func testThumbnailCacheHasBoundedRetention() async throws {
        let cache = ArtworkThumbnailCache(costLimit: 1)
        let artwork = Artwork(mimeType: "image/png", source: .generated, data: try png())
        _ = try await cache.thumbnail(artwork, pixels: 6)
        _ = try await cache.thumbnail(artwork, pixels: 6)
        let count = await cache.decodeCount
        XCTAssertEqual(count, 2, "An image larger than the budget is not retained")
    }
    func testBoundsMalformedAndAnimatedImages() throws {
        XCTAssertThrowsError(try ArtworkProcessor.inspect(Data("invalid".utf8)))
        XCTAssertThrowsError(try ArtworkProcessor.inspect(Data(repeating: 0, count: ArtworkValidation.maximumBytes + 1)))
        let image = try makeImage()
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.gif.identifier as CFString, 2, nil))
        CGImageDestinationAddImage(destination, image, nil); CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertThrowsError(try ArtworkProcessor.inspect(output as Data))

        // Valid CRC for an excessive PNG IHDR: rejected from headers before allocating a raster.
        var huge = [UInt8](try png())
        huge.replaceSubrange(16..<20, with: [0, 1, 0, 0])
        let crc = checksum(Array(huge[12..<29]))
        huge.replaceSubrange(29..<33, with: [UInt8((crc >> 24) & 255), UInt8((crc >> 16) & 255), UInt8((crc >> 8) & 255), UInt8(crc & 255)])
        XCTAssertThrowsError(try ArtworkProcessor.inspect(Data(huge)))
        XCTAssertThrowsError(try ArtworkProcessor.resize(try png(), maximumPixelSize: 0))
        XCTAssertThrowsError(try ArtworkProcessor.resize(try png(), maximumPixelSize: 20, quality: .nan))
        let large = Artwork(mimeType: "image/png", source: .generated, data: Data(repeating: 0, count: ArtworkValidation.maximumBytes))
        XCTAssertThrowsError(try ArtworkValidation.validateCollectionSize(Array(repeating: large, count: 5)))
    }

    func testOrientationAndTransparentJPEGBackground() throws {
        let image = try makeImage(width: 12, height: 8)
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let info = try ArtworkProcessor.inspect(output as Data)
        XCTAssertEqual(info.width, 8); XCTAssertEqual(info.height, 12)
        let resized = try ArtworkProcessor.resize(output as Data, maximumPixelSize: 6, format: .png)
        let smaller = try ArtworkProcessor.inspect(resized)
        XCTAssertEqual(smaller.width, 4); XCTAssertEqual(smaller.height, 6)

        let jpeg = try ArtworkProcessor.resize(try png(), maximumPixelSize: 20, format: .jpeg, quality: 1)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(decoded, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let pixel = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        XCTAssertGreaterThan(pixel[0], 245); XCTAssertGreaterThan(pixel[1], 245); XCTAssertGreaterThan(pixel[2], 245)
    }

    func testLocalImportsDimensionsAndBackCoverClassification() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("back-cover.png")
        try png().write(to: file)
        let imported = try ArtworkProcessor.importFile(file)
        XCTAssertEqual(imported.width, 12); XCTAssertEqual(imported.height, 8)
        XCTAssertEqual(imported.source, .localFile(file))
        let found = try LocalArtworkFinder().discover(in: directory)
        XCTAssertEqual(found.images.first?.type, .back)
        XCTAssertThrowsError(try ArtworkProcessor.importFile(directory))
    }

    func testExportReviewCollisionsUniqueNamesAndNoOverwrite() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let image = Artwork(mimeType: "image/png", source: .generated, data: try png())
        let first = try ArtworkExporter.review([image], directory: directory, policy: .stop)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty, "Review must not write")
        let urls = try ArtworkExporter.execute(first)
        XCTAssertEqual(try Data(contentsOf: urls[0]), image.data)
        XCTAssertThrowsError(try ArtworkExporter.execute(first))
        XCTAssertThrowsError(try ArtworkExporter.review([image], directory: directory, policy: .stop))
        let unique = try ArtworkExporter.review([image, image], directory: directory, policy: .uniqueNames)
        XCTAssertEqual(unique.items.map(\.filename), ["front-01-2.png", "front-02.png"])
        _ = try ArtworkExporter.execute(unique)
        XCTAssertEqual(try Data(contentsOf: urls[0]), image.data)
    }

    func testExportRefusesNewCollisionSymlinkAndChangedDirectory() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Export"); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = Artwork(mimeType: "image/png", source: .generated, data: try png())
        let plan = try ArtworkExporter.review([image], directory: directory, policy: .stop)
        let victim = root.appendingPathComponent("UserFile"); let original = Data("keep".utf8); try original.write(to: victim)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent(plan.items[0].filename), withDestinationURL: victim)
        XCTAssertThrowsError(try ArtworkExporter.execute(plan))
        XCTAssertEqual(try Data(contentsOf: victim), original)
        try FileManager.default.moveItem(at: directory, to: root.appendingPathComponent("Moved"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertThrowsError(try ArtworkExporter.execute(plan))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testHTTPSImportAndOversizeTransportAreValidatedBeforeCaching() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let transport = ImportTransport(data: try png())
        let client = CoverArtClient(userAgent: "Tests/1", transport: transport, cacheDirectory: directory, minimumRequestInterval: .zero)
        for value in ["http://archive.org/image.png", "file:///tmp/image.png", "https://user:pass@example.com/image.png"] {
            do { _ = try await client.download(url: URL(string: value)!); XCTFail("Unsafe URL") } catch {}
        }
        let count = await transport.count; XCTAssertEqual(count, 0)
        let result = try await client.download(url: URL(string: "https://example.com/image.png")!)
        XCTAssertEqual(result.width, 12); XCTAssertEqual(result.height, 8)
        let oversized = CoverArtClient(userAgent: "Tests/1", transport: ImportTransport(data: Data(repeating: 0, count: ArtworkValidation.maximumBytes + 1)), minimumRequestInterval: .zero)
        do { _ = try await oversized.download(url: URL(string: "https://example.com/image.png")!); XCTFail("Oversized import") } catch {}
    }

    private func temporaryDirectory() throws -> URL {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent("ArtworkTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true); return result
    }
    private func makeImage(width: Int = 12, height: Int = 8) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }
    private func png() throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try makeImage(), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination)); return data as Data
    }
    private func checksum(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in bytes { crc ^= UInt32(byte); for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0) } }
        return crc ^ 0xffffffff
    }
}

private actor ImportTransport: CoverArtTransport {
    let data: Data
    var count = 0
    init(data: Data) { self.data = data }
    func data(for request: URLRequest) async throws -> CoverArtHTTPResponse { count += 1; return .init(statusCode: 200, data: data) }
}
