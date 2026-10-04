import Foundation
import PicardFormats
import PicardFoundation

public enum WorkspaceKind: String, Codable, Sendable {
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
    public var excludedRelativePaths: Set<String> = []

    public init(id: UUID = UUID(), name: String, kind: WorkspaceKind = .library, directory: URL? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.directory = directory
        self.lastOpenedAt = Date()
        self.automaticallyRefreshes = kind == .library
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, directory, lastOpenedAt, lastScannedAt, automaticallyRefreshes, excludedRelativePaths
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        // Sessions from older catalogs become libraries. Their saved documents,
        // bookmarks and file URLs stay in place; only the catalog is migrated.
        let savedKind = try values.decode(String.self, forKey: .kind)
        guard savedKind == "library" || savedKind == "session" else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: values, debugDescription: "Unknown library type.")
        }
        kind = .library
        directory = try values.decodeIfPresent(URL.self, forKey: .directory)
        lastOpenedAt = try values.decode(Date.self, forKey: .lastOpenedAt)
        lastScannedAt = try values.decodeIfPresent(Date.self, forKey: .lastScannedAt)
        automaticallyRefreshes = try values.decodeIfPresent(Bool.self, forKey: .automaticallyRefreshes) ?? (savedKind == "library")
        excludedRelativePaths = try values.decodeIfPresent(Set<String>.self, forKey: .excludedRelativePaths) ?? []
    }
}

public struct WorkspaceCatalog: Codable, Sendable, Equatable {
    public var schemaVersion = 2
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

