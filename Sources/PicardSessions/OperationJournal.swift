import Foundation
import PicardFoundation

public struct FileOperationSummary: Codable, Sendable, Equatable {
    public let itemCount: Int
    public let stateCounts: [String: Int]
    public let checkpointLength: UInt64?
}

/// One initial snapshot, then bounded item deltas. A newline is the commit
/// marker; a torn final append is ignored. Each complete append is fsynced
/// before returning to the caller that is about to mutate an audio file.
final class OperationJournal: @unchecked Sendable {
    static let shared = OperationJournal()
    private struct Cached {
        var items: [UUID: FileOperationItem]
        var counts: [String: Int]
        var positions: [UUID: Int]
        var committedLength: UInt64 = 0
    }
    private struct Delta: Codable {
        let id: UUID
        let state: FileOperationState
        let finishedAt: Date?
        let message: String
        let items: [FileOperationItem]
        let removedIDs: [UUID]?
    }
    /// Decode old completed records without hydrating audio metadata or artwork.
    /// Their original snapshots remain the authority for on-demand details.
    private struct Header: Decodable {
        struct Item: Decodable { let state: FileOperationItemState }
        let schemaVersion: Int
        let id: UUID
        let workspaceID: UUID
        let kind: FileOperationKind
        let startedAt: Date
        let finishedAt: Date?
        let state: FileOperationState
        let message: String
        let items: [Item]
        var record: FileOperationRecord {
            FileOperationRecord(schemaVersion: schemaVersion, id: id, workspaceID: workspaceID,
                kind: kind, startedAt: startedAt, finishedAt: finishedAt, state: state, message: message,
                summary: FileOperationSummary(itemCount: items.count,
                    stateCounts: Dictionary(items.map { ($0.state.rawValue, 1) }, uniquingKeysWith: +),
                    checkpointLength: 0))
        }
    }
    private let lock = NSLock()
    private var cached: [URL: Cached] = [:]
    private var order: [URL] = []
    private var blobs: [URL: ArtworkBlobStore] = [:]

