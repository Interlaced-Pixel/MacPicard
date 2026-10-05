import Foundation
import PicardFoundation
import XCTest
@testable import PicardSessions

final class PerformanceJournalTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    func testDeltasReplayTornTailIsIgnoredAndCompletedDetailsLoadLazily() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let workspace = UUID()
        var record = FileOperationRecord(workspaceID: workspace, kind: .save,
            items: (0..<2).map { FileOperationItem(file: AudioFile(url: root.appendingPathComponent("\($0).flac"))) })
        let url = root.appendingPathComponent(record.id.uuidString).appendingPathExtension("json")
        try record.persist(to: url)
        let initial = try Data(contentsOf: url)
        record.items[0].state = .inProgress
        try record.persist(to: url, changedItemIDs: [record.items[0].id])
        record.items[0].state = .completed; record.items[0].message = "Durable"
        try record.persist(to: url, changedItemIDs: [record.items[0].id])
        XCTAssertEqual(try Data(contentsOf: url), initial)
        let deltaURL = url.appendingPathExtension("jsonl")
        let handle = try FileHandle(forWritingTo: deltaURL)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("{\"unfinished\":".utf8)); try handle.close()
        let store = OperationHistoryStore()
        let recovered = try await store.load(directory: root, workspaceID: workspace, markInterrupted: true)
        XCTAssertEqual(recovered.first?.items[0].message, "Durable")
        XCTAssertEqual(recovered.first?.state, .interrupted)
        record = try XCTUnwrap(recovered.first)
        record.items[1].state = .completed; record.state = .completed; record.finishedAt = Date()
        try record.persist(to: url)
        let summaries = try await store.load(directory: root, workspaceID: workspace, summariesOnly: true)
        XCTAssertEqual(summaries.first?.items.count, 0); XCTAssertEqual(summaries.first?.itemCount, 2)
        let details = try await store.details(id: record.id, directory: root)
        XCTAssertEqual(details.items, record.items)
        XCTAssertEqual(details.state, .completed)
    }
    func testScanJournalCanAddItemsAtCompletion() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        var record = FileOperationRecord(workspaceID: UUID(), kind: .scan, items: [])
        let url = root.appendingPathComponent(record.id.uuidString).appendingPathExtension("json")
        try record.persist(to: url)
        record.items = [FileOperationItem(file: AudioFile(url: root.appendingPathComponent("new.flac")))]
        record.state = .completed
        try record.persist(to: url)
        let loaded = try await OperationHistoryStore().details(id: record.id, directory: root)
        XCTAssertEqual(loaded.items, record.items)
    }
    func testLegacyCompletedHistoryCreatesSummaryWithoutReplacingItsSnapshot() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        var record = FileOperationRecord(workspaceID: UUID(), kind: .save,
            items: [FileOperationItem(file: AudioFile(url: root.appendingPathComponent("old.flac")))])
        record.schemaVersion = 1; record.state = .completed; record.items[0].state = .completed
        let url = root.appendingPathComponent(record.id.uuidString).appendingPathExtension("json")
        let original = try JSONEncoder().encode(record); try original.write(to: url)
        let store = OperationHistoryStore()
        let summaries = try await store.load(directory: root, workspaceID: record.workspaceID, summariesOnly: true)
        XCTAssertTrue(try XCTUnwrap(summaries.first).items.isEmpty)
        XCTAssertEqual(summaries.first?.itemCount, 1)
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("summary").path))
        // A corrupt derived summary cannot make a valid snapshot unavailable.
        try Data("broken".utf8).write(to: url.appendingPathExtension("summary"))
        let repaired = try await store.load(directory: root, workspaceID: record.workspaceID, summariesOnly: true)
        XCTAssertEqual(repaired.first?.itemCount, 1)
        let details = try await store.details(id: record.id, directory: root)
        XCTAssertEqual(details.items, record.items)
    }
    func testExplicitDeltaUsesItemIDAfterReordering() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        var record = FileOperationRecord(workspaceID: UUID(), kind: .save,
            items: (0..<2).map { FileOperationItem(file: AudioFile(url: root.appendingPathComponent("\($0).flac"))) })
        let url = root.appendingPathComponent(record.id.uuidString).appendingPathExtension("json")
        try record.persist(to: url)
        record.items.reverse(); record.items[0].state = .completed
        try record.persist(to: url, changedItemIDs: [record.items[0].id])
        let details = try await OperationHistoryStore().details(id: record.id, directory: root)
        XCTAssertEqual(details.items.first { $0.id == record.items[0].id }?.state, .completed)
        XCTAssertEqual(details.items.first { $0.id == record.items[1].id }?.state, .pending)
    }
    func testCheckpointBytesScaleLinearlyRatherThanRewritingEveryItem() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        func batch(_ count: Int) throws -> Int {
            var record = FileOperationRecord(workspaceID: UUID(), kind: .save,
                items: (0..<count).map { FileOperationItem(file: AudioFile(url: root.appendingPathComponent("\($0).flac"))) })
            let url = root.appendingPathComponent(record.id.uuidString).appendingPathExtension("json")
            var bytes = try record.persist(to: url)
            for index in record.items.indices {
                record.items[index].state = .inProgress
                bytes += try record.persist(to: url, changedItemIDs: [record.items[index].id])
                record.items[index].state = .completed
                bytes += try record.persist(to: url, changedItemIDs: [record.items[index].id])
            }
            return bytes
        }
        let small = try batch(16), large = try batch(32)
        XCTAssertLessThan(Double(large) / Double(small), 2.3)
    }
}
