import Foundation
import PicardFoundation

public enum WorkflowFailure: Error, LocalizedError, Sendable {
    case invalid(String)
    public var errorDescription: String? { switch self { case let .invalid(message): message } }
}

public struct ManagedScript: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case tagging, naming }
    public var id: UUID
    public var name: String
    public var kind: Kind
    public var enabled: Bool
    public var source: String
    public init(id: UUID = UUID(), name: String, kind: Kind = .tagging, enabled: Bool = true, source: String) {
        self.id = id; self.name = name; self.kind = kind; self.enabled = enabled; self.source = source
    }
}

/// A whitelist, not an entire app configuration. Credentials, workspaces, paths and UI state are never captured.
public enum ProfileOption: String, Codable, Sendable, CaseIterable, Identifiable {
    case matching, naming, tagging, artwork, timestamps
    public var id: String { rawValue }
}

public struct WorkflowProfile: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var included: Set<ProfileOption>
    public var country: String
    public var threshold: Double
    public var preservedTags: [String]
    public var naming: String
    public var tagging: String
    public var automaticArtwork: Bool
    public var artworkSize: String
    public var replaceCover: Bool
    public var maximumPixels: Int
    public var format: String
    public var quality: Double
    public var embed: Bool
    public var preserveTimestamps: Bool

    public init(id: UUID = UUID(), name: String, included: Set<ProfileOption> = Set(ProfileOption.allCases), configuration: AppConfiguration) {
        self.id = id; self.name = name; self.included = included
        country = configuration.preferredReleaseCountry; threshold = configuration.editing.matchThreshold
        preservedTags = configuration.editing.preservedTags; naming = configuration.editing.namingPattern
        tagging = configuration.editing.defaultTagScript; automaticArtwork = configuration.automaticCoverArt
        artworkSize = configuration.editing.coverArtSize; replaceCover = configuration.editing.replaceFrontCover
        maximumPixels = configuration.editing.artworkMaximumPixels; format = configuration.editing.artworkOutputFormat
        quality = configuration.editing.artworkJPEGQuality; embed = configuration.editing.embedImportedArtwork
        preserveTimestamps = configuration.preserveFileTimestamps
    }

    public func applying(to current: AppConfiguration) throws -> AppConfiguration {
        var value = current
        if included.contains(.matching) {
            value.preferredReleaseCountry = country; value.editing.matchThreshold = threshold
            value.editing.preservedTags = preservedTags
        }
        if included.contains(.naming) { value.editing.namingPattern = naming }
        if included.contains(.tagging) { value.editing.defaultTagScript = tagging }
        if included.contains(.artwork) {
            value.automaticCoverArt = automaticArtwork; value.editing.coverArtSize = artworkSize
            value.editing.replaceFrontCover = replaceCover; value.editing.artworkMaximumPixels = maximumPixels
            value.editing.artworkOutputFormat = format; value.editing.artworkJPEGQuality = quality
            value.editing.embedImportedArtwork = embed
        }
        if included.contains(.timestamps) { value.preserveFileTimestamps = preserveTimestamps }
        try value.validate()
        _ = try ScriptParser().parse(value.editing.namingPattern)
        _ = try ScriptParser().parse(value.editing.defaultTagScript)
        return value
    }
}

public struct WorkflowDocument: Codable, Sendable, Equatable {
    public var schemaVersion = 1
    public var scripts: [ManagedScript] = []
    public var profiles: [WorkflowProfile] = []
    public init() {}
    public func validate() throws {
        guard schemaVersion == 1, scripts.count <= 200, profiles.count <= 100,
              Set(scripts.map(\.id)).count == scripts.count, Set(profiles.map(\.id)).count == profiles.count else {
            throw WorkflowFailure.invalid("Unsupported workflow version, duplicate identities, or excessive item count.")
        }
        for name in scripts.map(\.name) + profiles.map(\.name) {
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 120 else {
                throw WorkflowFailure.invalid("Give every script/profile a name of 1–120 characters.")
            }
        }
        for script in scripts {
            guard script.source.utf8.count <= 64 * 1024 else { throw WorkflowFailure.invalid("Scripts are limited to 64 KiB.") }
            _ = try ScriptParser().parse(script.source)
        }
        for profile in profiles { _ = try profile.applying(to: AppConfiguration()) }
    }
    public func exported() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= 2 * 1024 * 1024 else { throw WorkflowFailure.invalid("Workflow documents are limited to 2 MiB.") }
        return data
    }
    public static func imported(_ data: Data) throws -> Self {
        guard data.count <= 2 * 1024 * 1024 else { throw WorkflowFailure.invalid("Workflow documents are limited to 2 MiB.") }
        let document = try JSONDecoder().decode(Self.self, from: data); try document.validate(); return document
    }
    public mutating func merge(_ other: Self) throws {
        try other.validate()
        var value = self
        for var item in other.scripts { item.id = UUID(); value.scripts.append(item) }
        for var item in other.profiles { item.id = UUID(); value.profiles.append(item) }
        try value.validate(); self = value
    }
}

public actor WorkflowStore {
    public nonisolated let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> WorkflowDocument {
        guard FileManager.default.fileExists(atPath: url.path) else { return WorkflowDocument() }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        return try WorkflowDocument.imported(handle.read(upToCount: 2 * 1024 * 1024 + 1) ?? Data())
    }
    public func save(_ value: WorkflowDocument) throws {
        let data = try value.exported(); try Task.checkCancellation()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
