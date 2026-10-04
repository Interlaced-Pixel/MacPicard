import Foundation
import CoreGraphics
import ImageIO
import PicardFoundation
import XCTest
@testable import PicardFormats

final class FormatEngineTests: XCTestCase {
    private static let temporaryRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("MacPicardFormatTests-\(UUID().uuidString)")

    override class func setUp() {
        super.setUp()
        try? FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override class func tearDown() {
        try? FileManager.default.removeItem(at: temporaryRoot)
        super.tearDown()
    }

    func testRegistryDetectsSupportedHeaders() throws {
        let registry = FormatRegistry()

        let wav = try makeFile(name: "header.wav", data: Self.wavHeader)
        let flac = try makeFile(name: "header.flac", data: Data("fLaC".utf8))
        let ogg = try makeFile(name: "header.ogg", data: Data("OggS\0\0\0\0vorbis".utf8))
        let mp4 = try makeFile(name: "header.m4a", data: Self.mp4Header)
        let mp3 = try makeFile(name: "header.mp3", data: Data("ID3\u{04}\u{00}".utf8))

        XCTAssertEqual(try registry.detect(url: wav), .wav)
        XCTAssertEqual(try registry.detect(url: flac), .flac)
        XCTAssertEqual(try registry.detect(url: ogg), .oggVorbis)
        XCTAssertEqual(try registry.detect(url: mp4), .mp4)
        XCTAssertEqual(try registry.detect(url: mp3), .mp3)
    }

    func testRegistryDetectsOpusHeader() throws {
        let registry = FormatRegistry()
        let ogg = try makeFile(
            name: "header.opus",
            data: Data("OggS\0\0\0\0OpusHead".utf8)
        )

        XCTAssertEqual(try registry.detect(url: ogg), .oggOpus)
    }

    func testFormatsRoundTripThroughTagLib() async throws {
        let fixtures: [(extensionName: String, codec: String, expected: AudioFormat)] = [
            ("mp3", "libmp3lame", .mp3),
            ("flac", "flac", .flac),
            ("m4a", "aac", .mp4),
            ("ogg", "vorbis", .oggVorbis),
            ("opus", "libopus", .oggOpus),
            ("wav", "pcm_s16le", .wav)
        ]
        let engine = FormatEngine()
        var executedFixtures = 0

        for fixture in fixtures {
            guard let url = try makeAudioFixture(extensionName: fixture.extensionName, codec: fixture.codec) else {
                continue
            }
            executedFixtures += 1
            defer { try? FileManager.default.removeItem(at: url) }

            let readResult = try await engine.read(url: url)
            XCTAssertEqual(readResult.format, fixture.expected, fixture.extensionName)
            XCTAssertEqual(readResult.metadata.firstValue(for: "title"), "Original Title")
            XCTAssertEqual(readResult.metadata.firstValue(for: "artist"), "Original Artist")
            XCTAssertNotNil(readResult.audioProperties)

            var metadata = readResult.metadata
            metadata.setValue("Jane Doe", for: "composer")
            metadata.setValues(["Rock", "Soul"], for: "genre")
            metadata.setValue("Custom value", for: "macpicard_custom")
            metadata.setValue("87e36ab4-6914-44ab-b740-7abb37678040", for: "musicbrainz_trackid")
            metadata.setValue("0c30e8e9-8368-4f2f-ab95-d6f9549eb54f", for: "musicbrainz_releasetrackid")
            let artwork = ArtworkCollection(images: [
                Artwork(
                    mimeType: "image/png",
                    description: "front",
                    source: .generated,
                    data: Self.pngData
                )
            ])

            let writeResult = try await engine.write(url: url, metadata: metadata, artwork: artwork)
            XCTAssertEqual(writeResult.format, fixture.expected)
            XCTAssertEqual(writeResult.writtenArtworkCount, 1)

            let reopened = try await engine.read(url: url)
            XCTAssertEqual(reopened.metadata.firstValue(for: "composer"), "Jane Doe")
            XCTAssertEqual(reopened.metadata.values(for: "genre"), ["Rock", "Soul"], fixture.extensionName)
            XCTAssertEqual(reopened.metadata.firstValue(for: "macpicard_custom"), "Custom value", fixture.extensionName)
            XCTAssertEqual(reopened.metadata.firstValue(for: "title"), "Original Title", fixture.extensionName)
            XCTAssertEqual(reopened.metadata.firstValue(for: "musicbrainz_trackid"), "87e36ab4-6914-44ab-b740-7abb37678040", fixture.extensionName)
            XCTAssertEqual(reopened.metadata.firstValue(for: "musicbrainz_releasetrackid"), "0c30e8e9-8368-4f2f-ab95-d6f9549eb54f", fixture.extensionName)
            XCTAssertEqual(reopened.artwork.images.count, 1, fixture.extensionName)
            XCTAssertEqual(reopened.artwork.images[0].data, Self.pngData)
            var deleted = reopened.metadata
            deleted.delete("genre"); deleted.delete("macpicard_custom")
            _ = try await engine.write(url: url, metadata: deleted, artwork: reopened.artwork)
            let afterDeletion = try await engine.read(url: url)
            XCTAssertFalse(afterDeletion.metadata.contains("genre"), fixture.extensionName)
            XCTAssertFalse(afterDeletion.metadata.contains("macpicard_custom"), fixture.extensionName)
            XCTAssertEqual(afterDeletion.metadata.firstValue(for: "composer"), "Jane Doe", fixture.extensionName)
        }

        if executedFixtures == 0 {
            throw XCTSkip("No supported FFmpeg encoders were available for format fixtures")
        }
        XCTAssertEqual(executedFixtures, fixtures.count, "Every supported format must round-trip both MusicBrainz identifiers.")
    }

    func testAudioFileCoordinatorPreservesDomainState() async throws {
        guard let url = try makeAudioFixture(extensionName: "flac", codec: "flac") else {
            throw XCTSkip("ffmpeg could not create a FLAC fixture")
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let coordinator = AudioFileCoordinator()
        var file = try await coordinator.load(url: url)
        XCTAssertEqual(file.state, .ready)
        XCTAssertFalse(file.isModified)

        var metadata = file.metadata
        metadata.setValue("Edited Title", for: "title")
        try file.updateMetadata(metadata)
        XCTAssertEqual(file.state, .changed)

        file = try await coordinator.save(file)
        XCTAssertEqual(file.state, .saved)
        XCTAssertFalse(file.isModified)
        XCTAssertEqual(file.originalMetadata.firstValue(for: "title"), "Edited Title")
    }

    func testMultipleArtworkOrderRolesDescriptionsAndRemovalAcrossAllFormats() async throws {
        let fixtures = [("mp3", "libmp3lame"), ("flac", "flac"), ("m4a", "aac"), ("ogg", "vorbis"), ("opus", "libopus"), ("wav", "pcm_s16le")]
        let engine = FormatEngine()
        var count = 0
        for (ext, codec) in fixtures {
            guard let url = try makeAudioFixture(extensionName: ext, codec: codec) else { continue }
            defer { try? FileManager.default.removeItem(at: url) }; count += 1
            let baseline = try await engine.read(url: url)
            let roles: [ArtworkType] = ext == "m4a" ? [.front, .front, .front] : [.back, .other, .front]
            let images = try roles.enumerated().map { index, role in
                Artwork(type: role, mimeType: "image/png", description: "Image \(index)", source: .generated, data: try distinctPNG(index))
            }
            XCTAssertEqual(Set(images.compactMap(\.data)).count, 3, "Distinct bytes must test order even in untyped M4A")
            _ = try await engine.writeAtomically(url: url, metadata: baseline.metadata, artwork: ArtworkCollection(images: images))
            let read = try await engine.read(url: url)
            XCTAssertEqual(read.artwork.images.map(\.type), roles, ext)
            XCTAssertEqual(read.artwork.images.map(\.data), images.map(\.data), ext)
            XCTAssertTrue(read.artwork.images.allSatisfy { $0.width == 1 && $0.height == 1 }, ext)
            if ext != "m4a" { XCTAssertEqual(read.artwork.images.map(\.description), images.map(\.description), ext) }
            _ = try await engine.writeAtomically(url: url, metadata: baseline.metadata, artwork: ArtworkCollection(images: Array(images.reversed())))
            let reversed = try await engine.read(url: url)
            XCTAssertEqual(reversed.artwork.images.map(\.type), roles.reversed(), ext)
            XCTAssertEqual(reversed.artwork.images.map(\.data), images.reversed().map(\.data), ext)
            let intact = try Data(contentsOf: url)
            var bad = images[0]; bad.data = Data("not an image".utf8)
            do { _ = try await engine.writeAtomically(url: url, metadata: baseline.metadata, artwork: ArtworkCollection(images: [bad])); XCTFail("Invalid artwork was written") } catch {}
            XCTAssertEqual(try Data(contentsOf: url), intact, ext)
            if ext == "m4a" {
                var back = images[0]; back.type = .back
                do { _ = try await engine.writeAtomically(url: url, metadata: baseline.metadata, artwork: ArtworkCollection(images: [back])); XCTFail("M4A silently discarded image role") } catch {}
                XCTAssertEqual(try Data(contentsOf: url), intact)
            }
            _ = try await engine.writeAtomically(url: url, metadata: baseline.metadata, artwork: ArtworkCollection())
            let removed = try await engine.read(url: url); XCTAssertTrue(removed.artwork.isEmpty, ext)
        }
        if count == 0 { throw XCTSkip("No FFmpeg fixture encoders available") }
        XCTAssertEqual(count, 6)
    }

    func testArtworkStorageSemanticsAndSavedBaseline() async throws {
        let artwork = ArtworkCollection(images: [Artwork(mimeType: "image/png", description: "Not supported in M4A", source: .generated, data: Self.pngData)])
        XCTAssertEqual(AudioFormat.mp4.artworkForStorage(artwork).images[0].description, "")
        XCTAssertEqual(AudioFormat.flac.artworkForStorage(ArtworkCollection(images: [Artwork(type: .booklet, mimeType: "image/png", source: .generated, data: Self.pngData)])).images[0].type, .leaflet)
        guard let url = try makeAudioFixture(extensionName: "m4a", codec: "aac") else { throw XCTSkip("No AAC fixture encoder") }
        defer { try? FileManager.default.removeItem(at: url) }
        let coordinator = AudioFileCoordinator()
        var file = try await coordinator.load(url: url)
        try file.updateArtwork(artwork)
        let saved = try await coordinator.save(file)
        XCTAssertEqual(saved.artwork.images[0].description, "")
        XCTAssertEqual(saved.originalArtwork, saved.artwork)
        XCTAssertFalse(saved.isModified)
        let reopened = try await coordinator.load(url: url)
        XCTAssertEqual(saved.artwork.images[0].type, reopened.artwork.images[0].type)
        XCTAssertEqual(saved.artwork.images[0].description, reopened.artwork.images[0].description)
    }

    private func distinctPNG(_ index: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: index == 0 ? 1 : 0, green: index == 1 ? 1 : 0, blue: index == 2 ? 1 : 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let image = try XCTUnwrap(context.makeImage()), data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func makeAudioFixture(extensionName: String, codec: String) throws -> URL? {
        guard let ffmpeg = Self.ffmpegPath else {
            return nil
        }

        let url = Self.temporaryRoot.appendingPathComponent("fixture-\(UUID().uuidString).\(extensionName)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "anullsrc=r=44100:cl=\(codec == "vorbis" ? "stereo" : "mono")", "-t", "1",
            "-c:a", codec, "-strict", "-2",
            "-metadata", "title=Original Title",
            "-metadata", "artist=Original Artist",
            "-metadata", "album=Original Album",
            url.path
        ]
        process.standardOutput = Pipe()
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: url.path) else {
            _ = errorPipe.fileHandleForReading.readDataToEndOfFile()
            return nil
        }

        return url
    }

    private func makeFile(name: String, data: Data) throws -> URL {
        let url = Self.temporaryRoot.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private static let ffmpegPath: String? = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", "ffmpeg"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let path = String(
                decoding: output.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : path
        } catch {
            return nil
        }
    }()

    private static let wavHeader = Data([
        0x52, 0x49, 0x46, 0x46, 0x24, 0x00, 0x00, 0x00,
        0x57, 0x41, 0x56, 0x45, 0x66, 0x6D, 0x74, 0x20
    ])

    private static let mp4Header = Data([
        0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70,
        0x4D, 0x34, 0x41, 0x20
    ])

    private static let pngData = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
        0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
        0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
        0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
        0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
        0x42, 0x60, 0x82
    ])
}
