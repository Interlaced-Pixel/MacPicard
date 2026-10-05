import Foundation
import PicardFoundation
import XCTest
@testable import PicardScripts

final class ScriptEngineTests: XCTestCase {
    func testRegexCacheReusesImmutableExpressionsAndEvictsOlderPatterns() throws {
        let cache = ScriptRegexCache()
        let first = try cache.expression("a+")
        XCTAssertTrue(try cache.expression("a+") === first)
        for index in 0..<40 { _ = try cache.expression("pattern\(index)") }
        XCTAssertFalse(try cache.expression("a+") === first)
        XCTAssertThrowsError(try cache.expression("["))
    }
    func testPreparedFilenameMappingsKeepNormalizationAndPatternValidation() throws {
        let parser = try FilenameTagParser(pattern: "{track} - {title}")
        let mappings = try parser.prepareMappings([.init(token: "track", tag: " TRACKNUMBER "), .init(token: "title", tag: "Title")])
        let result = try parser.metadata(for: URL(fileURLWithPath: "/tmp/02 - Song.flac"), original: Metadata(), mappings: mappings)
        XCTAssertEqual(result.firstValue(for: "tracknumber"), "2")
        XCTAssertEqual(result.firstValue(for: "title"), "Song")
        let differentParser = try FilenameTagParser(pattern: "{artist} - {title}")
        XCTAssertThrowsError(try differentParser.metadata(for: URL(fileURLWithPath: "/tmp/Artist - Song.flac"), original: Metadata(), mappings: mappings))
    }
    func testPrecomputedLocationsPreserveUnicodeAndMultilineOffsets() {
        let prefix = "é👩‍💻\nabc\n"
        XCTAssertThrowsError(try ScriptParser().parse(prefix + "$replace(%title%,a")) { error in
            guard case let ScriptError.missingFunctionTerminator(_, location) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(location.offset, prefix.count)
            XCTAssertEqual(location.line, 3)
            XCTAssertEqual(location.column, 1)
        }
    }
    func testNestedFunctionsVariablesAndEscapes() throws {
        var metadata = Metadata()
        metadata.setValue("  Blue Öyster Cult  ", for: "artist")
        metadata.setValues(["One", "Two"], for: "genre")

        let result = try ScriptEvaluator().evaluate(
            "$upper($trim(%artist%)) - $join(%genre%, / )\\n%%",
            context: ScriptContext(metadata: metadata)
        )

        XCTAssertEqual(result.output, "BLUE ÖYSTER CULT - One / Two\n%")
    }

    func testMetadataMutationAndMultiValueOperations() throws {
        let result = try ScriptEvaluator().evaluate(
            "$set(albumartist,%artist%)$addmulti(genre,Rock,Alternative)$delete(oldtag)",
            context: ScriptContext(metadata: Metadata(fields: [
                "artist": ["Example Artist"],
                "genre": ["Rock"],
                "oldtag": ["remove me"]
            ]))
        )

        XCTAssertEqual(result.metadata.values(for: "albumartist"), ["Example Artist"])
        XCTAssertEqual(result.metadata.values(for: "genre"), ["Rock", "Alternative"])
        XCTAssertTrue(result.metadata.isDeleted("oldtag"))
    }

    func testConditionalsAndNumericFunctions() throws {
        let result = try ScriptEvaluator().evaluate(
            "$if($gt(%tracknumber%,9),$num(%tracknumber%,2),00)-$substr(%title%,0,4)",
            context: ScriptContext(metadata: Metadata(fields: [
                "tracknumber": ["12"],
                "title": ["Track Name"]
            ]))
        )

        XCTAssertEqual(result.output, "12-Trac")
    }

    func testParserReportsLocationForMalformedScripts() {
        XCTAssertThrowsError(try ScriptParser().parse("$replace(%title%,a")) { error in
            guard case let ScriptError.missingFunctionTerminator(name, location) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(name, "replace")
            XCTAssertEqual(location.line, 1)
            XCTAssertEqual(location.column, 1)
        }
    }

    func testRegexReplacementAndUnicodeEscape() throws {
        let result = try ScriptEvaluator().evaluate("$rreplace(%title%,\\\\s+,_)\\u{2605}", context: ScriptContext(
            metadata: Metadata(fields: ["title": ["A  B"]])
        ))
        XCTAssertEqual(result.output, "A_B★")
    }
}
