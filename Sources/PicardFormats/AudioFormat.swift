import Foundation
import PicardFoundation

public enum AudioFormat: String, Codable, Sendable, CaseIterable, Equatable {
    case mp3
    case flac
    case mp4
    case oggVorbis
    case oggOpus
    case wav

    public var displayName: String {
        switch self {
        case .mp3: return "MP3"
        case .flac: return "FLAC"
        case .mp4: return "M4A/MP4"
        case .oggVorbis: return "Ogg Vorbis"
        case .oggOpus: return "Ogg Opus"
        case .wav: return "WAV"
        }
    }

    public var fileExtensions: Set<String> {
        switch self {
        case .mp3: return ["mp3"]
        case .flac: return ["flac"]
        case .mp4: return ["m4a", "m4b", "mp4"]
        case .oggVorbis: return ["ogg", "oga"]
        case .oggOpus: return ["opus"]
        case .wav: return ["wav"]
        }
    }

    public var canonicalExtension: String {
        switch self {
        case .mp3: return "mp3"
        case .flac: return "flac"
        case .mp4: return "m4a"
        case .oggVorbis, .oggOpus: return "ogg"
        case .wav: return "wav"
        }
    }
}

public struct FormatAudioProperties: Codable, Sendable, Equatable {
    public let lengthInMilliseconds: Int
    public let bitrate: Int
    public let sampleRate: Int
    public let channels: Int
    public let bitsPerSample: Int?

    public init(
        lengthInMilliseconds: Int,
        bitrate: Int,
        sampleRate: Int,
        channels: Int,
        bitsPerSample: Int?
    ) {
        self.lengthInMilliseconds = lengthInMilliseconds
        self.bitrate = bitrate
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerSample = bitsPerSample
    }
}

public struct FormatReadResult: Sendable, Equatable {
    public let format: AudioFormat
    public let metadata: Metadata
    public let artwork: ArtworkCollection
    public let audioProperties: FormatAudioProperties?

    public init(
        format: AudioFormat,
        metadata: Metadata,
        artwork: ArtworkCollection,
        audioProperties: FormatAudioProperties?
    ) {
        self.format = format
        self.metadata = metadata
        self.artwork = artwork
        self.audioProperties = audioProperties
    }
}

public struct FormatWriteResult: Sendable, Equatable {
    public let format: AudioFormat
    public let writtenMetadataKeys: [String]
    public let writtenArtworkCount: Int

    public init(format: AudioFormat, writtenMetadataKeys: [String], writtenArtworkCount: Int) {
        self.format = format
        self.writtenMetadataKeys = writtenMetadataKeys
        self.writtenArtworkCount = writtenArtworkCount
    }
}

public struct FormatSaveOptions: Sendable, Equatable {
    public let preserveModificationDate: Bool
    public let verifyArtwork: Bool

    public init(preserveModificationDate: Bool = true, verifyArtwork: Bool = true) {
        self.preserveModificationDate = preserveModificationDate
        self.verifyArtwork = verifyArtwork
    }
}

public enum FormatError: Error, LocalizedError, Sendable, Equatable {
    case unsupportedFile(path: String)
    case unreadableFile(path: String, reason: String)
    case cannotOpen(path: String, format: AudioFormat)
    case cannotSave(path: String, format: AudioFormat, reason: String)
    case unsupportedMetadata(path: String, keys: [String])
    case artworkMissingData(path: String, artworkID: UUID)
    case artworkWriteRejected(path: String, format: AudioFormat)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedFile(path):
            return "Unsupported audio format: \(path)"
        case let .unreadableFile(path, reason):
            return "Could not read audio file \(path): \(reason)"
        case let .cannotOpen(path, format):
            return "Could not open \(format.displayName) file: \(path)"
        case let .cannotSave(path, format, reason):
            return "Could not save \(format.displayName) file \(path): \(reason)"
        case let .unsupportedMetadata(path, keys):
            return "The file format rejected metadata in \(path): \(keys.joined(separator: ", "))"
        case let .artworkMissingData(path, artworkID):
            return "Artwork \(artworkID.uuidString) has no image data and cannot be written to \(path)."
        case let .artworkWriteRejected(path, format):
            return "The \(format.displayName) file rejected embedded artwork: \(path)"
        }
    }
}

public struct FormatRegistry: Sendable {
    public static let supportedFormats: [AudioFormat] = AudioFormat.allCases

    public init() {}

    public func detect(url: URL) throws -> AudioFormat {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw FormatError.unreadableFile(path: url.path, reason: "The file is not readable.")
        }

