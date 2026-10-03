import Foundation

public struct SessionDocument: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var createdAt: Date
    public var savedAt: Date
    public var files: [AudioFileSessionRecord]
    public var selectedFileIDs: [UUID]
    public var expandedNodeIDs: [UUID]
    public var selectedAlbumKey: String?
    public var accessBookmarkKeys: [String]

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
    }
}

public enum SessionMigrator {
    public static func migrate(_ data: Data) throws -> Data {
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

        var version = sourceVersion
        while version < SessionDocument.currentSchemaVersion {
            switch version {
            case 0:
                dictionary["schemaVersion"] = 1
                version = 1
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
    private let sessionURL: URL
    private let recoveryURL: URL

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
        guard FileManager.default.fileExists(atPath: recoveryURL.path) else {
            return
        }

        do {
            try FileManager.default.removeItem(at: recoveryURL)
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
            return try JSONDecoder.makeSessionDecoder().decode(SessionDocument.self, from: migratedData)
        } catch {
            throw PicardError.sessionEncoding(error.localizedDescription)
        }
    }

    private func write(_ document: SessionDocument, to url: URL) throws {
        guard document.schemaVersion <= SessionDocument.currentSchemaVersion else {
            throw PicardError.invalidConfiguration("Unsupported session schema version \(document.schemaVersion).")
        }

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder.makeSessionEncoder().encode(document)
            try data.write(to: url, options: [.atomic])
        } catch let error as PicardError {
            throw error
        } catch {
            throw PicardError.sessionWrite(path: url.path, reason: error.localizedDescription)
        }
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
