import Foundation
import XCTest
@testable import PicardFoundation
@testable import PicardScripts

final class ScriptHardeningTests: XCTestCase {
    func testParserAndEvaluatorHandleDeterministicFuzzCorpus() throws {
        let alphabet = Array("$%()[],._-0123456789abcXYZ \\\\n")
        let parser = ScriptParser()
        let evaluator = ScriptEvaluator()
        let context = ScriptContext(metadata: Metadata(fields: [
            "title": ["Example Title"],
            "artist": ["Example Artist"],
            "tracknumber": ["12"]
        ]))

        for seed in 0..<512 {
            let length = 1 + (seed * 19) % 256
            let source = String((0..<length).map { offset in
                alphabet[(seed * 13 + offset * 7) % alphabet.count]
            })

            do {
                let program = try parser.parse(source)
                _ = try evaluator.evaluate(program.source, context: context)
            } catch {
                XCTAssertTrue(error is ScriptError, "Unexpected error type: \(error)")
            }
        }
    }

    func testLongValidScriptRemainsBoundedAndDeterministic() throws {
        let source = String(repeating: "%title%|", count: 2_048)
        let context = ScriptContext(metadata: Metadata(fields: ["title": ["Track"]]))
        let first = try ScriptEvaluator().evaluate(source, context: context)
        let second = try ScriptEvaluator().evaluate(source, context: context)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.output.count, "Track|".count * 2_048)
    }
}
