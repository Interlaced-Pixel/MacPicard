// Opt-in measurements for docs/PERFORMANCE_REVIEW_2026-10-05.md.
// Run: MACPICARD_PERF_REVIEW=1 swift test -c release --filter PerformanceReviewBenchmarks
// These measure isolated source paths, not rendered SwiftUI latency.
import CoreGraphics
import Foundation
import ImageIO
import PicardCoverArt
import PicardFoundation
import PicardMusicBrainz
import PicardScripts
import PicardSessions
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import MacPicard

@MainActor
final class PerformanceReviewBenchmarks: XCTestCase {
    private func requireOptIn() throws {
        guard ProcessInfo.processInfo.environment["MACPICARD_PERF_REVIEW"] == "1" else {
            throw XCTSkip("Set MACPICARD_PERF_REVIEW=1 for isolated timing measurements.")
        }
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let value = duration.components
        return Double(value.seconds) * 1_000 + Double(value.attoseconds) / 1e15
    }

    private func emit(_ name: String, fixture: Int, values: [Double], bytes: Int = 0) {
        let ordered = values.sorted()
        let median = ordered[ordered.count / 2]
        let p95 = ordered[min(ordered.count - 1, Int(ceil(Double(ordered.count) * 0.95)) - 1)]
        print(String(format: "PERF|%@|%d|%d|%.3f|%.3f|%.3f|%.3f|%d", name, fixture, values.count,
                     median, p95, ordered.first!, ordered.last!, bytes))
    }

    private func timed(_ name: String, fixture: Int, samples: Int = 5, bytes: Int = 0,
                       _ operation: () throws -> Void) rethrows {
        try operation() // Untimed warm-up; fixture construction is always outside the sample.
        var values: [Double] = []
        for _ in 0..<samples {
            let start = ContinuousClock.now
            try operation()
            values.append(milliseconds(start.duration(to: .now)))
        }
        emit(name, fixture: fixture, values: values, bytes: bytes)
    }

    private func fixtures(_ count: Int, artwork: ArtworkCollection = ArtworkCollection()) throws -> [AudioFile] {
        try (0..<count).map { index in
            var fields: [String: [String]] = [
                "title": ["Track \(index)"], "artist": ["Artist \(index % 100)"],
                "albumartist": ["Artist \((index / 10) % 100)"], "album": ["Album \(index / 10)"],
                "genre": [index == count - 1 ? "Needle" : "Pop"],
                "tracknumber": [String(index % 10 + 1)], "discnumber": ["1"], "totaldiscs": ["1"]
            ]
            for tag in 0..<12 { fields["custom\(tag)"] = ["Value \(tag)"] }
            var file = AudioFile(url: URL(fileURLWithPath: "/tmp/macpicard-perf-fixture-\(index).flac"))
            try file.beginLoading()
            try file.finishLoading(metadata: Metadata(fields: fields), artwork: artwork,
                                   identity: AudioFileIdentity(resourceIdentifier: nil, byteCount: 1,
                                                               modificationDate: nil, prefixHash: "fixture"),
                                   durationInMilliseconds: 180_000)
            return file
        }
    }