    public func hasSavedCatalog() -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("workspaces.json").path)
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
        var loaded = try decoder.decode(WorkspaceCatalog.self, from: Data(contentsOf: url))
        guard (1...2).contains(loaded.schemaVersion),
              Set(loaded.workspaces.map(\.id)).count == loaded.workspaces.count,
              loaded.workspaces.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              loaded.activeWorkspaceID == nil || loaded.workspaces.contains(where: { $0.id == loaded.activeWorkspaceID }) else {
            throw SaveError.session("The library catalog is invalid or requires a newer MacPicard version.")
        }
        if loaded.schemaVersion == 1 {
            guard loaded.workspaces.allSatisfy({ $0.directory == nil || $0.directory?.isFileURL == true }) else {
                throw SaveError.session("A saved Music Library must use a local folder. The catalog was not replaced.")
            }
            for index in loaded.workspaces.indices where loaded.workspaces[index].directory == nil {
                loaded.workspaces[index] = try materializeLibrary(loaded.workspaces[index])
            }
            loaded.schemaVersion = 2
            try persist(loaded)
        }
        guard loaded.workspaces.allSatisfy({ $0.directory?.isFileURL == true }) else {
            throw SaveError.session("A saved Music Library is missing its folder. The catalog was not replaced.")
        }
        catalog = loaded
        return loaded
    }

    public func create(_ workspace: MusicWorkspace, document: SessionDocument) async throws -> WorkspaceCatalog {
        guard !pendingCreates.contains(workspace.id),
              !(try load()).workspaces.contains(where: { $0.id == workspace.id }) else {
            throw SaveError.session("This Music Library already exists.")
        }
        guard !workspace.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SaveError.session("A Music Library needs a name.")
        }
        pendingCreates.insert(workspace.id)
        defer { pendingCreates.remove(workspace.id) }
        let workspace = try materializeLibrary(workspace)
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
            throw SaveError.session("The requested Music Library does not exist.")
        }
        next.activeWorkspaceID = id
        next.workspaces[index].lastOpenedAt = Date()
        try persist(next)
        return next
    }

    public func update(_ workspace: MusicWorkspace) throws -> WorkspaceCatalog {
        var next = try load()
        guard let index = next.workspaces.firstIndex(where: { $0.id == workspace.id }),
              !workspace.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              workspace.directory?.isFileURL == true else {
            throw SaveError.session("The Music Library could not be updated.")
        }
        next.workspaces[index] = workspace
        try persist(next)
        return next
    }

    public func remove(_ id: UUID) throws -> WorkspaceCatalog {
        var next = try load()
        guard next.activeWorkspaceID != id || next.workspaces.count == 1 else {
            throw SaveError.session("Open another Music Library before removing this one.")
        }
        next.workspaces.removeAll { $0.id == id }
        if next.activeWorkspaceID == id { next.activeWorkspaceID = nil }
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

    public func operationDirectory(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: true).appendingPathComponent("Operations", isDirectory: true)
    }

    private func materializeLibrary(_ library: MusicWorkspace) throws -> MusicWorkspace {
        var result = library
        if result.directory == nil {
            let root = directory.appendingPathComponent(result.id.uuidString, isDirectory: true)
                .appendingPathComponent("Music", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            result.directory = root
        }
        guard result.directory?.isFileURL == true else {
            throw SaveError.session("A Music Library must use a local folder.")
        }
        return result
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
    public let metadataReadCount: Int
    public let inspectedFileCount: Int

    /// Apply deltas, never an old whole-library snapshot. Files edited, imported,
    /// moved or removed after the scan began always win over its baseline.
    public func merging(baseline: [AudioFile], current: [AudioFile]) -> [AudioFile] {
        let before = Dictionary(baseline.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let after = Dictionary(files.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var merged = current.map { file in
            file == before[file.id] ? (after[file.id] ?? file) : file
        }
        let currentPaths = Set(current.map { $0.url.standardizedFileURL.path })
        let currentIDs = Set(current.map(\.id))
        merged.append(contentsOf: files.filter {
            before[$0.id] == nil && !currentIDs.contains($0.id) && !currentPaths.contains($0.url.standardizedFileURL.path)
        })
        return merged
    }
}

/// Enumeration and metadata reads run outside the main actor. A scan never writes audio.
public actor LibraryScanner {
    private let coordinator = AudioFileCoordinator()

    public init() {}

    public func scan(
        directory: URL,
        existing: [AudioFile],
        excludingRelativePaths: Set<String> = [],
        affectedPaths: Set<URL>? = nil,
        progress: (@Sendable (Double) async -> Void)? = nil
    ) async throws -> LibraryScanResult {
        guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw SaveError.session("A library root must be a directory.")
        }
        // Validate the root even for a partial scan, so an offline drive cannot
        // be mistaken for hundreds of deleted files.
        _ = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let hints = affectedPaths.map { paths in
            paths.map { $0.resolvingSymlinksInPath().standardizedFileURL }.filter {
                $0 == root || $0.path.hasPrefix(root.path + "/")
            }
        }
        func affected(_ url: URL) -> Bool {
            guard let hints else { return true }
            let normalized = url.resolvingSymlinksInPath().standardizedFileURL
            return hints.contains { normalized == $0 || normalized.path.hasPrefix($0.path + "/") }
        }
        let roots = hints?.filter { FileManager.default.fileExists(atPath: $0.path) } ?? [root]
        let urls = try Self.audioURLs(in: roots).filter {
            !excludingRelativePaths.contains(LibraryPaths.relativePath(of: $0, in: directory) ?? "")
        }
        var byPath: [String: AudioFile] = [:]
        for file in existing { byPath[file.url.resolvingSymlinksInPath().standardizedFileURL.path] = file }
        let byResource = Dictionary(grouping: existing.filter { $0.identity?.resourceIdentifier != nil },
            by: { $0.identity!.resourceIdentifier! })
        var scanned: [AudioFile] = existing.filter { !affected($0.url) }
        let availablePaths = Set(urls.map { $0.standardizedFileURL.path })
        var renamedIDs = Set<UUID>()
        var seen = Set<String>()
        var added = 0
        var updated = 0
        var conflicts: [String] = []
        var failures: [String] = []
        var reads = 0
        for (offset, url) in urls.enumerated() {
            try Task.checkCancellation()
            let key = url.resolvingSymlinksInPath().standardizedFileURL.path
            seen.insert(key)
            var previous = byPath[key]
            do {
                let identity = try AudioFileIdentity.capture(url: url)
                // Track only unambiguous renames of the same filesystem item.
                // A copy/hard link at another existing path must remain separate.
                if previous == nil, let resourceID = identity.resourceIdentifier {
                    let candidates = (byResource[resourceID] ?? []).filter {
                        !renamedIDs.contains($0.id)
                            && !availablePaths.contains($0.url.standardizedFileURL.path)
                            && !FileManager.default.fileExists(atPath: $0.url.path)
                    }
                    if candidates.count == 1 {
                        previous = candidates[0]
                        try previous?.updateURL(url)
                        renamedIDs.insert(candidates[0].id)
                        scanned.removeAll { $0.id == candidates[0].id }
                        updated += 1
                    }
                }
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
                    reads += 1
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
        for var file in existing where affected(file.url) && !renamedIDs.contains(file.id)
            && !seen.contains(file.url.resolvingSymlinksInPath().standardizedFileURL.path) {
            if excludingRelativePaths.contains(LibraryPaths.relativePath(of: file.url, in: directory) ?? "") { continue }
            // Imported files outside the library root remain members of the workspace.
            let root = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
            if file.url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root) {
                if file.state != .removed { file.markRemoved(); missing += 1 }
            }
            scanned.append(file)
        }
        return LibraryScanResult(
            files: scanned, addedCount: added, updatedCount: updated,
            missingCount: missing, conflicts: conflicts, failures: failures,
            metadataReadCount: reads, inspectedFileCount: urls.count
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
