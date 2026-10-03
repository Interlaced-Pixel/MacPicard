import Foundation
import PicardFormats
import PicardFoundation

public enum WorkspaceKind: String, Codable, Sendable {
    case session
    case library
}

public struct MusicWorkspace: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public let kind: WorkspaceKind
    public var directory: URL?
    public var lastOpenedAt: Date
    public var lastScannedAt: Date?
    public var automaticallyRefreshes: Bool

    public init(id: UUID = UUID(), name: String, kind: WorkspaceKind, directory: URL? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.directory = directory
        self.lastOpenedAt = Date()
        self.automaticallyRefreshes = kind == .library
    }
}

public struct WorkspaceCatalog: Codable, Sendable, Equatable {
    public var schemaVersion = 1
    public var workspaces: [MusicWorkspace] = []
    public var activeWorkspaceID: UUID?

    public init() {}
}

/// The catalog only references workspace documents. Removing an entry never deletes audio.
public actor WorkspaceStore {
    private let directory: URL
    private var catalog: WorkspaceCatalog?
    private var pendingCreates = Set<UUID>()

    public init(directory: URL) {
        self.directory = directory
    }

    public func load() throws -> WorkspaceCatalog {
        if let catalog { return catalog }
        let url = directory.appendingPathComponent("workspaces.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            let empty = WorkspaceCatalog()
            catalog = empty
            return empty
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let loaded = try decoder.decode(WorkspaceCatalog.self, from: Data(contentsOf: url))
        guard loaded.schemaVersion == 1,
              Set(loaded.workspaces.map(\.id)).count == loaded.workspaces.count,
              loaded.workspaces.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw SaveError.session("The workspace catalog is invalid or requires a newer MacPicard version.")
        }
        catalog = loaded
        return loaded
    }

    public func create(_ workspace: MusicWorkspace, document: SessionDocument) async throws -> WorkspaceCatalog {
        guard !pendingCreates.contains(workspace.id),
              !(try load()).workspaces.contains(where: { $0.id == workspace.id }) else {
            throw SaveError.session("This workspace already exists.")
        }
        guard !workspace.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              workspace.kind != .library || workspace.directory != nil else {
            throw SaveError.session("A workspace needs a name, and a library needs a folder.")
        }
        pendingCreates.insert(workspace.id)
        defer { pendingCreates.remove(workspace.id) }
        try await sessionStore(for: workspace.id).save(document)
        var next = try load()
        next.workspaces.append(workspace)
        next.activeWorkspaceID = workspace.id
        try persist(next)
        return next
    }

    public func activate(_ id: UUID) throws -> WorkspaceCatalog {
        var next = try load()
        guard let index = next.workspaces.firstIndex(where: { $0.id == id }) else {
            throw SaveError.session("The requested workspace does not exist.")
        }
        next.activeWorkspaceID = id
        next.workspaces[index].lastOpenedAt = Date()
        try persist(next)
        return next
    }

    public func update(_ workspace: MusicWorkspace) throws -> WorkspaceCatalog {
        var next = try load()
        guard let index = next.workspaces.firstIndex(where: { $0.id == workspace.id }),
              !workspace.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SaveError.session("The workspace could not be updated.")
        }
        next.workspaces[index] = workspace
        try persist(next)
        return next
    }

    public func remove(_ id: UUID) throws -> WorkspaceCatalog {
        var next = try load()
        guard next.activeWorkspaceID != id else {
            throw SaveError.session("Open another workspace before removing this one.")
        }
        next.workspaces.removeAll { $0.id == id }
        // Retain the document and recovery file so removal is recoverable on disk.
        try persist(next)
        return next
    }

    public func sessionStore(for id: UUID) -> SessionStore {
        let root = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        return SessionStore(
            sessionURL: root.appendingPathComponent("session.json"),
            recoveryURL: root.appendingPathComponent("recovery.json")
        )
    }

    private func persist(_ next: WorkspaceCatalog) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(next).write(to: directory.appendingPathComponent("workspaces.json"), options: .atomic)
        catalog = next
    }
}

public struct LibraryScanResult: Sendable {
    public let files: [AudioFile]
    public let addedCount: Int
    public let updatedCount: Int
    public let missingCount: Int
    public let conflicts: [String]
    public let failures: [String]
}

