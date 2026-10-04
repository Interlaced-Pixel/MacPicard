import Foundation
import PicardFormats
import PicardFoundation

public enum FileOperationKind: String, Codable, Sendable {
    case scan = "Refresh Library"
    case save = "Save Tags"
    case organize = "Organize"
    case importFiles = "Import"
}
public enum FileOperationState: String, Codable, Sendable {
    case running, completed, failed, interrupted
}
public enum FileOperationItemState: String, Codable, Sendable {
    case pending, inProgress, completed, failed, skipped, recovered
}
public struct FileOperationItem: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let source: URL
    public var destination: URL?
    public var temporary: URL?
    public let baseline: AudioFile?
    public var result: AudioFile?
    public var state: FileOperationItemState = .pending
    public var message = ""

    public init(file: AudioFile, destination: URL? = nil) {
        id = file.id
        source = file.url
        baseline = file
        self.destination = destination
    }
}
/// Written before touching audio; each file result is durable before the UI
/// announces completion. Incomplete writes are checked, never blindly replayed.
public struct FileOperationRecord: Codable, Sendable, Identifiable, Equatable {
    public let schemaVersion: Int
    public let id: UUID
    public let workspaceID: UUID
    public let kind: FileOperationKind
    public let startedAt: Date
    public var finishedAt: Date?
    public var state: FileOperationState = .running
    public var items: [FileOperationItem]
    public var message = ""

    public init(workspaceID: UUID, kind: FileOperationKind, items: [FileOperationItem]) {
        schemaVersion = 1
        id = UUID()
        self.workspaceID = workspaceID
        self.kind = kind
        startedAt = Date()
        self.items = items
    }

    public func persist(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

public actor OperationHistoryStore {
    public init() {}
    public func load(directory: URL, workspaceID: UUID, markInterrupted: Bool = false) throws -> [FileOperationRecord] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        var records: [FileOperationRecord] = []
        for url in urls {
            var record = try JSONDecoder().decode(FileOperationRecord.self, from: Data(contentsOf: url))
            guard record.schemaVersion == 1, record.workspaceID == workspaceID,
                url.deletingPathExtension().lastPathComponent == record.id.uuidString
            else {
                throw SaveError.session(
                    "The operation history needs a newer app or contains an invalid record. It was not replaced.")
            }
            if markInterrupted && record.state == .running {
                record.state = .interrupted
                record.message = "Interrupted. Check the files before trying again."
                try record.persist(to: url)
            }
            records.append(record)
        }
        return records.sorted { $0.startedAt > $1.startedAt }
    }
    public func save(_ record: FileOperationRecord, directory: URL) throws {
        try record.persist(to: directory.appendingPathComponent(record.id.uuidString).appendingPathExtension("json"))
    }

    /// Read-only recovery: locate the one item with the reviewed identity. An
    /// ambiguous pair, replaced file, or partial write requires manual review.
    public func check(_ record: FileOperationRecord, progress: (@Sendable (Double) async -> Void)? = nil) async throws -> FileOperationRecord {
        var updated = record
        let loader = AudioFileCoordinator()
        for index in updated.items.indices {
            try Task.checkCancellation()
            let item = updated.items[index]
            guard let baseline = item.baseline else { continue }
            updated.items[index].result = nil
            updated.items[index].state = .failed
            if record.kind == .organize {
                let urls = Set([item.source, item.destination, item.temporary].compactMap { $0 })
                let candidates = urls.filter {
                    guard let identity = try? AudioFileIdentity.capture(url: $0) else { return false }
                    return identity.matches(baseline.identity)
                }
                if candidates.count == 1, let found = candidates.first {
                    var file = baseline
                    try file.updateURL(found, identity: try AudioFileIdentity.capture(url: found))
                    updated.items[index].result = file
                    updated.items[index].state = .recovered
                    updated.items[index].message =
                        found == item.temporary
                        ? "Found in a temporary location. Reveal the file and restore its original filename before saving tags."
                        : "Location checked. Tags and artwork were preserved."
                } else {
                    updated.items[index].message =
                        "The file is missing, replaced, or appears in more than one location. Check the source, destination and temporary paths."
                }
            } else if record.kind == .save {
                do {
                    let loaded = try await loader.load(url: item.source, id: item.id)
                    let expected = item.result ?? baseline
                    if loaded.metadata == expected.metadata && loaded.artwork == expected.artwork
                        && loaded.identity?.matches(expected.identity) == true
                    {
                        updated.items[index].result = loaded
                        updated.items[index].state = .recovered
                        updated.items[index].message = "The reviewed tags are already on disk."
                    } else {
                        updated.items[index].message =
                            "The file identity or disk tags changed. Pending edits were kept; reload or review this file before saving."
                    }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    updated.items[index].message = error.localizedDescription
                }
            }
            if index % 25 == 0 || index == updated.items.count - 1 {
                await progress?(Double(index + 1) / Double(max(1, updated.items.count)))
            }
        }
        try Task.checkCancellation()
        updated.state =
            updated.items.allSatisfy { [.completed, .recovered, .skipped].contains($0.state) }
            ? .completed : .interrupted
        updated.finishedAt = Date()
        return updated
    }
}
