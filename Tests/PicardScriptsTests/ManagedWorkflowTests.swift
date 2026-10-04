import Foundation
import PicardFoundation
import XCTest
@testable import PicardScripts

final class ManagedWorkflowTests: XCTestCase {
    func testFilenameParsingUnicodePathsMappingsAndNumberNormalization() throws {
        let parser = try FilenameTagParser(pattern: "{artist}/{album}/{track} - {title}")
        let url = URL(fileURLWithPath: "/Music/Björk/Debut/03 - Venus as a Boy.flac")
        XCTAssertEqual(parser.sample(for: url), "Björk/Debut/03 - Venus as a Boy")
        let mapping = parser.tokens.map { FilenameFieldMapping(token: $0, tag: $0 == "track" ? "tracknumber" : $0) }
        let metadata = try parser.metadata(for: url, original: Metadata(fields: ["genre": ["Pop", "Electronic"]]), mappings: mapping)
        XCTAssertEqual(metadata.firstValue(for: "artist"), "Björk")
        XCTAssertEqual(metadata.firstValue(for: "title"), "Venus as a Boy")
        XCTAssertEqual(metadata.firstValue(for: "tracknumber"), "3")
        XCTAssertEqual(metadata.values(for: "genre"), ["Pop", "Electronic"])
    }
    func testAmbiguityInvalidPatternsAndMappingsNeverGuess() throws {
        XCTAssertThrowsError(try ScriptParser().parse(String(repeating: "$upper(", count: 1000) + "x" + String(repeating: ")", count: 1000)))
        XCTAssertThrowsError(try ScriptParser().parse(String(repeating: "x", count: 64 * 1024 + 1)))
        let parser = try FilenameTagParser(pattern: "{artist} - {title}")
        XCTAssertEqual(parser.parse("Artist - Song - Remix"), .ambiguous)
        XCTAssertEqual(parser.parse("No separator"), .unmatched)
        for pattern in ["{a}{b}", "{a} - {a}", "{broken", "../{a}", "literal"] { XCTAssertThrowsError(try FilenameTagParser(pattern: pattern), pattern) }
        XCTAssertThrowsError(try parser.metadata(for: URL(fileURLWithPath: "/Artist - Title.mp3"), original: Metadata(), mappings: [FilenameFieldMapping(token: "artist", tag: "title"), FilenameFieldMapping(token: "title", tag: " TITLE ")]))
        XCTAssertThrowsError(try parser.metadata(for: URL(fileURLWithPath: "/Artist - Title.mp3"), original: Metadata(), mappings: [FilenameFieldMapping(token: "artist", tag: " ~length")]))
        let track = try FilenameTagParser(pattern: "{track} - {title}")
        XCTAssertThrowsError(try track.metadata(for: URL(fileURLWithPath: "/zero - Song.mp3"), original: Metadata(), mappings: [FilenameFieldMapping(token: "track", tag: "tracknumber")]))
    }
    func testScopedProfileChangesOnlyIncludedPreferencesAndExportsWhitelist() throws {
        var source = AppConfiguration(); source.preferredReleaseCountry = "GB"; source.editing.matchThreshold = 0.9
        source.editing.appearance = "dark"; source.autosaveIntervalSeconds = 40; source.editing.fpcalcPath = "/private/tool"
        let profile = WorkflowProfile(name: "British releases", included: [.matching], configuration: source)
        var current = AppConfiguration(); current.editing.appearance = "light"; current.autosaveIntervalSeconds = 70
        let updated = try profile.applying(to: current)
        XCTAssertEqual(updated.preferredReleaseCountry, "GB"); XCTAssertEqual(updated.editing.matchThreshold, 0.9)
        XCTAssertEqual(updated.editing.appearance, "light"); XCTAssertEqual(updated.autosaveIntervalSeconds, 70)
        XCTAssertEqual(updated.editing.namingPattern, current.editing.namingPattern)
        var document = WorkflowDocument(); document.profiles = [profile]
        let text = String(decoding: try document.exported(), as: UTF8.self)
        for excluded in ["fpcalcPath", "/private/tool", "requestUserAgent", "bookmark", "appearance", "autosaveInterval"] { XCTAssertFalse(text.contains(excluded)) }
        XCTAssertEqual(try WorkflowDocument.imported(document.exported()), document)
    }
    func testOrderedScriptsDocumentMergeValidationAndAtomicStore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Workflows-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.json"), store = WorkflowStore(url: url)
        var value = WorkflowDocument()
        value.scripts = [ManagedScript(name: "Trim", source: "$set(title,$trim(%title%))"), ManagedScript(name: "Disabled", enabled: false, source: "$set(artist,Ignore)")]
        try await store.save(value)
        let loaded = try await store.load(); XCTAssertEqual(loaded, value)
        let original = try Data(contentsOf: url)
        var invalid = value; invalid.scripts[0].source = "$set(title,broken"
        do { try await store.save(invalid); XCTFail("Invalid script persisted") } catch {}
        XCTAssertEqual(try Data(contentsOf: url), original)
        try value.merge(loaded); XCTAssertEqual(value.scripts.count, 4); XCTAssertEqual(Set(value.scripts.map(\.id)).count, 4)
        var future = value; future.schemaVersion = 10; XCTAssertThrowsError(try future.exported())
        var duplicate = value; duplicate.scripts.append(duplicate.scripts[0]); XCTAssertThrowsError(try duplicate.validate())
        XCTAssertThrowsError(try WorkflowDocument.imported(Data(repeating: 0, count: 2 * 1024 * 1024 + 1)))
        try Data("broken".utf8).write(to: url)
        do { _ = try await store.load(); XCTFail("Corruption silently replaced") } catch {}
        XCTAssertEqual(try Data(contentsOf: url), Data("broken".utf8))
    }
}
