import CryptoKit
import Foundation

public enum AudioFileState: String, Codable, Sendable, Equatable {
    case discovered
    case loading
    case ready
    case changed
    case saving
    case saved
    case failed
    case removed
    case unsupported
}

public struct AudioFileIdentity: Codable, Sendable, Equatable {
    public let resourceIdentifier: String?
    public let byteCount: Int64
    public let modificationDate: Date?
    public let prefixHash: String

    public init(
        resourceIdentifier: String?,
        byteCount: Int64,
        modificationDate: Date?,
        prefixHash: String
    ) {
        self.resourceIdentifier = resourceIdentifier
        self.byteCount = byteCount
        self.modificationDate = modificationDate
        self.prefixHash = prefixHash
    }

    /// JSON dates cross two floating-point epochs. Allow only that representation
    /// error, not filesystem-scale timestamp changes; all other identity fields
    /// must still match exactly. Equatable retains its exact value semantics.
    public func matches(_ other: AudioFileIdentity?) -> Bool {
        guard let other, resourceIdentifier == other.resourceIdentifier,
              byteCount == other.byteCount, prefixHash == other.prefixHash else { return false }
        switch (modificationDate, other.modificationDate) {
        case (nil, nil): return true
        case let (actual?, expected?):
            let precision = 2 * max(actual.timeIntervalSince1970.ulp, expected.timeIntervalSince1970.ulp)
            return abs(actual.timeIntervalSince(expected)) <= precision
        default: return false
        }
    }

    public static func capture(url: URL, prefixByteCount: Int = 8_192) throws -> AudioFileIdentity {
        let resourceValues: URLResourceValues

        do {
            resourceValues = try url.resourceValues(forKeys: [
                .fileResourceIdentifierKey,
                .fileSizeKey,
                .contentModificationDateKey,
                .isRegularFileKey
            ])
        } catch {
            throw PicardError.fileSystem(
                path: url.path,
                operation: "read file identity",
                reason: error.localizedDescription
            )
        }

        guard resourceValues.isRegularFile == true else {
            throw PicardError.fileSystem(
                path: url.path,
                operation: "read file identity",
                reason: "The URL is not a regular file."
            )
        }

        guard let byteCount = resourceValues.fileSize else {
            throw PicardError.fileSystem(
                path: url.path,
                operation: "read file identity",
                reason: "The file size is unavailable."
            )
        }

        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            data = try handle.read(upToCount: prefixByteCount) ?? Data()
        } catch {
            throw PicardError.fileSystem(
                path: url.path,
                operation: "hash file identity",
                reason: error.localizedDescription
            )
        }

        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let resourceIdentifier = (resourceValues.fileResourceIdentifier as? NSObject)?.description

        return AudioFileIdentity(
            resourceIdentifier: resourceIdentifier,
            byteCount: Int64(byteCount),
            modificationDate: resourceValues.contentModificationDate,
            prefixHash: hash
        )
    }
}

