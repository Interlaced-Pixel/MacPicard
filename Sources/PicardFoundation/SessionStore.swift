import Foundation

public struct SessionDocument: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var createdAt: Date
    public var savedAt: Date
    public var files: [AudioFileSessionRecord]
    public var selectedFileIDs: [UUID]
    public var expandedNodeIDs: [UUID]
    public var selectedAlbumKey: String?
    public var accessBookmarkKeys: [String]
    var archiveGeneration: UUID?

    public init(
        schemaVersion: Int = SessionDocument.currentSchemaVersion,
        createdAt: Date = Date(),
        savedAt: Date = Date(),
        files: [AudioFileSessionRecord] = [],
        selectedFileIDs: [UUID] = [],
        expandedNodeIDs: [UUID] = [],
        selectedAlbumKey: String? = nil,
        accessBookmarkKeys: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.savedAt = savedAt
        self.files = files
        self.selectedFileIDs = selectedFileIDs
        self.expandedNodeIDs = expandedNodeIDs
        self.selectedAlbumKey = selectedAlbumKey
        self.accessBookmarkKeys = accessBookmarkKeys
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case createdAt
        case savedAt
        case files
        case selectedFileIDs
        case expandedNodeIDs
        case selectedAlbumKey
        case accessBookmarkKeys
        case archiveGeneration
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaVersion: try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
                ?? SessionDocument.currentSchemaVersion,
            createdAt: try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(),
            savedAt: try container.decodeIfPresent(Date.self, forKey: .savedAt) ?? Date(),
            files: try container.decodeIfPresent([AudioFileSessionRecord].self, forKey: .files) ?? [],
            selectedFileIDs: try container.decodeIfPresent([UUID].self, forKey: .selectedFileIDs) ?? [],
            expandedNodeIDs: try container.decodeIfPresent([UUID].self, forKey: .expandedNodeIDs) ?? [],
            selectedAlbumKey: try container.decodeIfPresent(String.self, forKey: .selectedAlbumKey),
            accessBookmarkKeys: try container.decodeIfPresent([String].self, forKey: .accessBookmarkKeys) ?? []
        )
        archiveGeneration = try container.decodeIfPresent(UUID.self, forKey: .archiveGeneration)
    }
}

public enum SessionMigrator {
    public static func migrate(_ data: Data) throws -> Data {
        struct Header: Decodable { let schemaVersion: Int? }
        let header = try JSONDecoder().decode(Header.self, from: data)
        if let version = header.schemaVersion {
            guard version <= SessionDocument.currentSchemaVersion else {
                throw PicardError.invalidConfiguration("Unsupported session schema version \(version).")
            }
            // V1 inline bytes and V2 blob references have the same field shape.
            // Decode directly without a second, fully materialized JSON tree.
            if version >= 1 { return data }
        }
        let object: Any

        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw PicardError.sessionEncoding(error.localizedDescription)
        }

        guard var dictionary = object as? [String: Any] else {
            throw PicardError.sessionEncoding("The root JSON value must be an object.")
        }

        let sourceVersion = dictionary["schemaVersion"] as? Int ?? 0
        guard sourceVersion <= SessionDocument.currentSchemaVersion else {
            throw PicardError.invalidConfiguration("Unsupported session schema version \(sourceVersion).")
        }

        // Do not round-trip current JSON through NSNumber: it can lose the last
        // bit of a timestamp, and current documents need no transformation.
        if sourceVersion == SessionDocument.currentSchemaVersion { return data }

        var version = sourceVersion
        while version < SessionDocument.currentSchemaVersion {
            switch version {
            case 0:
                dictionary["schemaVersion"] = SessionDocument.currentSchemaVersion
                version = SessionDocument.currentSchemaVersion
            default:
                throw PicardError.migrationFailed(
                    from: version,
                    to: SessionDocument.currentSchemaVersion,
                    reason: "No session migration exists for this schema version."
                )
            }
        }

        do {
            return try JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys])
        } catch {
            throw PicardError.sessionEncoding(error.localizedDescription)
        }
    }
}