/// Enumeration and metadata reads run outside the main actor. A scan never writes audio.
public actor LibraryScanner {
    private let coordinator = AudioFileCoordinator()

    public init() {}

    public func scan(
        directory: URL,
        existing: [AudioFile],
        progress: (@Sendable (Double) async -> Void)? = nil
    ) async throws -> LibraryScanResult {
        guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw SaveError.session("A library root must be a directory.")
        }
        let urls = try Self.audioURLs(in: [directory])
        var byPath: [String: AudioFile] = [:]
        for file in existing { byPath[file.url.resolvingSymlinksInPath().standardizedFileURL.path] = file }
        var scanned: [AudioFile] = []
        var seen = Set<String>()
        var added = 0
        var updated = 0
        var conflicts: [String] = []
        var failures: [String] = []
        for (offset, url) in urls.enumerated() {
            try Task.checkCancellation()
            let key = url.resolvingSymlinksInPath().standardizedFileURL.path
            seen.insert(key)
            let previous = byPath[key]
            do {
                let identity = try AudioFileIdentity.capture(url: url)
                if var previous, previous.isModified {
                    if previous.state == .removed || previous.state == .failed {
                        try previous.restoreAvailability()
                    }
                    scanned.append(previous)
                    if !identity.matches(previous.identity) { conflicts.append(url.lastPathComponent) }
                } else if let previous, identity.matches(previous.identity), previous.state != .removed,
                          previous.state != .failed {
                    scanned.append(previous)
                } else {
                    let loaded = try await coordinator.load(url: url, id: previous?.id ?? UUID())
                    scanned.append(loaded)
                    if previous == nil { added += 1 } else { updated += 1 }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                var failed = previous ?? AudioFile(url: url)
                failed.markFailure(error)
                scanned.append(failed)
            }
            if offset % 25 == 0 || offset == urls.count - 1 {
                await progress?(Double(offset + 1) / Double(max(urls.count, 1)))
            }
        }
        var missing = 0
        for var file in existing where !seen.contains(file.url.resolvingSymlinksInPath().standardizedFileURL.path) {
            // Imported files outside the library root remain members of the workspace.
            let root = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
            if file.url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root) {
                file.markRemoved()
                missing += 1
            }
            scanned.append(file)
        }
        return LibraryScanResult(
            files: scanned, addedCount: added, updatedCount: updated,
            missingCount: missing, conflicts: conflicts, failures: failures
        )
    }

    public func expand(_ urls: [URL]) throws -> [URL] {
        try Self.audioURLs(in: urls)
    }

    private static func audioURLs(in roots: [URL]) throws -> [URL] {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        var result: [URL] = []
        var paths = Set<String>()
        for root in roots {
            try Task.checkCancellation()
            let values = try root.resourceValues(forKeys: keys)
            if values.isDirectory == true {
                // An unreadable/offline root must not mark the entire library as missing.
                _ = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                var enumerationError: Error?
                guard let enumerator = manager.enumerator(
                    at: root, includingPropertiesForKeys: Array(keys),
                    options: [.skipsHiddenFiles, .skipsPackageDescendants],
                    errorHandler: { _, error in enumerationError = error; return false }
                ) else { throw SaveError.session("Cannot enumerate \(root.path).") }
                for case let child as URL in enumerator {
                    try Task.checkCancellation()
                    let childValues = try child.resourceValues(forKeys: keys)
                    if childValues.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                    if childValues.isRegularFile == true,
                       FormatRegistry.format(forExtension: child.pathExtension) != nil,
                       paths.insert(child.resolvingSymlinksInPath().standardizedFileURL.path).inserted {
                        result.append(child.resolvingSymlinksInPath().standardizedFileURL)
                    }
                }
                if let enumerationError { throw enumerationError }
            } else if values.isRegularFile == true,
                      FormatRegistry.format(forExtension: root.pathExtension) != nil,
                      paths.insert(root.resolvingSymlinksInPath().standardizedFileURL.path).inserted {
                result.append(root.resolvingSymlinksInPath().standardizedFileURL)
            }
        }
        return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
