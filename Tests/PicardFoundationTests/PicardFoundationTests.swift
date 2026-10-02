import Foundation
import XCTest
@testable import PicardFoundation

final class PicardFoundationTests: XCTestCase {
    func testAppPathsPrepareCreatesFoundationDirectories() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(applicationSupportDirectory: root.appendingPathComponent("MacPicard"))
        try paths.prepare()

        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.applicationSupportDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.cacheDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.logsDirectory.path))
    }

    func testConfigurationStoreCreatesAndReloadsDefaults() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("configuration.json")
        let store = ConfigurationStore(fileURL: fileURL)

        let configuration = try await store.load()
        XCTAssertEqual(configuration, AppConfiguration())
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        let reloadedStore = ConfigurationStore(fileURL: fileURL)
        let reloaded = try await reloadedStore.load()
        XCTAssertEqual(reloaded, configuration)
    }

    func testConfigurationMigrationAddsSchemaVersion() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("configuration.json")
        let legacyData = Data(#"{"preferredReleaseCountry":"GB"}"#.utf8)
        try legacyData.write(to: fileURL)

        let store = ConfigurationStore(fileURL: fileURL)
        let configuration = try await store.load()

        XCTAssertEqual(configuration.schemaVersion, AppConfiguration.currentSchemaVersion)
        XCTAssertEqual(configuration.preferredReleaseCountry, "GB")

        let migratedData = try Data(contentsOf: fileURL)
        let migratedObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: migratedData) as? [String: Any]
        )
        XCTAssertEqual(migratedObject["schemaVersion"] as? Int, AppConfiguration.currentSchemaVersion)
    }

    func testConfigurationUpdatePersistsChanges() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ConfigurationStore(fileURL: root.appendingPathComponent("configuration.json"))
        let updated = try await store.update {
            $0.preferredReleaseCountry = "DE"
            $0.autosaveIntervalSeconds = 90
        }

        XCTAssertEqual(updated.preferredReleaseCountry, "DE")
        XCTAssertEqual(updated.autosaveIntervalSeconds, 90)
    }

    func testKeychainRoundTrip() async throws {
        let service = "com.interlacedpixel.MacPicard.tests.\(UUID().uuidString)"
        let account = "test-account"
        let store = KeychainStore(service: service)
        let value = Data("phase-one-secret".utf8)

        try await store.set(value, for: account)
        let storedValue = try await store.data(for: account)
        XCTAssertEqual(storedValue, value)
        try await store.remove(account: account)
        let removedValue = try await store.data(for: account)
        XCTAssertNil(removedValue)
    }

    func testRuntimeStartsAndProducesDiagnostics() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(applicationSupportDirectory: root.appendingPathComponent("MacPicard"))
        let runtime = PicardRuntime(paths: paths)
        let snapshot = try await runtime.start()

        XCTAssertEqual(snapshot.configuration.schemaVersion, AppConfiguration.currentSchemaVersion)
        XCTAssertFalse(snapshot.diagnostics.operatingSystem.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.configurationFile.path))
    }

    func testMetadataTracksValuesDeletionsAndDiffs() throws {
        var original = Metadata()
        original.setValue("Example Album", for: "ALBUM")
        original.setValues(["Artist One", "Artist Two"], for: "artist")

        var current = original
        current.setValue("Renamed Album", for: "album")
        current.delete("artist")
        current.setValue("2026", for: "date")

        let diff = current.difference(from: original)
        XCTAssertEqual(diff.changedKeys, ["album", "artist", "date"])
        XCTAssertTrue(current.isDeleted("artist"))

        let applied = original.applying(diff)
        XCTAssertEqual(applied, current)
    }

    func testAudioFileStateAndSessionRecordPreserveUnsavedChanges() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("example.mp3")
        FileManager.default.createFile(atPath: fileURL.path, contents: Data("audio".utf8))
        let identity = try AudioFileIdentity.capture(url: fileURL)

        var file = AudioFile(url: fileURL)
        try file.beginLoading()

        var loadedMetadata = Metadata()
        loadedMetadata.setValue("Original", for: "title")
        try file.finishLoading(metadata: loadedMetadata, identity: identity)

        var changedMetadata = loadedMetadata
        changedMetadata.setValue("Edited", for: "title")
        try file.updateMetadata(changedMetadata)

        XCTAssertEqual(file.state, .changed)
        XCTAssertTrue(file.isModified)

        let restored = AudioFile.restore(from: file.sessionRecord())
        XCTAssertEqual(restored.metadata.firstValue(for: "title"), "Edited")
        XCTAssertEqual(restored.originalMetadata.firstValue(for: "title"), "Original")
        XCTAssertEqual(restored.state, .changed)
    }

    func testSessionStoreRoundTripAndRecovery() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionStore = SessionStore(
            sessionURL: root.appendingPathComponent("session.json"),
            recoveryURL: root.appendingPathComponent("session-recovery.json")
        )
        let document = SessionDocument(selectedFileIDs: [UUID()])

        let missingDocument = try await sessionStore.load()
        XCTAssertNil(missingDocument)
        try await sessionStore.save(document)
        try await sessionStore.saveRecovery(document)

        let loadedDocument = try await sessionStore.load()
        let loadedRecoveryDocument = try await sessionStore.loadRecovery()
        XCTAssertEqual(loadedDocument, document)
        XCTAssertEqual(loadedRecoveryDocument, document)

        try await sessionStore.removeRecovery()
        let removedRecoveryDocument = try await sessionStore.loadRecovery()
        XCTAssertNil(removedRecoveryDocument)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacPicardTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
