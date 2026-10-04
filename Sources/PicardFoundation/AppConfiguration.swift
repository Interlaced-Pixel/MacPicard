import Foundation

public struct AppConfiguration: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 2
    public static let defaultUserAgent = "MacPicard/0.1.0 (https://github.com/Interlaced-Pixel)"

    public var schemaVersion: Int
    public var preferredReleaseCountry: String
    public var requestUserAgent: String
    public var preserveFileTimestamps: Bool
    public var automaticCoverArt: Bool
    public var autosaveEnabled: Bool
    public var autosaveIntervalSeconds: Int
    public var editing = EditingPreferences()

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
        case editing
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
        editing = try container.decodeIfPresent(EditingPreferences.self, forKey: .editing) ?? EditingPreferences()
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
            case 1:
                dictionary["schemaVersion"] = 2
                version = 2
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
        try configuration.validate()
        guard configuration.schemaVersion <= AppConfiguration.currentSchemaVersion else {
            throw PicardError.unsupportedConfigurationVersion(configuration.schemaVersion)
        }

        do {
            let encoded = try JSONEncoder.makeStableEncoder().encode(configuration)
            // Preserve future/vendor keys, including nested preferences, across edits.
            var known = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
            if let old = try? Data(contentsOf: fileURL),
               let original = try? JSONSerialization.jsonObject(with: old) as? [String: Any] {
                known = Self.merge(original, with: known)
            }
            let data = try JSONSerialization.data(withJSONObject: known, options: [.prettyPrinted, .sortedKeys])
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

    private static func merge(_ original: [String: Any], with known: [String: Any]) -> [String: Any] {
        var result = original
        for (key, value) in known {
            if let previous = original[key] as? [String: Any], let current = value as? [String: Any] {
                result[key] = merge(previous, with: current)
            } else { result[key] = value }
        }
        return result
    }
}

public struct EditingPreferences: Codable, Sendable, Equatable {
    public var matchThreshold: Double = 0.85
    public var preservedTags: [String] = []
    public var coverArtSize: String = "1200"
    public var replaceFrontCover: Bool = true
    public var artworkMaximumPixels: Int = 1200
    public var artworkOutputFormat: String = "preserve"
    public var artworkJPEGQuality: Double = 0.92
    public var embedImportedArtwork: Bool = true
    public var namingPattern: String = "$if2(%albumartist%,%artist%,Unknown Artist)/$if2(%album%,Unknown Album)/$if($gt(%totaldiscs%,1),$num(%discnumber%,1)-)$if(%tracknumber%,$num($if2(%tracknumber%,0),2) - )$if2(%title%,%filename%).%extension%"
    public var defaultTagScript: String = ""
    /// Legacy preference retained for decoding older workspaces; never used to select executable code.
    public var fpcalcPath: String = ""
    public var appearance: String = "system"
    public var monitoringIntervalSeconds: Int = 300
    public var newLibrariesMonitorAutomatically: Bool = true
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case matchThreshold, preservedTags, coverArtSize, replaceFrontCover, namingPattern
        case defaultTagScript, fpcalcPath, appearance, monitoringIntervalSeconds, newLibrariesMonitorAutomatically
        case artworkMaximumPixels, artworkOutputFormat, artworkJPEGQuality, embedImportedArtwork
    }
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        matchThreshold = try c.decodeIfPresent(Double.self, forKey: .matchThreshold) ?? matchThreshold
        preservedTags = try c.decodeIfPresent([String].self, forKey: .preservedTags) ?? preservedTags
        coverArtSize = try c.decodeIfPresent(String.self, forKey: .coverArtSize) ?? coverArtSize
        replaceFrontCover = try c.decodeIfPresent(Bool.self, forKey: .replaceFrontCover) ?? replaceFrontCover
        artworkMaximumPixels = try c.decodeIfPresent(Int.self, forKey: .artworkMaximumPixels) ?? artworkMaximumPixels
        artworkOutputFormat = try c.decodeIfPresent(String.self, forKey: .artworkOutputFormat) ?? artworkOutputFormat
        artworkJPEGQuality = try c.decodeIfPresent(Double.self, forKey: .artworkJPEGQuality) ?? artworkJPEGQuality
        embedImportedArtwork = try c.decodeIfPresent(Bool.self, forKey: .embedImportedArtwork) ?? embedImportedArtwork
        namingPattern = try c.decodeIfPresent(String.self, forKey: .namingPattern) ?? namingPattern
        defaultTagScript = try c.decodeIfPresent(String.self, forKey: .defaultTagScript) ?? defaultTagScript
        fpcalcPath = try c.decodeIfPresent(String.self, forKey: .fpcalcPath) ?? fpcalcPath
        appearance = try c.decodeIfPresent(String.self, forKey: .appearance) ?? appearance
        monitoringIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .monitoringIntervalSeconds) ?? monitoringIntervalSeconds
        newLibrariesMonitorAutomatically = try c.decodeIfPresent(Bool.self, forKey: .newLibrariesMonitorAutomatically) ?? newLibrariesMonitorAutomatically
    }
}

extension AppConfiguration {
    public func validate() throws {
        guard (1...ArtworkValidation.maximumSide).contains(editing.artworkMaximumPixels),
              ["preserve", "jpeg", "png"].contains(editing.artworkOutputFormat),
              editing.artworkJPEGQuality.isFinite, (0...1).contains(editing.artworkJPEGQuality) else {
            throw PicardError.invalidConfiguration("Invalid artwork conversion preferences.")
        }
        guard preferredReleaseCountry.isEmpty || preferredReleaseCountry.range(of: "^[A-Z]{2}$", options: .regularExpression) != nil else {
            throw PicardError.invalidConfiguration("Release country must be a two-letter uppercase country code, or empty for no preference.")
        }
        guard (15...3600).contains(autosaveIntervalSeconds),
              (60...3600).contains(editing.monitoringIntervalSeconds) else {
            throw PicardError.invalidConfiguration("Recovery interval must be 15–3600 seconds; monitoring must be 60–3600 seconds.")
        }
        guard editing.matchThreshold.isFinite, (0.60...0.95).contains(editing.matchThreshold),
              ["250", "500", "1200", "original"].contains(editing.coverArtSize),
              ["system", "light", "dark"].contains(editing.appearance) else {
            throw PicardError.invalidConfiguration("Invalid matching threshold, artwork size, or appearance.")
        }
        guard !editing.namingPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PicardError.invalidConfiguration("A naming pattern is required.")
        }
        guard !editing.preservedTags.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw PicardError.invalidConfiguration("Preserved tag names must not be empty.")
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
