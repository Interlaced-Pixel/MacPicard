import Foundation
import PicardFormats
import PicardFoundation
import XCTest
@testable import PicardSessions

final class PersistenceTests: XCTestCase {
    func testOrganizationPlansAndExecutesScriptedMoves() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("song.mp3")
        try Data("audio".utf8).write(to: source)
        let destination = root.appendingPathComponent("Library", isDirectory: true)
        let file = AudioFile(url: source)
        let secondSource = root.appendingPathComponent("second.mp3")
        try Data("audio".utf8).write(to: secondSource)

        let coordinator = FileOrganizationCoordinator()
        let plan = try await coordinator.plan(
            files: [file],
            destinationDirectory: destination,
            namingScript: "Renamed - %filename%"
        )
        let report = try await coordinator.execute(plan)
        let organized = try await coordinator.organize(
            files: [AudioFile(url: secondSource)],
            destinationDirectory: destination,
            namingScript: "%filename%",
            collisionPolicy: .fail
        )

        XCTAssertEqual(report.movedFileIDs, [file.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Renamed - song.mp3").path))
        XCTAssertTrue(organized[0].url.path.hasSuffix("second.mp3"))
    }

    func testAtomicSavePreservesMetadataAndModificationDate() async throws {
        guard let source = try makeAudioFixture() else {
            throw XCTSkip("ffmpeg could not create a FLAC fixture")
        }
        defer { try? FileManager.default.removeItem(at: source) }

        let engine = FormatEngine()
        let before = try source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let result = try await engine.writeAtomically(
            url: source,
            metadata: Metadata(fields: ["title": ["Atomic Title"]]),
            artwork: ArtworkCollection(),
            options: FormatSaveOptions(preserveModificationDate: true)
        )
        let reopened = try await engine.read(url: source)

        XCTAssertEqual(result.format, .flac)
        XCTAssertEqual(reopened.metadata.firstValue(for: "title"), "Atomic Title")
        XCTAssertEqual(try source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, before)
    }

    func testAudioSaveCoordinatorRejectsExternalModification() async throws {
        guard let source = try makeAudioFixture() else {
            throw XCTSkip("ffmpeg could not create a FLAC fixture")
        }
        defer { try? FileManager.default.removeItem(at: source) }

        let fileCoordinator = AudioFileCoordinator()
        var file = try await fileCoordinator.load(url: source)
        var metadata = file.metadata
        metadata.setValue("Edited", for: "title")
        try file.updateMetadata(metadata)
        var externalContents = try Data(contentsOf: source)
        externalContents[0] ^= 0xFF
        try externalContents.write(to: source, options: [.atomic])

        do {
            _ = try await AudioSaveCoordinator().save(file)
            XCTFail("Expected external modification error")
        } catch let error as SaveError {
            guard case .externalModification = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testMoveCollisionCanFailOrSkipWithoutDeletingTheExistingFile() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("song.mp3")
        let destinationDirectory = root.appendingPathComponent("Library", isDirectory: true)
        let existing = destinationDirectory.appendingPathComponent("song.mp3")
        try Data("source".utf8).write(to: source)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        try Data("existing".utf8).write(to: existing)
        let file = AudioFile(url: source)
        let coordinator = FileOrganizationCoordinator()
        let plan = try await coordinator.plan(files: [file], destinationDirectory: destinationDirectory, namingScript: "%filename%")

        do {
            _ = try await coordinator.execute(plan, collisionPolicy: .fail)
            XCTFail("Expected collision error")
        } catch let error as SaveError {
            guard case .collision = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let report = try await coordinator.execute(plan, collisionPolicy: .skip)
        XCTAssertEqual(report.skippedFileIDs, [file.id])
        XCTAssertEqual(String(decoding: try Data(contentsOf: existing), as: UTF8.self), "existing")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testProfileStoreExportsNonSecretProfileAndMigrates() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProfileStore(directory: directory)
        let profile = PicardProfile(name: "Main", namingScript: "%artist%/%title%", customVariables: ["label": ["Example"]])

        try await store.save(profile)
        let exported = try await store.export(profile)
        let imported = try await store.import(exported)
        let profiles = try await store.list()
        let legacy = try await store.import(Data(#"{"name":"Legacy"}"#.utf8))

        XCTAssertEqual(imported.name, "Main")
        XCTAssertEqual(imported.customVariables["label"], ["Example"])
        XCTAssertEqual(legacy.name, "Legacy")
        XCTAssertEqual(profiles.count, 1)
        XCTAssertFalse(String(decoding: exported, as: UTF8.self).localizedCaseInsensitiveContains("password"))
    }

    func testSessionManagerPrefersNewerRecoveryAndAcceptsIt() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(
            sessionURL: directory.appendingPathComponent("session.json"),
            recoveryURL: directory.appendingPathComponent("recovery.json")
        )
        let manager = SessionManager(store: store)
        let primary = SessionDocument(
            createdAt: Date(timeIntervalSince1970: 10),
            savedAt: Date(timeIntervalSince1970: 100)
        )
        let recovery = SessionDocument(
            createdAt: Date(timeIntervalSince1970: 20),
            savedAt: Date(timeIntervalSince1970: 200)
        )

        try await manager.save(primary)
        try await manager.saveRecovery(recovery)
        let loaded = try await manager.loadBestAvailable()
        try await manager.acceptRecovery()
        let accepted = try await store.load()
        let remainingRecovery = try await store.loadRecovery()

        XCTAssertEqual(loaded?.source, .recovery)
        XCTAssertEqual(accepted, recovery)
        XCTAssertNil(remainingRecovery)
    }

    func testAutosaveWritesRecoveryDocument() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(
            sessionURL: directory.appendingPathComponent("session.json"),
            recoveryURL: directory.appendingPathComponent("recovery.json")
        )
        let autosave = SessionAutosave(store: store)
        let document = SessionDocument(
            createdAt: Date(timeIntervalSince1970: 400),
            savedAt: Date(timeIntervalSince1970: 500)
        )

        try await autosave.start(interval: .milliseconds(20)) { document }
        try await Task.sleep(for: .milliseconds(80))
        await autosave.stop()

        let recovery = try await store.loadRecovery()
        XCTAssertEqual(recovery, document)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeAudioFixture() throws -> URL? {
        let lookup = Process()
        lookup.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        lookup.arguments = ["which", "ffmpeg"]
        let output = Pipe()
        lookup.standardOutput = output
        lookup.standardError = Pipe()
        try lookup.run()
        lookup.waitUntilExit()
        guard lookup.terminationStatus == 0 else { return nil }
        let ffmpeg = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacPicard-\(UUID().uuidString).flac")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono", "-t", "1", "-c:a", "flac", url.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? url : nil
    }
}