    func persist(_ input: FileOperationRecord, to url: URL, changedItemIDs: Set<UUID>?) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        var record = input
        guard record.summary == nil else { throw SaveError.session("Load operation details before changing its journal.") }
        record.schemaVersion = 2
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blobDirectory = directory.appendingPathComponent("ArtworkBlobs", isDirectory: true)
        let store = blobs[blobDirectory] ?? ArtworkBlobStore(directory: blobDirectory, memoryLimit: 8 * 1024 * 1024)
        blobs[blobDirectory] = store
        let encoder = JSONEncoder()
        encoder.userInfo[ArtworkBlobStore.codingKey] = store
        var bytes = 0
        if !FileManager.default.fileExists(atPath: url.path) {
            let data = try encoder.encode(record)
            try DurableArchive.replace(data, at: url)
            bytes += data.count
            cached[url] = Self.index(record)
        } else {
            if cached[url] == nil {
                var index = Self.index(try Self.read(url))
                let deltaURL = url.appendingPathExtension("jsonl")
                if FileManager.default.fileExists(atPath: deltaURL.path) { index.committedLength = UInt64(try Self.committedLength(deltaURL)) }
                cached[url] = index
            }
            var index = cached[url]!
            let changes: [FileOperationItem]
            if let changedItemIDs {
                if changedItemIDs.contains(where: { id in
                    guard let position = index.positions[id], record.items.indices.contains(position) else { return true }
                    return record.items[position].id != id
                }) {
                    index.positions = Dictionary(uniqueKeysWithValues: record.items.enumerated().map { ($0.element.id, $0.offset) })
                }
                changes = changedItemIDs.compactMap { index.positions[$0].map { record.items[$0] } }
                guard changes.count == changedItemIDs.count else { throw SaveError.session("Unknown operation item.") }
            } else { changes = record.items.filter { index.items[$0.id] != $0 } }
            let incomingIDs = changedItemIDs != nil && record.items.count == index.items.count ? nil : Set(record.items.map(\.id))
            let removedIDs = incomingIDs.map { Set(index.items.keys).subtracting($0) } ?? []
            for id in removedIDs {
                if let removed = index.items.removeValue(forKey: id) { index.counts[removed.state.rawValue, default: 0] -= 1 }
            }
            for item in changes {
                if let previous = index.items[item.id] { index.counts[previous.state.rawValue, default: 0] -= 1 }
                index.counts[item.state.rawValue, default: 0] += 1
                index.items[item.id] = item
            }
            if incomingIDs != nil { index.positions = Dictionary(uniqueKeysWithValues: record.items.enumerated().map { ($0.element.id, $0.offset) }) }
            var data = try encoder.encode(Delta(id: record.id, state: record.state,
                finishedAt: record.finishedAt, message: record.message, items: changes, removedIDs: Array(removedIDs)))
            data.append(0x0A)
            let deltaURL = url.appendingPathExtension("jsonl")
            if !FileManager.default.fileExists(atPath: deltaURL.path) {
                FileManager.default.createFile(atPath: deltaURL.path, contents: nil)
                try DurableArchive.synchronizeDirectory(directory)
            }
            let handle = try FileHandle(forWritingTo: deltaURL)
            defer { try? handle.close() }
            // Remove an uncommitted tail left by a crash before appending again.
            try handle.truncate(atOffset: index.committedLength)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
            index.committedLength += UInt64(data.count)
            bytes += data.count
            cached[url] = index
        }
        let index = cached[url]!
        var summary = record
        summary.items = []
        summary.summary = FileOperationSummary(itemCount: index.items.count, stateCounts: index.counts, checkpointLength: index.committedLength)
        let summaryData = try encoder.encode(summary)
        try summaryData.write(to: Self.summaryURL(url), options: .atomic)
        bytes += summaryData.count
        order.removeAll { $0 == url }; order.append(url)
        while order.count > 4 { cached.removeValue(forKey: order.removeFirst()) }
        let activeBlobDirectories = Set(cached.keys.map { $0.deletingLastPathComponent().appendingPathComponent("ArtworkBlobs", isDirectory: true) })
        blobs = blobs.filter { activeBlobDirectories.contains($0.key) }
        return bytes
    }

    static func read(_ url: URL, summaryOnly: Bool = false) throws -> FileOperationRecord {
        let decoder = JSONDecoder()
        decoder.userInfo[ArtworkBlobStore.codingKey] = ArtworkBlobStore(directory: url.deletingLastPathComponent().appendingPathComponent("ArtworkBlobs"))
        if summaryOnly, let data = try? Data(contentsOf: summaryURL(url)),
           let summary = try? decoder.decode(FileOperationRecord.self, from: data) {
            guard summary.id.uuidString == url.deletingPathExtension().lastPathComponent else { throw SaveError.session("Invalid operation summary.") }
            // Unfinished operations must retain all their recovery information.
            let deltaURL = url.appendingPathExtension("jsonl")
            let length = FileManager.default.fileExists(atPath: deltaURL.path)
                ? UInt64(try deltaURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) : 0
            if summary.state == .completed, summary.summary?.checkpointLength == length { return summary }
        }
        if summaryOnly, !FileManager.default.fileExists(atPath: url.appendingPathExtension("jsonl").path) {
            let header = try decoder.decode(Header.self, from: Data(contentsOf: url))
            if (1...2).contains(header.schemaVersion), header.state == .completed {
                let summary = header.record
                try JSONEncoder().encode(summary).write(to: summaryURL(url), options: .atomic)
                return summary
            }
        }
        var record = try decoder.decode(FileOperationRecord.self, from: Data(contentsOf: url))
        let deltaURL = url.appendingPathExtension("jsonl")
        if FileManager.default.fileExists(atPath: deltaURL.path) {
            let data = try Data(contentsOf: deltaURL)
            var indices = Dictionary(uniqueKeysWithValues: record.items.enumerated().map { ($0.element.id, $0.offset) })
            let committed = data.prefix(committedLength(data))
            for line in committed.split(separator: 0x0A) {
                let delta = try decoder.decode(Delta.self, from: Data(line))
                guard delta.id == record.id else { throw SaveError.session("Invalid operation delta.") }
                record.state = delta.state; record.finishedAt = delta.finishedAt; record.message = delta.message
                if let removed = delta.removedIDs, !removed.isEmpty {
                    let ids = Set(removed); record.items.removeAll { ids.contains($0.id) }
                    indices = Dictionary(uniqueKeysWithValues: record.items.enumerated().map { ($0.element.id, $0.offset) })
                }
                for item in delta.items {
                    if let index = indices[item.id] { record.items[index] = item }
                    else { indices[item.id] = record.items.count; record.items.append(item) }
                }
            }
        }
        return record
    }
    private static func index(_ record: FileOperationRecord) -> Cached {
        Cached(items: Dictionary(uniqueKeysWithValues: record.items.map { ($0.id, $0) }),
            counts: Dictionary(record.items.map { ($0.state.rawValue, 1) }, uniquingKeysWith: +),
            positions: Dictionary(uniqueKeysWithValues: record.items.enumerated().map { ($0.element.id, $0.offset) }))
    }
    private static func summaryURL(_ url: URL) -> URL { url.appendingPathExtension("summary") }
    private static func committedLength(_ url: URL) throws -> Int { committedLength(try Data(contentsOf: url)) }
    private static func committedLength(_ data: Data) -> Int { data.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0 }
}