public actor SessionStore {
    private struct Navigation: Codable {
        let generation: UUID
        let savedAt: Date
        let selectedFileIDs: [UUID]
        let expandedNodeIDs: [UUID]
        let selectedAlbumKey: String?
        let accessBookmarkKeys: [String]
    }
    private let sessionURL: URL
    private let recoveryURL: URL
    private var savedContent: [URL: SessionDocument] = [:]
    private var blobStores: [URL: ArtworkBlobStore] = [:]
    private var generations: [URL: UUID] = [:]
    public private(set) var writeCount = 0

    public init(sessionURL: URL, recoveryURL: URL) {
        self.sessionURL = sessionURL
        self.recoveryURL = recoveryURL
    }

    public func load() throws -> SessionDocument? {
        try load(from: sessionURL)
    }

    public func loadRecovery() throws -> SessionDocument? {
        try load(from: recoveryURL)
    }

    public func save(_ document: SessionDocument) throws {
        try write(document, to: sessionURL)
    }

    public func saveRecovery(_ document: SessionDocument) throws {
        try write(document, to: recoveryURL)
    }

    public func removeRecovery() throws {
        savedContent.removeValue(forKey: recoveryURL)
        guard FileManager.default.fileExists(atPath: recoveryURL.path) else {
            return
        }

        do {
            try FileManager.default.removeItem(at: recoveryURL)
            savedContent.removeValue(forKey: recoveryURL)
        } catch {
            throw PicardError.sessionWrite(path: recoveryURL.path, reason: error.localizedDescription)
        }
    }

    private func load(from url: URL) throws -> SessionDocument? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PicardError.sessionRead(path: url.path, reason: error.localizedDescription)
        }

        let migratedData = try SessionMigrator.migrate(data)

        do {
            let decoder = JSONDecoder.makeSessionDecoder()
            decoder.userInfo[ArtworkBlobStore.codingKey] = blobStore(for: url)
            var document = try decoder.decode(SessionDocument.self, from: migratedData)
            if let generation = document.archiveGeneration {
                generations[url] = generation
                let navigationURL = url.appendingPathExtension("navigation")
                if FileManager.default.fileExists(atPath: navigationURL.path) {
                    if let navigation = try? decoder.decode(Navigation.self, from: Data(contentsOf: navigationURL)), navigation.generation == generation {
                        document.savedAt = navigation.savedAt
                        document.selectedFileIDs = navigation.selectedFileIDs
                        document.expandedNodeIDs = navigation.expandedNodeIDs
                        document.selectedAlbumKey = navigation.selectedAlbumKey
                        document.accessBookmarkKeys = navigation.accessBookmarkKeys
                    }
                }
            }
            document.archiveGeneration = nil
            document.schemaVersion = SessionDocument.currentSchemaVersion
            var normalized = document; normalized.savedAt = Date(timeIntervalSince1970: 0)
            savedContent[url] = normalized
            return document
        } catch {
            throw PicardError.sessionEncoding(error.localizedDescription)
        }
    }

    private func write(_ document: SessionDocument, to url: URL) throws {
        guard document.schemaVersion <= SessionDocument.currentSchemaVersion else {
            throw PicardError.invalidConfiguration("Unsupported session schema version \(document.schemaVersion).")
        }

        do {
            var normalized = document
            normalized.schemaVersion = SessionDocument.currentSchemaVersion
            normalized.archiveGeneration = nil
            normalized.savedAt = Date(timeIntervalSince1970: 0)
            let encoder = JSONEncoder.makeSessionEncoder()
            encoder.userInfo[ArtworkBlobStore.codingKey] = blobStore(for: url)
            if savedContent[url] == nil, var previous = try replacementBaseline(from: url) {
                previous.savedAt = normalized.savedAt
                savedContent[url] = previous
            }
            if savedContent[url] == normalized, FileManager.default.fileExists(atPath: url.path) { return }
            if url == recoveryURL {
                if savedContent[sessionURL] == nil, var primary = try replacementBaseline(from: sessionURL) {
                    primary.savedAt = normalized.savedAt
                    savedContent[sessionURL] = primary
                }
                if savedContent[sessionURL] == normalized, FileManager.default.fileExists(atPath: sessionURL.path) { return }
            }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if let previous = savedContent[url], let generation = generations[url],
               previous.files == normalized.files, previous.createdAt == normalized.createdAt,
               FileManager.default.fileExists(atPath: url.path) {
                let navigation = Navigation(generation: generation, savedAt: document.savedAt,
                    selectedFileIDs: document.selectedFileIDs, expandedNodeIDs: document.expandedNodeIDs,
                    selectedAlbumKey: document.selectedAlbumKey, accessBookmarkKeys: document.accessBookmarkKeys)
                try DurableArchive.replace(encoder.encode(navigation), at: url.appendingPathExtension("navigation"))
                savedContent[url] = normalized; writeCount += 1
                return
            }
            var persisted = document; persisted.schemaVersion = SessionDocument.currentSchemaVersion
            let generation = UUID(); persisted.archiveGeneration = generation
            let data = try encoder.encode(persisted)
            try DurableArchive.replace(data, at: url)
            savedContent[url] = normalized
            generations[url] = generation
            writeCount += 1
        } catch let error as PicardError {
            throw error
        } catch {
            throw PicardError.sessionWrite(path: url.path, reason: error.localizedDescription)
        }
    }

    private func replacementBaseline(from url: URL) throws -> SessionDocument? {
        do { return try load(from: url) }
        catch let error as PicardError {
            // A supported recovered document may replace a corrupt primary,
            // but an archive from a newer app must never be downgraded.
            if case .invalidConfiguration = error { throw error }
            return nil
        } catch { return nil }
    }

    private func blobStore(for url: URL) -> ArtworkBlobStore {
        let directory = url.deletingLastPathComponent().appendingPathComponent("ArtworkBlobs", isDirectory: true)
        if let store = blobStores[directory] { return store }
        let store = ArtworkBlobStore(directory: directory)
        blobStores[directory] = store
        return store
    }
}

private extension JSONEncoder {
    static func makeSessionEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static func makeSessionDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
