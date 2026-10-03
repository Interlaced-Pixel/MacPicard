import Foundation
import PicardFormats
import PicardFoundation
import XCTest
@testable import PicardSessions

final class LibraryImportTests: XCTestCase {
    func testEverySupportedFormatImportsAsAnUnchangedManagedCopy() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try directory(in: root, name: "Library")
        let formats: [(String, String, AudioFormat)] = [
            ("mp3", "libmp3lame", .mp3), ("flac", "flac", .flac), ("m4a", "aac", .mp4),
            ("ogg", "vorbis", .oggVorbis), ("opus", "libopus", .oggOpus), ("wav", "pcm_s16le", .wav)
        ]
        for (ext, codec, expected) in formats {
            let source = try fixture(in: root, extensionName: ext, codec: codec)
            let bytes = try Data(contentsOf: source)
            let result = try await LibraryImporter().importFile(at: source, into: library)
            XCTAssertTrue(result.copied, ext)
            XCTAssertEqual(try FormatRegistry().detect(url: result.file.url), expected, ext)
            XCTAssertNotNil(LibraryPaths.relativePath(of: result.file.url, in: library), ext)
            XCTAssertEqual(try Data(contentsOf: result.file.url), bytes, ext)
            XCTAssertEqual(try Data(contentsOf: source), bytes, ext)
        }
    }

    func testCopyOrganizesPreservesSourceAndSavesOnlyLibraryCopy() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root)
        let bytes = try Data(contentsOf: source)
        let identity = try AudioFileIdentity.capture(url: source)
        let library = try directory(in: root, name: "Library")
        let result = try await LibraryImporter().importFile(at: source, into: library)
        XCTAssertTrue(result.copied)
        XCTAssertEqual(LibraryPaths.relativePath(of: result.file.url, in: library), "Artist/Album/01 - Song.flac")
        XCTAssertEqual(try Data(contentsOf: result.file.url), bytes)
        XCTAssertTrue(try AudioFileIdentity.capture(url: source).matches(identity))
        XCTAssertTrue(try AudioFileIdentity.capture(url: result.file.url).matches(result.file.identity))
        var file = result.file
        var tags = file.metadata
        tags.setValue("Edited Copy", for: "title")
        try file.updateMetadata(tags)
        _ = try await AudioSaveCoordinator().save(file)
        XCTAssertEqual(try Data(contentsOf: source), bytes, "Saving the library item must never change its original.")
        let reopened = try await AudioFileCoordinator().load(url: file.url)
        XCTAssertEqual(reopened.metadata.firstValue(for: "title"), "Edited Copy")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: library.path).contains { $0.hasPrefix(".macpicard-import-") })
    }

    func testDuplicatesReuseIdentityAndPendingEditsWhileCollisionsKeepBothFiles() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root)
        let other = try fixture(in: root, name: "other", frequency: 880)
        let library = try directory(in: root, name: "Library")
        let importer = LibraryImporter()
        var first = try await importer.importFile(at: source, into: library).file
        var metadata = first.metadata
        metadata.setValue("Pending edit", for: "title")
        try first.updateMetadata(metadata)
        let repeated = try await importer.importFile(at: source, into: library, existing: [first])
        XCTAssertFalse(repeated.copied)
        XCTAssertEqual(repeated.file, first)
        let collision = try await importer.importFile(at: other, into: library, existing: [first])
        XCTAssertTrue(collision.copied)
        XCTAssertEqual(collision.file.url.lastPathComponent, "01 - Song (2).flac")
        XCTAssertEqual(try Data(contentsOf: collision.file.url), try Data(contentsOf: other))
        let repeatedCollision = try await importer.importFile(at: other, into: library, existing: [first, collision.file])
        XCTAssertFalse(repeatedCollision.copied)
        XCTAssertEqual(repeatedCollision.file.id, collision.file.id)
        XCTAssertEqual(try Data(contentsOf: first.url), try Data(contentsOf: source))
    }

    func testConcurrentImportsNeverOverwriteOrDuplicateIdenticalFiles() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root)
        let library = try directory(in: root, name: "Library")
        let results = try await withThrowingTaskGroup(of: LibraryImportResult.self) { group in
            for _ in 0..<6 { group.addTask { try await LibraryImporter().importFile(at: source, into: library) } }
            var results: [LibraryImportResult] = []
            for try await result in group { results.append(result) }
            return results
        }
        XCTAssertEqual(results.filter(\.copied).count, 1)
        XCTAssertEqual(Set(results.map { $0.file.url }).count, 1)
        let scanned = try await LibraryScanner().scan(directory: library, existing: [])
        XCTAssertEqual(scanned.files.count, 1)
        XCTAssertEqual(try Data(contentsOf: scanned.files[0].url), try Data(contentsOf: source))
    }

    func testInsideLibraryFilesAreIndexedWithoutCopiesOrMoves() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root)
        let file = try await AudioFileCoordinator().load(url: source)
        let imported = try await LibraryImporter().importFile(at: source, into: root, existing: [file])
        XCTAssertFalse(imported.copied)
        XCTAssertEqual(imported.file, file)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["input.flac"])
    }

    func testLegacyExternalReferenceBecomesManagedWithoutLosingPendingEdits() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root)
        let bytes = try Data(contentsOf: source)
        var linked = try await AudioFileCoordinator().load(url: source)
        var metadata = linked.metadata
        metadata.setValue("Pending title", for: "title")
        try linked.updateMetadata(metadata)
        let library = try directory(in: root, name: "Library")
        let result = try await LibraryImporter().importFile(at: source, into: library, existing: [linked])
        XCTAssertTrue(result.copied)
        XCTAssertEqual(result.file.id, linked.id)
        XCTAssertTrue(result.file.isModified)
        XCTAssertEqual(result.file.metadata.firstValue(for: "title"), "Pending title")
        XCTAssertTrue(try AudioFileIdentity.capture(url: result.file.url).matches(result.file.identity))
        XCTAssertEqual(try Data(contentsOf: result.file.url), bytes)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testDestinationFileSymlinkIsNotFollowedOrReplaced() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root)
        let library = try directory(in: root, name: "Library")
        let album = try directory(in: library, name: "Artist/Album")
        let link = album.appendingPathComponent("01 - Song.flac")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let result = try await LibraryImporter().importFile(at: source, into: library)
        XCTAssertTrue(result.copied)
        XCTAssertEqual(result.file.url.lastPathComponent, "01 - Song (2).flac")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), source.path)
        XCTAssertEqual(try Data(contentsOf: result.file.url), try Data(contentsOf: source))
    }

    func testMultiDiscNamesSanitizeTagsWithoutChangingEmbeddedMetadata() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root, title: "Title/Name", artist: "Various/Artists", album: "Album:Name", track: "11/12", disc: "2/2")
        let library = try directory(in: root, name: "Library")
        let result = try await LibraryImporter().importFile(at: source, into: library)
        XCTAssertEqual(LibraryPaths.relativePath(of: result.file.url, in: library), "Various_Artists/Album_Name/2-11 - Title_Name.flac")
        XCTAssertEqual(result.file.metadata.firstValue(for: "artist"), "Various/Artists")
        XCTAssertEqual(result.file.metadata.firstValue(for: "title"), "Title/Name")
        XCTAssertEqual(try Data(contentsOf: result.file.url), try Data(contentsOf: source))
    }

    func testMissingTagsUseSafeFilenameAndUnknownFolders() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root, name: ".Demo: Recording", title: "", artist: "", album: "", track: "")
        let library = try directory(in: root, name: "Library")
        let result = try await LibraryImporter().importFile(at: source, into: library)
        XCTAssertEqual(LibraryPaths.relativePath(of: result.file.url, in: library), "Unknown Artist/Unknown Album/_.Demo_ Recording.flac")
    }

    func testDottedAndLongTagsKeepTheAudioExtensionAndFitFileSystemLimits() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try directory(in: root, name: "Library")
        let dotted = try fixture(in: root, title: "Song.Part.mp3")
        let imported = try await LibraryImporter().importFile(at: dotted, into: library)
        XCTAssertEqual(imported.file.url.lastPathComponent, "01 - Song.Part.mp3.flac")
        let longTitle = String(repeating: "🟣", count: 400)
        let long = try fixture(in: root, name: "long", title: longTitle, artist: longTitle, album: longTitle)
        let bounded = try await LibraryImporter().importFile(at: long, into: library)
        XCTAssertEqual(bounded.file.url.pathExtension, "flac")
        XCTAssertLessThan(bounded.file.url.lastPathComponent.utf8.count, 255)
        XCTAssertEqual(bounded.file.metadata.firstValue(for: "title"), longTitle)
        XCTAssertEqual(try Data(contentsOf: bounded.file.url), try Data(contentsOf: long))
    }

    func testDestinationSymlinksCannotEscapeLibraryAndSourcesAreReadOnlySafe() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root)
        let library = try directory(in: root, name: "Library")
        let outside = try directory(in: root, name: "Outside")
        try FileManager.default.createSymbolicLink(at: library.appendingPathComponent("Artist"), withDestinationURL: outside)
        do { _ = try await LibraryImporter().importFile(at: source, into: library); XCTFail("Expected symlink rejection") }
        catch {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        try FileManager.default.removeItem(at: library.appendingPathComponent("Artist"))
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: source.path)
        let copy = try await LibraryImporter().importFile(at: source, into: library)
        XCTAssertTrue(FileManager.default.isWritableFile(atPath: copy.file.url.path))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: source.path)[.posixPermissions] as? NSNumber)?.intValue, 0o444)
    }

    func testUnavailableRootCorruptInputAndCancellationLeaveNoPartialCopies() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root)
        let missing = root.appendingPathComponent("Offline")
        do { _ = try await LibraryImporter().importFile(at: source, into: missing); XCTFail("Expected offline failure") }
        catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        let library = try directory(in: root, name: "Library")
        let corrupt = root.appendingPathComponent("broken.flac")
        try Data("not audio".utf8).write(to: corrupt)
        do { _ = try await LibraryImporter().importFile(at: corrupt, into: library); XCTFail("Expected corrupt audio rejection") }
        catch {}
        let cancelled = Task { try await LibraryImporter().importFile(at: source, into: library) }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: library.path).isEmpty)
    }

    func testTrashRequiresConfirmationAndNeverTouchesExternalOriginals() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root)
        let file = try await AudioFileCoordinator().load(url: source)
        let library = try directory(in: root, name: "Library")
        do { _ = try await LibraryTrashCoordinator().trash([file], in: library, confirmed: false); XCTFail("Expected consent guard") }
        catch {}
        let guarded = try await LibraryTrashCoordinator().trash([file], in: library, confirmed: true)
        XCTAssertTrue(guarded.trashedFileIDs.isEmpty)
        XCTAssertEqual(guarded.failures.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testNativeTrashMovesOnlyFixtureCopyAndIsRecoverable() async throws {
        guard ProcessInfo.processInfo.environment["MACPICARD_TRASH_INTEGRATION_TEST"] == "1" else {
            throw XCTSkip("Opt in to exercise the native Trash with an isolated generated fixture.")
        }
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root)
        let library = try directory(in: root, name: "Library")
        let copy = try await LibraryImporter().importFile(at: source, into: library).file
        let result = try await LibraryTrashCoordinator().trash([copy], in: library, confirmed: true)
        XCTAssertEqual(result.trashedFileIDs, [copy.id])
        XCTAssertTrue(result.failures.isEmpty)
        let trashed = try XCTUnwrap(result.trashLocations[copy.id])
        // Restore our exact fixture immediately so the test leaves no Trash clutter.
        defer { try? FileManager.default.moveItem(at: trashed, to: copy.url) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.url.path))
        XCTAssertEqual(try Data(contentsOf: trashed), try Data(contentsOf: source))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testTrashRejectsFilesChangedExternallySinceTheyWereLoaded() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root)
        let file = try await AudioFileCoordinator().load(url: source)
        var changed = file
        var metadata = changed.metadata
        metadata.setValue("Changed outside the current workspace", for: "title")
        try changed.updateMetadata(metadata)
        _ = try await AudioSaveCoordinator().save(changed)
        let result = try await LibraryTrashCoordinator().trash([file], in: root, confirmed: true)
        XCTAssertTrue(result.trashedFileIDs.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    private func directory(in parent: URL = FileManager.default.temporaryDirectory, name: String = "MacPicard-import-tests-\(UUID())") throws -> URL {
        let url = parent.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fixture(in root: URL, name: String = "input", title: String = "Song", artist: String = "Artist",
                         album: String = "Album", track: String = "1/12", disc: String = "1/1", frequency: Int = 440,
                         extensionName: String = "flac", codec: String = "flac") throws -> URL {
        let url = root.appendingPathComponent(name).appendingPathExtension(extensionName)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
                             "sine=frequency=\(frequency):sample_rate=44100", "-t", "0.1", "-ac", "2", "-c:a", codec, "-strict", "-2",
                             "-metadata", "title=\(title)", "-metadata", "artist=\(artist)", "-metadata", "album=\(album)",
                             "-metadata", "track=\(track)", "-metadata", "disc=\(disc)", url.path]
        process.standardOutput = Pipe(); process.standardError = Pipe()
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw XCTSkip("ffmpeg is needed for real audio fixtures") }
        return url
    }
}
