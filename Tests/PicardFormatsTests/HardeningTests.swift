import Foundation
import XCTest
@testable import PicardFormats

final class FormatHardeningTests: XCTestCase {
    func testRegistryHandlesDeterministicMalformedCorpus() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacPicardMalformed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let registry = FormatRegistry()
        for index in 0..<512 {
            let length = (index * 37) % 8193
            let bytes = Data((0..<length).map { offset in
                UInt8((index * 97 + offset * 31 + 17) & 0xFF)
            })
            let url = root.appendingPathComponent("sample-\(index).bin")
            try bytes.write(to: url)

            do {
                _ = try registry.detect(url: url)
            } catch {
                XCTAssertTrue(error is FormatError, "Unexpected error type: \(error)")
            }
        }
    }

    func testRegistryRejectsMissingAndEmptyFilesWithTypedErrors() throws {
        let registry = FormatRegistry()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacPicard-missing-\(UUID().uuidString).flac")
        XCTAssertThrowsError(try registry.detect(url: missing)) { error in
            XCTAssertTrue(error is FormatError)
        }

        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacPicard-empty-\(UUID().uuidString).bin")
        try Data().write(to: empty)
        defer { try? FileManager.default.removeItem(at: empty) }
        XCTAssertThrowsError(try registry.detect(url: empty)) { error in
            XCTAssertTrue(error is FormatError)
        }
    }
}
