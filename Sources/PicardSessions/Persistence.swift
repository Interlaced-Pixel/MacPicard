import Foundation
import PicardFormats
import PicardFoundation
import PicardScripts

public enum SaveError: Error, LocalizedError, Sendable, Equatable {
    case externalModification(path: String)
    case collision(path: String)
    case duplicateDestination(path: String)
    case sourceMissing(path: String)
    case invalidName(String)
    case moveFailed(path: String, reason: String)
    case format(String)
    case session(String)
    case invalidInterval

    public var errorDescription: String? {
        switch self {
        case let .externalModification(path): return "The file changed outside MacPicard and was not overwritten: \(path)"
        case let .collision(path): return "The destination already exists: \(path)"
        case let .duplicateDestination(path): return "Multiple files resolve to the same destination: \(path)"
        case let .sourceMissing(path): return "The source file no longer exists: \(path)"
        case let .invalidName(message): return "Invalid file name: \(message)"
        case let .moveFailed(path, reason): return "Could not move \(path): \(reason)"
        case let .format(message): return "Audio save failed: \(message)"
        case let .session(message): return "Session operation failed: \(message)"
        case .invalidInterval: return "Autosave interval must be greater than zero."
        }
    }
}

public struct AudioSaveOptions: Codable, Sendable, Equatable {
    public let preserveModificationDate: Bool
    public let rejectExternalChanges: Bool

    public init(preserveModificationDate: Bool = true, rejectExternalChanges: Bool = true) {
        self.preserveModificationDate = preserveModificationDate
        self.rejectExternalChanges = rejectExternalChanges
    }
}

public actor AudioSaveCoordinator {
    private let coordinator: AudioFileCoordinator

    public init(coordinator: AudioFileCoordinator = AudioFileCoordinator()) {
        self.coordinator = coordinator
    }

    public func save(_ file: AudioFile, options: AudioSaveOptions = AudioSaveOptions()) async throws -> AudioFile {
        if options.rejectExternalChanges, let expectedIdentity = file.identity {
            let actualIdentity = try AudioFileIdentity.capture(url: file.url)
            guard actualIdentity.matches(expectedIdentity) else {
                throw SaveError.externalModification(path: file.url.path)
            }
        }

        do {
            return try await coordinator.save(
                file,
                options: FormatSaveOptions(preserveModificationDate: options.preserveModificationDate)
            )
        } catch let error as SaveError {
            throw error
        } catch {
            throw SaveError.format(error.localizedDescription)
        }
    }

    public func saveAll(
        _ files: [AudioFile],
        options: AudioSaveOptions = AudioSaveOptions(),
        progress: (@Sendable (Double) async -> Void)? = nil
    ) async throws -> [AudioFile] {
        var saved: [AudioFile] = []
        saved.reserveCapacity(files.count)
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            saved.append(try await save(file, options: options))
            await progress?(Double(index + 1) / Double(files.count))
        }
        return saved
    }
}

public enum FileCollisionPolicy: String, Codable, Sendable, CaseIterable {
    case fail
    case skip
    case overwrite
}

public struct FileMoveOperation: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let fileID: UUID
    public let source: URL
    public let destination: URL

    public init(id: UUID = UUID(), fileID: UUID, source: URL, destination: URL) {
        self.id = id
        self.fileID = fileID
        self.source = source
        self.destination = destination
    }
}

public struct FileMovePlan: Codable, Sendable, Equatable {
    public let operations: [FileMoveOperation]

    public init(operations: [FileMoveOperation]) {
        self.operations = operations
    }
}

public struct FileMoveReport: Codable, Sendable, Equatable {
    public let movedFileIDs: [UUID]
    public let skippedFileIDs: [UUID]
    public let destinations: [UUID: URL]

    public init(movedFileIDs: [UUID], skippedFileIDs: [UUID], destinations: [UUID: URL]) {
        self.movedFileIDs = movedFileIDs
        self.skippedFileIDs = skippedFileIDs
        self.destinations = destinations
    }
}

