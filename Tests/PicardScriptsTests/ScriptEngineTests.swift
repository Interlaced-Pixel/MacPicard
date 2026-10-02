import Foundation
import PicardFoundation
import XCTest
@testable import PicardScripts

final class ScriptEngineTests: XCTestCase {
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