    func testBrowserAndInspector() throws {
        try requireOptIn()
        for count in [1_000, 10_000, 50_000] {
            let model = AppModel()
            model.files = try fixtures(count)
            defer { model.sessionSaveTask?.cancel(); model.searchTask?.cancel() }
            model.selectionChanged([model.files[0].id])
            var revision = 0
            timed("edit.genre.one", fixture: count) {
                revision += 1
                model.setTagValues(["Genre \(revision)"], for: "genre")
                model.sessionSaveTask?.cancel()
            }
            timed("edit.title.one", fixture: count, samples: 3) {
                revision += 1
                model.setTagValues(["Renamed \(revision)"], for: "title")
                model.sessionSaveTask?.cancel()
            }
            timed("publish.identical.files", fixture: count) { model.files = model.files }
            timed("table.projection.number", fixture: count) {
                XCTAssertEqual(model.collectionProjection(sortOrder: [KeyPathComparator(\CollectionTrack.number)]).rows.count, count)
            }
            timed("table.projection.number.cold", fixture: count, samples: 3) {
                model.browserDerivedCache.projectionKey = nil
                model.browserDerivedCache.visibleKey = nil
                XCTAssertEqual(model.collectionProjection(sortOrder: [KeyPathComparator(\CollectionTrack.number)]).rows.count, count)
            }
            timed("table.projection.after.title.edit", fixture: count, samples: 3) {
                revision += 1
                model.setTagValues(["Projection edit \(revision)"], for: "title")
                XCTAssertEqual(model.collectionProjection(sortOrder: [KeyPathComparator(\CollectionTrack.number)]).rows.count, count)
                model.sessionSaveTask?.cancel()
            }
            model.searchQuery = "Needle"
            timed("search.indexed.one.token", fixture: count) { model.applyBrowserSearch() }
            XCTAssertEqual(model.visibleFiles.count, 1)
            model.searchTask?.cancel()
        }
        let model = AppModel()
        model.files = try fixtures(10_000)
        defer { model.sessionSaveTask?.cancel(); model.searchTask?.cancel() }
        for count in [100, 1_000, 10_000] {
            model.selectionChanged(Set(model.files.prefix(count).map(\.id)))
            timed("inspector.metadata.rows.20.tags", fixture: count, samples: 3) {
                XCTAssertEqual(model.metadataRows.count, 20)
            }
            timed("inspector.metadata.rows.20.tags.cold", fixture: count, samples: 3) {
                model.browserDerivedCache.metadataRevision = nil
                model.browserDerivedCache.selectionRevision = nil
                XCTAssertEqual(model.metadataRows.count, 20)
            }
        }
    }

    func testScriptsAndPlanning() async throws {
        try requireOptIn()
        let evaluator = ScriptEvaluator()
        for count in [256, 512, 1_024, 2_048, 4_096] {
            let source = String(repeating: "%title%|", count: count)
            try timed("script.compile.repeated.variables", fixture: count) {
                XCTAssertEqual(try evaluator.compile(source).nodes.count, count * 2)
            }
        }
        let files = try fixtures(1_000)
        let contexts = files.map { ScriptContext(metadata: $0.metadata, variables: ["extension": ["flac"]]) }
        let source = LibraryImporter.defaultNamingScript
        let compiled = try evaluator.compile(source)
        try timed("script.batch.source", fixture: files.count, samples: 3) {
            for context in contexts { XCTAssertFalse(try evaluator.evaluate(source, context: context).output.isEmpty) }
        }
        try timed("script.batch.compiled", fixture: files.count, samples: 3) {
            for context in contexts { XCTAssertFalse(try evaluator.evaluate(compiled, context: context).output.isEmpty) }
        }
        let organizer = FileOrganizationCoordinator()
        var values: [Double] = []
        for _ in 0..<4 {
            let start = ContinuousClock.now
            let plan = try await organizer.plan(files: files, destinationDirectory: URL(fileURLWithPath: "/tmp/macpicard-perf-dest"), namingScript: source)
            let elapsed = milliseconds(start.duration(to: .now))
            XCTAssertEqual(plan.operations.count, files.count)
            values.append(elapsed)
        }
        emit("organization.plan.default.script", fixture: files.count, values: Array(values.dropFirst()))
    }

