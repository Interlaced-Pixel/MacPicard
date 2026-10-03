import Foundation

public struct AppConfiguration: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    public static let defaultUserAgent = "MacPicard/0.1.0 (https://github.com/Interlaced-Pixel)"

    public var schemaVersion: Int
    public var preferredReleaseCountry: String
    public var requestUserAgent: String
    public var preserveFileTimestamps: Bool
    public var automaticCoverArt: Bool
    public var autosaveEnabled: Bool
    public var autosaveIntervalSeconds: Int

    public init(
        schemaVersion: Int = AppConfiguration.currentSchemaVersion,
        preferredReleaseCountry: String = "US",
        requestUserAgent: String = AppConfiguration.defaultUserAgent,
        preserveFileTimestamps: Bool = true,
        automaticCoverArt: Bool = true,
        autosaveEnabled: Bool = true,
        autosaveIntervalSeconds: Int = 60
    ) {
        self.schemaVersion = schemaVersion
        self.preferredReleaseCountry = preferredReleaseCountry
        let agent = requestUserAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        self.requestUserAgent = agent.isEmpty || agent == "MacPicard/0.1.0" ? Self.defaultUserAgent : agent
        self.preserveFileTimestamps = preserveFileTimestamps
        self.automaticCoverArt = automaticCoverArt
        self.autosaveEnabled = autosaveEnabled
        self.autosaveIntervalSeconds = autosaveIntervalSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case preferredReleaseCountry
        case requestUserAgent
        case preserveFileTimestamps
        case automaticCoverArt
        case autosaveEnabled
        case autosaveIntervalSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaVersion: try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
                ?? AppConfiguration.currentSchemaVersion,
            preferredReleaseCountry: try container.decodeIfPresent(String.self, forKey: .preferredReleaseCountry)
                ?? "US",
            requestUserAgent: try container.decodeIfPresent(String.self, forKey: .requestUserAgent)
                ?? AppConfiguration.defaultUserAgent,
            preserveFileTimestamps: try container.decodeIfPresent(Bool.self, forKey: .preserveFileTimestamps)
                ?? true,
            automaticCoverArt: try container.decodeIfPresent(Bool.self, forKey: .automaticCoverArt)
                ?? true,
            autosaveEnabled: try container.decodeIfPresent(Bool.self, forKey: .autosaveEnabled)
                ?? true,
            autosaveIntervalSeconds: try container.decodeIfPresent(Int.self, forKey: .autosaveIntervalSeconds)
                ?? 60
        )
    }
}

public enum ConfigurationMigrator {
    public static func migrate(_ data: Data) throws -> Data {
        let object: Any

        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw PicardError.configurationEncoding(error.localizedDescription)
        }

        guard var dictionary = object as? [String: Any] else {
            throw PicardError.invalidConfiguration("The root JSON value must be an object.")
        }

        let sourceVersion = dictionary["schemaVersion"] as? Int ?? 0

        guard sourceVersion <= AppConfiguration.currentSchemaVersion else {
            throw PicardError.unsupportedConfigurationVersion(sourceVersion)
        }

        var version = sourceVersion
        while version < AppConfiguration.currentSchemaVersion {
            switch version {
            case 0:
                dictionary["schemaVersion"] = 1
                version = 1
            default:
                throw PicardError.migrationFailed(
                    from: version,
                    to: AppConfiguration.currentSchemaVersion,
                    reason: "No migration exists for this schema version."
                )
            }
        }

        do {
            return try JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys])
        } catch {
            throw PicardError.configurationEncoding(error.localizedDescription)
        }
    }
}

public actor ConfigurationStore {
    private let fileURL: URL
    private var cachedConfiguration: AppConfiguration?

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> AppConfiguration {
        if let cachedConfiguration {
            return cachedConfiguration
        }

        let configuration: AppConfiguration

        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data: Data

            do {
                data = try Data(contentsOf: fileURL)
            } catch {
                throw PicardError.configurationRead(path: fileURL.path, reason: error.localizedDescription)
            }

            let migratedData = try ConfigurationMigrator.migrate(data)

            do {
                configuration = try JSONDecoder().decode(AppConfiguration.self, from: migratedData)
            } catch {
                throw PicardError.invalidConfiguration(error.localizedDescription)
            }

            if migratedData != data {
                try write(migratedData)
            }
        } else {
            configuration = AppConfiguration()
            try save(configuration)
        }

        cachedConfiguration = configuration
        return configuration
    }

    public func save(_ configuration: AppConfiguration) throws {
        guard configuration.schemaVersion <= AppConfiguration.currentSchemaVersion else {
            throw PicardError.unsupportedConfigurationVersion(configuration.schemaVersion)
        }

        do {
            let data = try JSONEncoder.makeStableEncoder().encode(configuration)
            try write(data)
        } catch let error as PicardError {
            throw error
        } catch {
            throw PicardError.configurationEncoding(error.localizedDescription)
        }

        cachedConfiguration = configuration
    }

    @discardableResult
    public func update(_ body: @Sendable (inout AppConfiguration) -> Void) throws -> AppConfiguration {
        var configuration = try load()
        body(&configuration)
        try save(configuration)
        return configuration
    }

    @discardableResult
    public func reset() throws -> AppConfiguration {
        let configuration = AppConfiguration()
        try save(configuration)
        return configuration
    }

    private func write(_ data: Data) throws {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            throw PicardError.configurationWrite(path: fileURL.path, reason: error.localizedDescription)
        }
    }
}

private extension JSONEncoder {
    static func makeStableEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
