import Foundation
import PicardFormats
import PicardFoundation
import XCTest
@testable import PicardSessions

final class OrganizationReviewTests: XCTestCase {
    func testPreviewIsReadOnlyAndNormalizesTrackDiscAndUnsafeTags() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = try folder("Library", in: root)
        let file = try audio("source.mp3", in: root, tags: ["artist": ["A/B"], "album": ["Album:C"], "title": ["Title/Part"], "tracknumber": ["3/12"], "discnumber": ["2/2"]])
        let before = try Data(contentsOf: file.url)
        let review = try await FileOrganizationCoordinator().preview(files: [file], directory: destination, namingScript: LibraryImporter.defaultNamingScript)
        XCTAssertEqual(review.moveCount, 1)
        XCTAssertEqual(review.rows[0].destination?.path, destination.appendingPathComponent("A_B/Album_C/2-03 - Title_Part.mp3").path)
        XCTAssertEqual(try Data(contentsOf: file.url), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
        XCTAssertEqual(review.files[0].metadata, file.metadata)
    }

    func testMissingTagsFallBackToFilenameAndUnknownFolders() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = try folder("Library", in: root)
        let file = try audio("untagged.flac", in: root, tags: [:])
        let review = try await FileOrganizationCoordinator().preview(files: [file], directory: destination, namingScript: LibraryImporter.defaultNamingScript)
        XCTAssertEqual(review.rows[0].destination?.path, destination.appendingPathComponent("Unknown Artist/Unknown Album/untagged.flac").path)
    }

    func testAlreadyOrganizedFilesHaveNoExecutableMoves() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try audio("same.mp3", in: root)
        let review = try await FileOrganizationCoordinator().preview(files: [file], directory: root, namingScript: "%filename%")
        XCTAssertEqual(review.rows[0].status, .unchanged)
        XCTAssertFalse(review.canExecute)
    }

    func testDuplicateTargetsStopSkipOrReceiveDistinctSuffixes() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = try folder("Library", in: root)
        let first = try audio("first.mp3", in: root), second = try audio("second.mp3", in: root)
        let mover = FileOrganizationCoordinator()
        let stopped = try await mover.preview(files: [first, second], directory: destination, namingScript: "Same")
        XCTAssertEqual(stopped.blockedCount, 2); XCTAssertFalse(stopped.canExecute)
        let skipped = try await mover.preview(files: [first, second], directory: destination, namingScript: "Same", policy: .skip)
        XCTAssertTrue(skipped.rows.allSatisfy { $0.status == .skipped })
        let numbered = try await mover.preview(files: [first, second], directory: destination, namingScript: "Same", policy: .numbered)
        XCTAssertEqual(numbered.rows.compactMap { $0.destination?.lastPathComponent }, ["Same.mp3", "Same (2).mp3"])
        let result = try await mover.executeReview(numbered)
        XCTAssertEqual(result.report.movedFileIDs.count, 2)
        XCTAssertEqual(try Data(contentsOf: result.files[0].url), Data("first.mp3".utf8))
        XCTAssertEqual(try Data(contentsOf: result.files[1].url), Data("second.mp3".utf8))
    }

    func testExistingConflictPoliciesNeverOverwriteAndSkipOnlyAffectedFile() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = try folder("Library", in: root)
        let first = try audio("first.mp3", in: root), second = try audio("second.mp3", in: root)
        let occupied = destination.appendingPathComponent("first.mp3")
        try Data("existing".utf8).write(to: occupied)
        let mover = FileOrganizationCoordinator()
        let stopped = try await mover.preview(files: [first, second], directory: destination, namingScript: "%filename%")
        XCTAssertEqual(stopped.blockedCount, 1)
        let numbered = try await mover.preview(files: [first], directory: destination, namingScript: "%filename%", policy: .numbered)
        XCTAssertEqual(numbered.rows[0].destination?.lastPathComponent, "first (2).mp3")
        let skipped = try await mover.preview(files: [first, second], directory: destination, namingScript: "%filename%", policy: .skip)
        let result = try await mover.executeReview(skipped)
        XCTAssertEqual(result.report.movedFileIDs, [second.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.url.path))
        XCTAssertEqual(try Data(contentsOf: occupied), Data("existing".utf8))
    }

    func testExcludedFilesStayUntouchedAndCanResolveDuplicateTargets() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = try folder("Library", in: root)
        let first = try audio("first.mp3", in: root), second = try audio("second.mp3", in: root)
        let mover = FileOrganizationCoordinator()
        let review = try await mover.preview(files: [first, second], directory: destination, namingScript: "Same", excludedIDs: [second.id])
        XCTAssertEqual(review.moveCount, 1); XCTAssertEqual(review.rows[1].status, .excluded)
        let result = try await mover.executeReview(review)
        XCTAssertEqual(result.files[1], second)
        XCTAssertEqual(try Data(contentsOf: second.url), Data("second.mp3".utf8))
    }

    func testExternalChangesBlockPreviewAndAbortEntireBatchAfterPreview() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = try folder("Library", in: root)
        let first = try audio("first.mp3", in: root), second = try audio("second.mp3", in: root)
        let mover = FileOrganizationCoordinator()
        let review = try await mover.preview(files: [first, second], directory: destination, namingScript: "%filename%")
        try Data("changed externally".utf8).write(to: second.url)
        do { _ = try await mover.executeReview(review); XCTFail("Expected stale source rejection") }
        catch let error as SaveError { guard case .externalModification = error else { return XCTFail("\(error)") } }
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.url.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
        let refreshed = try await mover.preview(files: [second], directory: destination, namingScript: "%filename%")
        XCTAssertEqual(refreshed.blockedCount, 1)
    }

    func testDestinationAppearingAfterPreviewAbortsWithoutMovingSources() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = try folder("Library", in: root)
        let file = try audio("source.mp3", in: root)
        let mover = FileOrganizationCoordinator()
        let review = try await mover.preview(files: [file], directory: destination, namingScript: "%filename%")
        let occupied = try XCTUnwrap(review.rows[0].destination)
        try Data("race winner".utf8).write(to: occupied)
        do { _ = try await mover.executeReview(review); XCTFail("Expected collision") }
        catch let error as SaveError { guard case .collision = error else { return XCTFail("\(error)") } }
        XCTAssertEqual(try Data(contentsOf: occupied), Data("race winner".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
    }

    func testSymlinkEscapeAndSourceLinksAreBlocked() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = try folder("Library", in: root), outside = try folder("Outside", in: root)
        let file = try audio("source.mp3", in: root)
        try FileManager.default.createSymbolicLink(at: destination.appendingPathComponent("escape"), withDestinationURL: outside)
        let mover = FileOrganizationCoordinator()
        let escaped = try await mover.preview(files: [file], directory: destination, namingScript: "escape/%filename%")
        XCTAssertEqual(escaped.blockedCount, 1)
        let linked = root.appendingPathComponent("link.mp3")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: file.url)
        var alias = file; try alias.updateURL(linked)
        let sourceLink = try await mover.preview(files: [alias], directory: destination, namingScript: "%filename%")
        XCTAssertEqual(sourceLink.blockedCount, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

    func testReplacedDestinationFolderIsRejected() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = try folder("Library", in: root)
        let file = try audio("source.mp3", in: root), mover = FileOrganizationCoordinator()
        let review = try await mover.preview(files: [file], directory: destination, namingScript: "%filename%")
        try FileManager.default.moveItem(at: destination, to: root.appendingPathComponent("OldLibrary"))
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        do { _ = try await mover.executeReview(review); XCTFail("Expected replaced folder rejection") } catch { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
    }

    func testInvalidPatternsAndBlockedParentAreActionableRows() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = try folder("Library", in: root), file = try audio("source.mp3", in: root)
        let mover = FileOrganizationCoordinator()
        for pattern in ["../escape", "/absolute", "$unknown()", "", "WrongFormat.flac"] {
            let review = try await mover.preview(files: [file], directory: destination, namingScript: pattern)
            XCTAssertEqual(review.blockedCount, 1, pattern)
        }
        try Data([1]).write(to: destination.appendingPathComponent("blocker"))
        let blocked = try await mover.preview(files: [file], directory: destination, namingScript: "blocker/song")
        XCTAssertEqual(blocked.blockedCount, 1)
        XCTAssertTrue(blocked.rows[0].message.contains("required destination folder"))
    }

    func testDuplicateIdentifiersAndPhysicalAliasesAreRejected() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try audio("source.mp3", in: root)
        do { _ = try await FileOrganizationCoordinator().preview(files: [file, file], directory: root, namingScript: "%filename%"); XCTFail("Expected duplicate rejection") } catch { }
        let encoded = try JSONEncoder().encode(FileMoveOperation(fileID: file.id, source: file.url, destination: root.appendingPathComponent("new.mp3")))
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any]); old.removeValue(forKey: "expectedIdentity")
        let decoded = try JSONDecoder().decode(FileMoveOperation.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(decoded.expectedIdentity)
    }

    func testRollbackRestoresRenameCycleWhenLaterDestinationFails() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try audio("first.mp3", in: root), second = try audio("second.mp3", in: root), third = try audio("third.mp3", in: root)
        let blocker = root.appendingPathComponent("blocker"); try Data([1]).write(to: blocker)
        let plan = FileMovePlan(operations: [
            .init(fileID: first.id, source: first.url, destination: second.url),
            .init(fileID: second.id, source: second.url, destination: first.url),
            .init(fileID: third.id, source: third.url, destination: blocker.appendingPathComponent("third.mp3"))
        ])
        do { _ = try await FileOrganizationCoordinator().execute(plan); XCTFail("Expected failure") } catch { }
        for file in [first, second, third] { XCTAssertEqual(try Data(contentsOf: file.url), Data(file.url.lastPathComponent.utf8)) }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".macpicard-") })
    }

    func testConcurrentMovesNeverOverwriteTheWinningDestination() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = try folder("Library", in: root)
        let first = try audio("first.mp3", in: root), second = try audio("second.mp3", in: root)
        let a = FileOrganizationCoordinator(), b = FileOrganizationCoordinator()
        let firstReview = try await a.preview(files: [first], directory: destination, namingScript: "Winner")
        let secondReview = try await b.preview(files: [second], directory: destination, namingScript: "Winner")
        async let firstResult = Self.attempt(a, firstReview)
        async let secondResult = Self.attempt(b, secondReview)
        let (one, two) = await (firstResult, secondResult)
        XCTAssertNotEqual(one, two)
        let winner = one ? first : second, loser = one ? second : first
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("Winner.mp3")), Data(winner.url.lastPathComponent.utf8))
        XCTAssertEqual(try Data(contentsOf: loser.url), Data(loser.url.lastPathComponent.utf8))
    }

    func testCrossVolumeMoveRefreshesIdentityAndCanSavePendingTags() async throws {
        guard ProcessInfo.processInfo.environment["MACPICARD_CROSS_VOLUME_TEST"] == "1" else {
            throw XCTSkip("Enable MACPICARD_CROSS_VOLUME_TEST=1 to test on a temporary mounted disk image.")
        }
        let root = try temporaryDirectory()
        let image = root.appendingPathComponent("TestVolume.dmg")
        let volume = try folder("Volume", in: root)
        var mounted = false
        defer {
            if mounted {
                do { try Self.run("/usr/bin/hdiutil", ["detach", volume.path]); mounted = false }
                catch { XCTFail("Temporary test volume could not be detached: \(volume.path): \(error)") }
            }
            if !mounted { try? FileManager.default.removeItem(at: root) }
        }
        try Self.run("/usr/bin/hdiutil", ["create", "-size", "128m", "-fs", "APFS", "-volname", "MacPicardOrganizationTest", image.path])
        try Self.run("/usr/bin/hdiutil", ["attach", image.path, "-mountpoint", volume.path, "-nobrowse", "-noautoopen"])
        mounted = true
        let source = root.appendingPathComponent("source.flac")
        try Self.run("/usr/bin/env", ["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono", "-t", "1", "-c:a", "flac", "-metadata", "title=Original", source.path])
        var file = try await AudioFileCoordinator().load(url: source)
        let before = try Data(contentsOf: source)
        var tags = file.metadata; tags.setValue("Pending", for: "title"); try file.updateMetadata(tags)
        let mover = FileOrganizationCoordinator()
        let review = try await mover.preview(files: [file], directory: volume, namingScript: "%title%")
        let result = try await mover.executeReview(review)
        let relocated = try XCTUnwrap(result.files.first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: relocated.url), before)
        XCTAssertTrue(try AudioFileIdentity.capture(url: relocated.url).matches(relocated.identity))
        XCTAssertNotEqual(relocated.identity?.resourceIdentifier, file.identity?.resourceIdentifier)
        XCTAssertEqual(relocated.originalMetadata, file.originalMetadata)
        XCTAssertTrue(relocated.isModified)
        let saved = try await AudioSaveCoordinator().save(relocated)
        let reopened = try await FormatEngine().read(url: saved.url)
        XCTAssertEqual(reopened.metadata.firstValue(for: "title"), "Pending")
    }

    private static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SaveError.session("\(executable) failed: \(String(decoding: data, as: UTF8.self))")
        }
    }

    private static func attempt(_ mover: FileOrganizationCoordinator, _ review: OrganizationReview) async -> Bool {
        do { _ = try await mover.executeReview(review); return true } catch { return false }
    }
    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacPicard-organization-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func folder(_ name: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func audio(_ name: String, in root: URL, tags: [String: [String]] = ["title": ["Title"]]) throws -> AudioFile {
        let url = root.appendingPathComponent(name)
        try Data(name.utf8).write(to: url)
        var file = AudioFile(url: url)
        try file.beginLoading(); try file.finishLoading(metadata: Metadata(fields: tags), identity: AudioFileIdentity.capture(url: url))
        return file
    }
}