        let header: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            header = try handle.read(upToCount: 8_192) ?? Data()
        } catch {
            throw FormatError.unreadableFile(path: url.path, reason: error.localizedDescription)
        }

        if let headerFormat = Self.detectHeader(header) {
            return headerFormat
        }

        let extensionName = url.pathExtension.lowercased()
        if let extensionFormat = Self.format(forExtension: extensionName) {
            return extensionFormat
        }

        throw FormatError.unsupportedFile(path: url.path)
    }

    public func handler(for format: AudioFormat) -> TagLibFormatHandler {
        TagLibFormatHandler(format: format)
    }

    public static func format(forExtension extensionName: String) -> AudioFormat? {
        let normalized = extensionName.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        return AudioFormat.allCases.first { $0.fileExtensions.contains(normalized) }
    }

    private static func detectHeader(_ data: Data) -> AudioFormat? {
        let bytes = [UInt8](data)

        if bytes.count >= 12,
           Array(bytes[0..<4]) == Array("RIFF".utf8),
           Array(bytes[8..<12]) == Array("WAVE".utf8) {
            return .wav
        }

        if bytes.count >= 12, Array(bytes[4..<8]) == Array("ftyp".utf8) {
            return .mp4
        }

        if bytes.count >= 4, Array(bytes[0..<4]) == Array("fLaC".utf8) {
            return .flac
        }

        if bytes.count >= 4, Array(bytes[0..<4]) == Array("OggS".utf8) {
            let marker = Array(bytes[0..<min(bytes.count, 8_192)])
            if containsSequence(marker, sequence: Array("OpusHead".utf8)) {
                return .oggOpus
            }
            return .oggVorbis
        }

        if bytes.count >= 3, Array(bytes[0..<3]) == Array("ID3".utf8) || containsMPEGFrameSync(bytes) {
            return .mp3
        }

        return nil
    }

    private static func containsSequence(_ bytes: [UInt8], sequence: [UInt8]) -> Bool {
        guard !sequence.isEmpty, bytes.count >= sequence.count else {
            return false
        }

        for index in 0...(bytes.count - sequence.count) {
            if Array(bytes[index..<(index + sequence.count)]) == sequence {
                return true
            }
        }

        return false
    }

    private static func containsMPEGFrameSync(_ bytes: [UInt8]) -> Bool {
        guard bytes.count > 1 else { return false }

        for index in 0..<(bytes.count - 1) {
            let first = bytes[index]
            let second = bytes[index + 1]
            guard first == 0xFF, (second & 0xE0) == 0xE0 else { continue }
            guard (second & 0x06) != 0 else { continue }
            return true
        }

        return false
    }
}

public actor FormatEngine {
    public let registry: FormatRegistry

    public init(registry: FormatRegistry = FormatRegistry()) {
        self.registry = registry
    }

    public func read(url: URL) throws -> FormatReadResult {
        let format = try registry.detect(url: url)
        return try registry.handler(for: format).read(url: url)
    }

    public func write(
        url: URL,
        metadata: Metadata,
        artwork: ArtworkCollection
    ) throws -> FormatWriteResult {
        let format = try registry.detect(url: url)
        return try registry.handler(for: format).write(url: url, metadata: metadata, artwork: artwork)
    }

    public func writeAtomically(
        url: URL,
        metadata: Metadata,
        artwork: ArtworkCollection,
        options: FormatSaveOptions = FormatSaveOptions()
    ) throws -> FormatWriteResult {
        let format = try registry.detect(url: url)
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        let temporaryName = ".\(url.deletingPathExtension().lastPathComponent).\(UUID().uuidString).\(url.pathExtension)"
        let temporaryURL = directory.appendingPathComponent(temporaryName)
        let originalIdentity = try AudioFileIdentity.capture(url: url)
        let originalDate = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        var targetURL = url

        do {
            try fileManager.copyItem(at: url, to: temporaryURL)
            let result = try registry.handler(for: format).write(
                url: temporaryURL, metadata: metadata, artwork: artwork, verifyArtwork: options.verifyArtwork
            )
            guard try AudioFileIdentity.capture(url: url).matches(originalIdentity) else {
                throw PicardError.fileSystem(path: url.path, operation: "commit audio tags",
                    reason: "The source changed while tags were being written. It was not overwritten.")
            }
            try Task.checkCancellation()
            _ = try fileManager.replaceItemAt(url, withItemAt: temporaryURL)

            if options.preserveModificationDate, let originalDate {
                var values = URLResourceValues()
                values.contentModificationDate = originalDate
                try? targetURL.setResourceValues(values)
            }
            return result
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }
}

public actor AudioFileCoordinator {
    public let engine: FormatEngine

    public init(engine: FormatEngine = FormatEngine()) {
        self.engine = engine
    }

    public func load(url: URL, id: UUID = UUID()) async throws -> AudioFile {
        let result = try await engine.read(url: url)
        let identity = try AudioFileIdentity.capture(url: url)

        var file = AudioFile(id: id, url: url)
        try file.beginLoading()
        try file.finishLoading(metadata: result.metadata, artwork: result.artwork, identity: identity,
                               durationInMilliseconds: result.audioProperties?.lengthInMilliseconds)
        return file
    }

    public func save(_ file: AudioFile) async throws -> AudioFile {
        try await save(file, options: FormatSaveOptions())
    }

    public func save(_ file: AudioFile, options: FormatSaveOptions) async throws -> AudioFile {
        var fileToSave = file
        let artworkChanged = file.artwork != file.originalArtwork
        let format = try engine.registry.detect(url: file.url)
        try format.validateArtwork(file.artwork)
        try fileToSave.updateArtwork(format.artworkForStorage(file.artwork))
        try fileToSave.beginSaving()
        _ = try await engine.writeAtomically(
            url: fileToSave.url,
            metadata: fileToSave.metadata,
            artwork: fileToSave.artwork,
            options: FormatSaveOptions(
                preserveModificationDate: options.preserveModificationDate,
                verifyArtwork: options.verifyArtwork && artworkChanged
            )
        )
        let identity = try AudioFileIdentity.capture(url: fileToSave.url)
        try fileToSave.finishSaving(identity: identity)
        return fileToSave
    }
}