public actor FileOrganizationCoordinator {
    private let evaluator: ScriptEvaluator

    public init(evaluator: ScriptEvaluator = ScriptEvaluator()) {
        self.evaluator = evaluator
    }

    public func plan(
        files: [AudioFile],
        destinationDirectory: URL,
        namingScript: String
    ) throws -> FileMovePlan {
        var operations: [FileMoveOperation] = []
        for file in files {
            let context = ScriptContext(metadata: file.metadata, variables: [
                "filename": [file.url.deletingPathExtension().lastPathComponent],
                "extension": [file.url.pathExtension]
            ])
            let rendered: String
            do {
                rendered = try evaluator.evaluate(namingScript, context: context).output
            } catch {
                throw SaveError.invalidName(error.localizedDescription)
            }
            let destination = try Self.destinationURL(
                rendered: rendered,
                originalURL: file.url,
                root: destinationDirectory
            )
            operations.append(FileMoveOperation(fileID: file.id, source: file.url, destination: destination))
        }

        let destinations = operations.map(\.destination.path)
        guard Set(destinations).count == destinations.count else {
            let duplicate = destinations.first { path in destinations.filter { $0 == path }.count > 1 } ?? ""
            throw SaveError.duplicateDestination(path: duplicate)
        }
        return FileMovePlan(operations: operations)
    }

    public func execute(
        _ plan: FileMovePlan,
        collisionPolicy: FileCollisionPolicy = .fail
    ) throws -> FileMoveReport {
        let fileManager = FileManager.default
        let sourcePaths = Set(plan.operations.map { $0.source.standardizedFileURL.path })
        var active: [FileMoveOperation] = []
        var skipped: [UUID] = []

        for operation in plan.operations {
            guard fileManager.fileExists(atPath: operation.source.path) else {
                throw SaveError.sourceMissing(path: operation.source.path)
            }
            if operation.source.standardizedFileURL == operation.destination.standardizedFileURL {
                skipped.append(operation.fileID)
                continue
            }
            if fileManager.fileExists(atPath: operation.destination.path), !sourcePaths.contains(operation.destination.standardizedFileURL.path) {
                switch collisionPolicy {
                case .fail: throw SaveError.collision(path: operation.destination.path)
                case .skip:
                    skipped.append(operation.fileID)
                    continue
                case .overwrite: break
                }
            }
            active.append(operation)
        }

        var temporaryLocations: [(operation: FileMoveOperation, temporary: URL)] = []
        var completedMoves: [FileMoveOperation] = []
        var backups: [(destination: URL, backup: URL)] = []
        do {
            if collisionPolicy == .overwrite {
                for operation in active where fileManager.fileExists(atPath: operation.destination.path)
                    && !sourcePaths.contains(operation.destination.standardizedFileURL.path) {
                    let backup = operation.destination.deletingLastPathComponent().appendingPathComponent(
                        ".macpicard-backup-\(UUID().uuidString)"
                    )
                    try fileManager.moveItem(at: operation.destination, to: backup)
                    backups.append((operation.destination, backup))
                }
            }

            for operation in active {
                let temporary = operation.source.deletingLastPathComponent().appendingPathComponent(
                    ".macpicard-move-\(UUID().uuidString)"
                )
                try fileManager.moveItem(at: operation.source, to: temporary)
                temporaryLocations.append((operation, temporary))
            }

            var moved: [UUID] = []
            var destinations: [UUID: URL] = [:]
            for (operation, temporary) in temporaryLocations {
                if fileManager.fileExists(atPath: operation.destination.path) {
                    if collisionPolicy == .overwrite {
                        try fileManager.removeItem(at: operation.destination)
                    } else {
                        throw SaveError.collision(path: operation.destination.path)
                    }
                }
                try fileManager.createDirectory(at: operation.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.moveItem(at: temporary, to: operation.destination)
                completedMoves.append(operation)
                moved.append(operation.fileID)
                destinations[operation.fileID] = operation.destination
            }
            for backup in backups { try? fileManager.removeItem(at: backup.backup) }
            return FileMoveReport(movedFileIDs: moved, skippedFileIDs: skipped, destinations: destinations)
        } catch let error as SaveError {
            rollback(completedMoves: completedMoves, temporaryLocations: temporaryLocations, backups: backups, fileManager: fileManager)
            throw error
        } catch {
            rollback(completedMoves: completedMoves, temporaryLocations: temporaryLocations, backups: backups, fileManager: fileManager)
            throw SaveError.moveFailed(path: active.first?.source.path ?? "", reason: error.localizedDescription)
        }
    }

    public func organize(
        files: [AudioFile],
        destinationDirectory: URL,
        namingScript: String,
        collisionPolicy: FileCollisionPolicy = .fail
    ) throws -> [AudioFile] {
        let plan = try plan(files: files, destinationDirectory: destinationDirectory, namingScript: namingScript)
        let report = try execute(plan, collisionPolicy: collisionPolicy)
        return try files.map { file in
            guard let destination = report.destinations[file.id] else { return file }
            var updated = file
            try updated.updateURL(destination)
            return updated
        }
    }

    private static func destinationURL(rendered: String, originalURL: URL, root: URL) throws -> URL {
        let raw = rendered.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw SaveError.invalidName("The naming script produced an empty path.") }
        let normalized = raw.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.hasPrefix("/"), !normalized.contains(":") else {
            throw SaveError.invalidName("Absolute paths and volume-qualified paths are not allowed.")
        }

        var components: [String] = []
        for component in normalized.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            guard component != ".", component != ".." else { throw SaveError.invalidName("Path traversal is not allowed.") }
            let sanitized = component.unicodeScalars.filter { scalar in
                scalar.value >= 0x20 && !CharacterSet(charactersIn: "/\\:").contains(scalar)
            }
            let value = String(String.UnicodeScalarView(sanitized)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { throw SaveError.invalidName("A path component is empty.") }
            components.append(value)
        }
        guard !components.isEmpty else { throw SaveError.invalidName("The naming script produced no path components.") }

        var filename = components.removeLast()
        if URL(fileURLWithPath: filename).pathExtension.isEmpty {
            filename += ".\(originalURL.pathExtension)"
        }
        components.append(filename)
        return components.dropLast().reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
            .appendingPathComponent(components.last!)
    }

    private func rollback(
        completedMoves: [FileMoveOperation],
        temporaryLocations: [(operation: FileMoveOperation, temporary: URL)],
        backups: [(destination: URL, backup: URL)],
        fileManager: FileManager
    ) {
        for operation in completedMoves.reversed() {
            if fileManager.fileExists(atPath: operation.destination.path) {
                try? fileManager.moveItem(at: operation.destination, to: operation.source)
            }
        }
        for (operation, temporary) in temporaryLocations.reversed() {
            if fileManager.fileExists(atPath: temporary.path) {
                try? fileManager.moveItem(at: temporary, to: operation.source)
            }
        }
        for backup in backups.reversed() {
            if fileManager.fileExists(atPath: backup.backup.path) {
                try? fileManager.moveItem(at: backup.backup, to: backup.destination)
            }
        }
    }
}