public struct AudioFile: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public private(set) var url: URL
    public private(set) var state: AudioFileState
    public private(set) var identity: AudioFileIdentity?
    public private(set) var originalMetadata: Metadata
    public private(set) var metadata: Metadata
    public private(set) var originalArtwork: ArtworkCollection
    public private(set) var artwork: ArtworkCollection
    public private(set) var lastError: String?

    public init(id: UUID = UUID(), url: URL) {
        self.id = id
        self.url = url
        self.state = .discovered
        self.identity = nil
        self.originalMetadata = Metadata()
        self.metadata = Metadata()
        self.originalArtwork = ArtworkCollection()
        self.artwork = ArtworkCollection()
        self.lastError = nil
    }

    public var metadataDiff: MetadataDiff {
        metadata.difference(from: originalMetadata)
    }

    public var isModified: Bool {
        !metadataDiff.isEmpty || artwork != originalArtwork
    }

    public mutating func beginLoading() throws {
        try requireState([.discovered, .failed], operation: "begin loading")
        state = .loading
        lastError = nil
    }

    public mutating func finishLoading(
        metadata: Metadata,
        artwork: ArtworkCollection = ArtworkCollection(),
        identity: AudioFileIdentity
    ) throws {
        try requireState([.loading], operation: "finish loading")
        self.originalMetadata = metadata
        self.metadata = metadata
        self.originalArtwork = artwork
        self.artwork = artwork
        self.identity = identity
        self.state = .ready
        self.lastError = nil
    }

    public mutating func updateMetadata(_ metadata: Metadata) throws {
        try requireState([.ready, .changed, .saved], operation: "update metadata")
        self.metadata = metadata
        state = metadataDiff.isEmpty && artwork == originalArtwork ? .ready : .changed
        lastError = nil
    }

    public mutating func updateArtwork(_ artwork: ArtworkCollection) throws {
        try requireState([.ready, .changed, .saved], operation: "update artwork")
        self.artwork = artwork
        state = metadataDiff.isEmpty && artwork == originalArtwork ? .ready : .changed
        lastError = nil
    }

    public mutating func updateURL(_ url: URL) throws {
        try requireState([.discovered, .ready, .changed, .saved, .removed, .failed], operation: "update file location")
        self.url = url
    }

    public mutating func beginSaving() throws {
        try requireState([.ready, .changed, .saved], operation: "begin saving")
        state = .saving
        lastError = nil
    }

    public mutating func finishSaving(identity: AudioFileIdentity) throws {
        try requireState([.saving], operation: "finish saving")
        originalMetadata = metadata
        originalArtwork = artwork
        self.identity = identity
        state = .saved
        lastError = nil
    }

    public mutating func markFailure(_ error: Error) {
        state = .failed
        lastError = error.localizedDescription
    }

    public mutating func markRemoved() {
        state = .removed
    }

    public mutating func restoreAvailability() throws {
        try requireState([.removed, .failed], operation: "restore file availability")
        guard identity != nil else {
            throw PicardError.invalidState(entity: "audio file", state: state.rawValue,
                                           operation: "restore a file that has not been loaded")
        }
        state = isModified ? .changed : .ready
        lastError = nil
    }

    public mutating func markUnsupported(_ reason: String) {
        state = .unsupported
        lastError = reason
    }

    public func sessionRecord() -> AudioFileSessionRecord {
        AudioFileSessionRecord(
            id: id,
            url: url,
            state: state,
            identity: identity,
            originalMetadata: originalMetadata,
            metadata: metadata,
            originalArtwork: originalArtwork,
            artwork: artwork,
            lastError: lastError
        )
    }

    public static func restore(from record: AudioFileSessionRecord) -> AudioFile {
        var file = AudioFile(id: record.id, url: record.url)
        file.state = record.state == .saving ? .changed : record.state
        file.identity = record.identity
        file.originalMetadata = record.originalMetadata
        file.metadata = record.metadata
        file.originalArtwork = record.originalArtwork
        file.artwork = record.artwork
        file.lastError = record.lastError
        return file
    }

    private func requireState(_ allowedStates: Set<AudioFileState>, operation: String) throws {
        guard allowedStates.contains(state) else {
            throw PicardError.invalidState(
                entity: "audio file",
                state: state.rawValue,
                operation: operation
            )
        }
    }
}

public struct AudioFileSessionRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let url: URL
    public let state: AudioFileState
    public let identity: AudioFileIdentity?
    public let originalMetadata: Metadata
    public let metadata: Metadata
    public let originalArtwork: ArtworkCollection
    public let artwork: ArtworkCollection
    public let lastError: String?

    public init(
        id: UUID,
        url: URL,
        state: AudioFileState,
        identity: AudioFileIdentity?,
        originalMetadata: Metadata,
        metadata: Metadata,
        originalArtwork: ArtworkCollection,
        artwork: ArtworkCollection,
        lastError: String?
    ) {
        self.id = id
        self.url = url
        self.state = state
        self.identity = identity
        self.originalMetadata = originalMetadata
        self.metadata = metadata
        self.originalArtwork = originalArtwork
        self.artwork = artwork
        self.lastError = lastError
    }
}
