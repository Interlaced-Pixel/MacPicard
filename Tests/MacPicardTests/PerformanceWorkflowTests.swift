import Foundation
import PicardFoundation
import XCTest
@testable import MacPicard

final class PerformanceWorkflowTests: XCTestCase {
    @MainActor
    func testCheckpointDeltasAreLinearAndIgnoreTornOrOldGenerationTails() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReviewCheckpointStore()
        func checkpoint(_ count: Int) -> LibraryReviewCheckpoint {
            LibraryReviewCheckpoint(workspaceID: UUID(), country: "US", groups: (0..<count).map {
                AppModel.AlbumGroup(id: String($0), title: "Album \($0)", artist: "Artist", fileIDs: [UUID()])
            }, run: AppModel.LibraryMatchRun(proposals: [], autoApplyThreshold: 0.85, completedAt: Date()))
        }
        func batch(_ count: Int) async throws -> Int {
            var value = checkpoint(count)
            let url = root.appendingPathComponent("review-\(count).json")
            try await store.reset(value, to: url)
            for group in value.groups {
                value.run.proposals.append(AppModel.LibraryMatchProposal(id: group.id, albumTitle: group.title,
                    artist: group.artist, fileIDs: group.fileIDs, result: nil, release: nil, status: .review, errorMessage: nil))
                try await store.save(value, to: url, changedProposalIDs: [group.id])
            }
            let loaded = try await store.load(url); XCTAssertEqual(loaded.run.proposals.count, count)
            return try Data(contentsOf: url.appendingPathExtension("jsonl")).count
        }
        let small = try await batch(20), large = try await batch(40)
        XCTAssertLessThan(Double(large) / Double(small), 2.3)
        let url = root.appendingPathComponent("review-20.json")
        let oldLog = try Data(contentsOf: url.appendingPathExtension("jsonl"))
        let handle = try FileHandle(forWritingTo: url.appendingPathExtension("jsonl"))
        try handle.seekToEnd(); try handle.write(contentsOf: Data("{\"torn\":".utf8)); try handle.close()
        let recovered = try await store.load(url); XCTAssertEqual(recovered.run.proposals.count, 20)
        let fresh = checkpoint(1)
        try await store.reset(fresh, to: url)
        try oldLog.write(to: url.appendingPathExtension("jsonl"))
        let newGeneration = try await store.load(url)
        XCTAssertTrue(newGeneration.run.proposals.isEmpty)
        XCTAssertEqual(newGeneration.workspaceID, fresh.workspaceID)
    }
    @MainActor
    func testScriptWorkerYieldsMainActorAndCancellationStagesNothing() async throws {
        let model = AppModel()
        model.files = try (0..<100).map { index in
            var file = AudioFile(url: URL(fileURLWithPath: "/tmp/script-worker-\(index).flac"))
            try file.beginLoading()
            try file.finishLoading(metadata: Metadata(fields: ["title": ["Song \(index)"]]),
                identity: AudioFileIdentity(resourceIdentifier: nil, byteCount: 1, modificationDate: nil, prefixHash: "test"))
            return file
        }
        let original = model.files
        model.selectedFileIDs = Set(original.map(\.id))
        model.scriptSource = String(repeating: "%title%|", count: 4096)
        let task = Task { await model.runScript(applying: true) }
        for _ in 0..<100 {
            if model.isWorking { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(model.isWorking, "Main actor must be available while the worker is evaluating")
        task.cancel(); await task.value
        XCTAssertEqual(model.files, original)
        XCTAssertFalse(model.isWorking); XCTAssertNil(model.errorMessage)
        model.sessionSaveTask?.cancel()
    }
}