public struct PicardProfile: Codable, Sendable, Equatable, Identifiable {
    public static let currentSchemaVersion = 1

    public let id: UUID
    public var schemaVersion: Int
    public var name: String
    public var preferredReleaseCountry: String
    public var namingScript: String
    public var destinationDirectory: URL?
    public var collisionPolicy: FileCollisionPolicy
    public var preserveFileTimestamps: Bool
    public var automaticCoverArt: Bool
    public var customVariables: [String: [String]]
    public let createdAt: Date
    public var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case schemaVersion
        case name
        case preferredReleaseCountry
        case namingScript
        case destinationDirectory
        case collisionPolicy
        case preserveFileTimestamps
        case automaticCoverArt
        case customVariables
        case createdAt
        case updatedAt
    }

    public init(
        id: UUID = UUID(),
        schemaVersion: Int = PicardProfile.currentSchemaVersion,
        name: String,
        preferredReleaseCountry: String = "US",
        namingScript: String = "%artist%/%album%/%tracknumber% - %title%",
        destinationDirectory: URL? = nil,
        collisionPolicy: FileCollisionPolicy = .fail,
        preserveFileTimestamps: Bool = true,
        automaticCoverArt: Bool = true,
        customVariables: [String: [String]] = [:],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.name = name
        self.preferredReleaseCountry = preferredReleaseCountry
        self.namingScript = namingScript
        self.destinationDirectory = destinationDirectory
        self.collisionPolicy = collisionPolicy
        self.preserveFileTimestamps = preserveFileTimestamps
        self.automaticCoverArt = automaticCoverArt
        self.customVariables = customVariables
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            schemaVersion: try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion,
            name: try container.decodeIfPresent(String.self, forKey: .name) ?? "Imported Profile",
            preferredReleaseCountry: try container.decodeIfPresent(String.self, forKey: .preferredReleaseCountry) ?? "US",
            namingScript: try container.decodeIfPresent(String.self, forKey: .namingScript) ?? "%artist%/%album%/%tracknumber% - %title%",
            destinationDirectory: try container.decodeIfPresent(URL.self, forKey: .destinationDirectory),
            collisionPolicy: try container.decodeIfPresent(FileCollisionPolicy.self, forKey: .collisionPolicy) ?? .fail,
            preserveFileTimestamps: try container.decodeIfPresent(Bool.self, forKey: .preserveFileTimestamps) ?? true,
            automaticCoverArt: try container.decodeIfPresent(Bool.self, forKey: .automaticCoverArt) ?? true,
            customVariables: try container.decodeIfPresent([String: [String]].self, forKey: .customVariables) ?? [:],
            createdAt: createdAt,
            updatedAt: try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        )
    }
}

public enum ProfileMigrator {
    public static func migrate(_ data: Data) throws -> Data {
        do {
            guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SaveError.session("Profile root JSON value must be an object.")
            }
            let version = object["schemaVersion"] as? Int ?? 0
            guard version <= PicardProfile.currentSchemaVersion else {
                throw SaveError.session("Profile schema version \(version) is newer than this application supports.")
            }
            if version == 0 { object["schemaVersion"] = PicardProfile.currentSchemaVersion }
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        } catch let error as SaveError {
            throw error
        } catch {
            throw SaveError.session(error.localizedDescription)
        }
    }
}

