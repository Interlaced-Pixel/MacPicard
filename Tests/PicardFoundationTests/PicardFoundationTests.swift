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

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacPicardTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
