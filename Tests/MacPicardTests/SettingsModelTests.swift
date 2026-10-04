import Foundation
import PicardFoundation
import XCTest
@testable import MacPicard

final class SettingsModelTests: XCTestCase {
    @MainActor
    func testPreferencesApplyPersistAndInvalidScriptKeepsPreviousSettings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = PicardRuntime(paths: AppPaths(applicationSupportDirectory: root))
        _ = try await runtime.start()
        let model = AppModel(); model.runtime = runtime
        defer { model.refreshTask?.cancel() }
        var config = AppConfiguration()
        config.autosaveEnabled = false
        config.preferredReleaseCountry = "GB"
        config.editing.matchThreshold = 0.9
        config.editing.namingPattern = "%artist%/%title%"
        config.editing.defaultTagScript = "$set(genre,Rock)"
        config.editing.fpcalcPath = "/does/not/exist/legacy-fpcalc"
        try await model.savePreferences(config)
        XCTAssertEqual(model.configuration, config)
        XCTAssertEqual(model.scriptSource, config.editing.defaultTagScript)
        XCTAssertEqual(model.organizationNamingScript, config.editing.namingPattern)
        XCTAssertEqual(model.releaseMatchPreferences.preferredCountries, ["GB"])
        let reloaded = try await ConfigurationStore(fileURL: root.appendingPathComponent("configuration.json")).load()
        XCTAssertEqual(reloaded, config)
        var invalid = config; invalid.editing.defaultTagScript = "$set("
        do { try await model.savePreferences(invalid); XCTFail("Expected script error") } catch { }
        XCTAssertEqual(model.configuration, config)
        XCTAssertFalse(model.isWorking)
    }

    func testBuiltInCalculatorInspectorNeedsNoPath() async throws {
        let version = try await FingerprintToolInspector().version()
        XCTAssertTrue(version.contains("fpcalc version 1.6.1"))
    }
}