public actor ProfileStore {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func list() throws -> [PicardProfile] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        return try urls.compactMap { try load(from: $0) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func load(id: UUID) throws -> PicardProfile? {
        try load(from: fileURL(for: id))
    }

    public func save(_ profile: PicardProfile) throws {
        guard profile.schemaVersion <= PicardProfile.currentSchemaVersion else {
            throw SaveError.session("Profile schema version is unsupported.")
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(profile).write(to: fileURL(for: profile.id), options: [.atomic])
        } catch {
            throw SaveError.session(error.localizedDescription)
        }
    }

    public func remove(id: UUID) throws {
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do { try FileManager.default.removeItem(at: url) } catch { throw SaveError.session(error.localizedDescription) }
    }

    public func export(_ profile: PicardProfile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do { return try encoder.encode(profile) } catch { throw SaveError.session(error.localizedDescription) }
    }

    public func `import`(_ data: Data, replacingID: UUID? = nil) throws -> PicardProfile {
        let migrated = try ProfileMigrator.migrate(data)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        do {
            var profile = try decoder.decode(PicardProfile.self, from: migrated)
            if let replacingID { profile = PicardProfile(id: replacingID, schemaVersion: profile.schemaVersion, name: profile.name, preferredReleaseCountry: profile.preferredReleaseCountry, namingScript: profile.namingScript, destinationDirectory: profile.destinationDirectory, collisionPolicy: profile.collisionPolicy, preserveFileTimestamps: profile.preserveFileTimestamps, automaticCoverArt: profile.automaticCoverArt, customVariables: profile.customVariables, createdAt: profile.createdAt, updatedAt: Date()) }
            try save(profile)
            return profile
        } catch let error as SaveError {
            throw error
        } catch {
            throw SaveError.session(error.localizedDescription)
        }
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    private func load(from url: URL) throws -> PicardProfile? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let migrated = try ProfileMigrator.migrate(data)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            return try decoder.decode(PicardProfile.self, from: migrated)
        } catch let error as SaveError {
            throw error
        } catch {
            throw SaveError.session(error.localizedDescription)
        }
    }
}

public actor SessionAutosave {
    private let store: SessionStore
    private var task: Task<Void, Never>?

    public init(store: SessionStore) {
        self.store = store
    }

    public func saveRecovery(_ document: SessionDocument) async throws {
        try await store.saveRecovery(document)
    }

    public func start(
        interval: Duration,
        provider: @escaping @Sendable () async throws -> SessionDocument
    ) throws {
        guard interval > .zero else { throw SaveError.invalidInterval }
        stop()
        let store = self.store
        task = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                    guard !Task.isCancelled else { break }
                    let document = try await provider()
                    try await store.saveRecovery(document)
                } catch is CancellationError {
                    break
                } catch {
                    continue
                }
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

}

public struct LoadedSession: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable { case primary, recovery }
    public let document: SessionDocument
    public let source: Source

    public init(document: SessionDocument, source: Source) {
        self.document = document
        self.source = source
    }
}

public actor SessionManager {
    private let store: SessionStore
    private let autosave: SessionAutosave

    public init(store: SessionStore) {
        self.store = store
        self.autosave = SessionAutosave(store: store)
    }

    public func loadBestAvailable() async throws -> LoadedSession? {
        let primary = try await store.load()
        let recovery = try await store.loadRecovery()
        switch (primary, recovery) {
        case (nil, nil): return nil
        case let (document?, nil): return LoadedSession(document: document, source: .primary)
        case let (nil, document?): return LoadedSession(document: document, source: .recovery)
        case let (primary?, recovery?):
            return recovery.savedAt > primary.savedAt
                ? LoadedSession(document: recovery, source: .recovery)
                : LoadedSession(document: primary, source: .primary)
        }
    }

    public func save(_ document: SessionDocument) async throws {
        try await store.save(document)
    }

    public func saveRecovery(_ document: SessionDocument) async throws {
        try await store.saveRecovery(document)
    }

    public func acceptRecovery() async throws {
        guard let recovery = try await store.loadRecovery() else { return }
        try await store.save(recovery)
        try await store.removeRecovery()
    }

    public func discardRecovery() async throws {
        try await store.removeRecovery()
    }

    public func startAutosave(interval: Duration, provider: @escaping @Sendable () async throws -> SessionDocument) async throws {
        try await autosave.start(interval: interval, provider: provider)
    }

    public func stopAutosave() async {
        await autosave.stop()
    }
}
