import Foundation
import XCTest
@testable import PicardFoundation

final class PreferencesTests: XCTestCase {
    func testLegacyAndPartialPreferencesMigrateWithDefaultsAndKeepUnknownKeys() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("configuration.json")
        try Data(#"{"schemaVersion":1,"futureOption":"retained","editing":{"matchThreshold":0.9,"futureNested":123}}"#.utf8).write(to: url)
        let store = ConfigurationStore(fileURL: url)
        var config = try await store.load()
        XCTAssertEqual(config.schemaVersion, 2)
        XCTAssertEqual(config.editing.matchThreshold, 0.9)
        XCTAssertEqual(config.editing.coverArtSize, "1200")
        XCTAssertEqual(config.editing.artworkMaximumPixels, 1200)
        XCTAssertEqual(config.editing.artworkOutputFormat, "preserve")
        XCTAssertEqual(config.editing.artworkJPEGQuality, 0.92)
        XCTAssertTrue(config.editing.embedImportedArtwork)
        config.editing.preservedTags = ["genre", "rating"]
        config.editing.artworkMaximumPixels = 800
        config.editing.artworkOutputFormat = "png"
        config.editing.artworkJPEGQuality = 0.85
        config.editing.embedImportedArtwork = false
        try await store.save(config)
        let reloaded = try await ConfigurationStore(fileURL: url).load()
        XCTAssertEqual(reloaded, config)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(object["futureOption"] as? String, "retained")
        XCTAssertEqual((object["editing"] as? [String: Any])?["futureNested"] as? Int, 123)
    }

    func testInvalidPreferencesLeavePersistedConfigurationUntouched() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("configuration.json")
        let store = ConfigurationStore(fileURL: url)
        var config = try await store.load()
        let before = try Data(contentsOf: url)
        config.editing.matchThreshold = .nan
        do { try await store.save(config); XCTFail("Expected validation failure") } catch { }
        XCTAssertEqual(try Data(contentsOf: url), before)
        config = AppConfiguration(); config.preferredReleaseCountry = "bad"
        XCTAssertThrowsError(try config.validate())
        config = AppConfiguration(); config.editing.artworkMaximumPixels = 0
        XCTAssertThrowsError(try config.validate())
        config = AppConfiguration(); config.editing.artworkOutputFormat = "unsupported"
        XCTAssertThrowsError(try config.validate())
        config = AppConfiguration(); config.editing.artworkJPEGQuality = .nan
        XCTAssertThrowsError(try config.validate())
        config.editing.artworkJPEGQuality = 1.1
        XCTAssertThrowsError(try config.validate())
    }
}