    func testPersistence() async throws {
        try requireOptIn()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacPicardPerf-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for count in [50, 100, 200] {
            let files = try fixtures(count)
            var totalBytes = 0
            try timed("journal.batch.two.checkpoints.per.file", fixture: count, samples: 3) {
                var journal = FileOperationRecord(workspaceID: UUID(), kind: .save, items: files.map { FileOperationItem(file: $0) })
                let journalURL = root.appendingPathComponent(journal.id.uuidString).appendingPathExtension("json")
                var bytes = 0
                for index in journal.items.indices {
                    journal.items[index].state = .inProgress
                    bytes += try journal.persist(to: journalURL, changedItemIDs: [journal.items[index].id])
                    journal.items[index].state = .completed
                    journal.items[index].result = files[index]
                    bytes += try journal.persist(to: journalURL, changedItemIDs: [journal.items[index].id])
                }
                totalBytes = bytes
            }
            print("PERF_BYTES|journal.batch.two.checkpoints.per.file|\(count)|\(totalBytes)")
        }
        let cover = Artwork(mimeType: "application/octet-stream", source: .generated,
                            data: Data(repeating: 0x5A, count: 256 * 1024))
        for (count, art) in [(1_000, false), (10_000, false), (10, true), (50, true)] {
            let files = try fixtures(count, artwork: art ? ArtworkCollection(images: [cover]) : ArtworkCollection())
            let document = SessionDocument(files: files.map { $0.sessionRecord() })
            let primary = root.appendingPathComponent("session-\(count)-\(art).json")
            let store = SessionStore(sessionURL: primary, recoveryURL: root.appendingPathComponent("recovery.json"))
            try await store.save(document)
            let bytes = (try primary.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            var unchanged: [Double] = [], changed: [Double] = [], loads: [Double] = []
            for index in 0..<5 {
                try await store.save(document)
                let start = ContinuousClock.now
                try await store.save(document)
                unchanged.append(milliseconds(start.duration(to: .now)))
                var modified = document
                modified.selectedAlbumKey = "selection-\(index)"
                let changeStart = ContinuousClock.now
                try await store.save(modified)
                changed.append(milliseconds(changeStart.duration(to: .now)))
                let loadStart = ContinuousClock.now
                let loaded = try await store.load()
                loads.append(milliseconds(loadStart.duration(to: .now)))
                XCTAssertEqual(loaded?.files.count, count)
            }
            let suffix = art ? ".256KiB.cover" : ".metadata.only"
            emit("session.save.unchanged" + suffix, fixture: count, values: unchanged, bytes: bytes)
            emit("session.save.selection.change" + suffix, fixture: count, values: changed, bytes: bytes)
            emit("session.load" + suffix, fixture: count, values: loads, bytes: bytes)
            let blobBytes = art ? (try root.appendingPathComponent("ArtworkBlobs").appendingPathComponent(cover.contentHash!)
                .resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) : 0
            let navigationBytes = try primary.appendingPathExtension("navigation").resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            print("PERF_STORAGE|session" + suffix + "|\(count)|\(bytes)|\(blobBytes)|\(navigationBytes)")
        }
    }

    func testTrackMatchingAndThumbnails() async throws {
        try requireOptIn()
        let original = Artwork(mimeType: "application/octet-stream", source: .generated, data: Data([1, 2, 3]))
        let originalHash = original.contentHash
        var edited = original
        edited.data = Data([4, 5, 6])
        _ = edited.contentHash
        print("PERF_NOTE|artwork.copy.hash_preserves_original|\(original.contentHash == originalHash)")
        for count in [32, 64, 128, 256, 512] {
            let locals = (0..<count).map { LocalTrackCandidate(title: "Song \($0)", artist: "Artist", durationInMilliseconds: 180_000 + $0 * 1_000, trackNumber: $0 + 1) }
            let remotes = (0..<count).map { MusicBrainzTrack(id: "track-\($0)", recordingID: nil, title: "Song \($0)", artistCredit: "Artist", lengthInMilliseconds: 180_000 + $0 * 1_000, number: String($0 + 1), position: $0 + 1, isrcs: []) }
            timed("matcher.album.square", fixture: count) {
                let matches = TrackMatcher().match(localTracks: locals, releaseTracks: remotes)
                XCTAssertEqual(matches.count, count)
                XCTAssertEqual(Set(matches.compactMap(\.releaseTrackID)).count, count)
            }
        }
        let pixels = Data(repeating: 0x7F, count: 1_600 * 1_600 * 4)
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        let image = try XCTUnwrap(CGImage(width: 1_600, height: 1_600, bitsPerComponent: 8, bitsPerPixel: 32,
                                         bytesPerRow: 1_600 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
        let png = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        for size in [68, 600] {
            try timed("thumbnail.resize.png", fixture: size, samples: 7) {
                let output = try ArtworkProcessor.resize(png as Data, maximumPixelSize: size, format: .png)
                XCTAssertFalse(output.isEmpty)
            }
            let artwork = Artwork(mimeType: "image/png", source: .generated, data: png as Data)
            let cache = ArtworkThumbnailCache()
            var cold: [Double] = [], warm: [Double] = []
            for _ in 0..<7 {
                let coldCache = ArtworkThumbnailCache()
                let start = ContinuousClock.now
                _ = try await coldCache.thumbnail(artwork, pixels: size)
                cold.append(milliseconds(start.duration(to: .now)))
                let warmStart = ContinuousClock.now
                _ = try await cache.thumbnail(artwork, pixels: size)
                warm.append(milliseconds(warmStart.duration(to: .now)))
            }
            emit("thumbnail.direct.cold", fixture: size, values: cold)
            emit("thumbnail.direct.cached", fixture: size, values: Array(warm.dropFirst()))
        }
    }
}
