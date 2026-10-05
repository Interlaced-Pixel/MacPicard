import CryptoKit
import Foundation

public enum ArtworkType: String, Codable, Sendable, CaseIterable {
    case front
    case back
    case booklet
    case media
    case obi
    case leaflet
    case other
}

public enum ArtworkSource: Codable, Sendable, Equatable {
    case embedded
    case localFile(URL)
    case remote(URL)
    case generated
}

private final class ArtworkHashCache: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: String?

    var value: String? {
        get {
            lock.lock(); defer { lock.unlock() }
            return storedValue
        }
        set {
            lock.lock(); defer { lock.unlock() }
            storedValue = newValue
        }
    }
}

public struct Artwork: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var type: ArtworkType
    public var mimeType: String
    public var description: String
    public var width: Int?
    public var height: Int?
    public var source: ArtworkSource
    public var data: Data? {
        didSet { hashCache.value = nil }
    }

    // Hashing image bytes is useful for SwiftUI task identities, but doing it on
    // every body evaluation turns large artwork into a repeated O(bytes) cost.
    // The cache is deliberately not serialized; it is derived from `data`.
    private let hashCache: ArtworkHashCache

    private enum CodingKeys: String, CodingKey {
        case id, type, mimeType, description, width, height, source, data
    }

    public init(
        id: UUID = UUID(),
        type: ArtworkType = .front,
        mimeType: String,
        description: String = "",
        width: Int? = nil,
        height: Int? = nil,
        source: ArtworkSource,
        data: Data? = nil
    ) {
        self.id = id
        self.type = type
        self.mimeType = mimeType
        self.description = description
        self.width = width
        self.height = height
        self.source = source
        self.data = data
        self.hashCache = ArtworkHashCache()
    }

    public var contentHash: String? {
        guard let data else {
            return nil
        }
        if let cachedContentHash = hashCache.value { return cachedContentHash }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        hashCache.value = hash
        return hash
    }

    public static func == (lhs: Artwork, rhs: Artwork) -> Bool {
        lhs.id == rhs.id && lhs.type == rhs.type && lhs.mimeType == rhs.mimeType &&
            lhs.description == rhs.description && lhs.width == rhs.width && lhs.height == rhs.height &&
            lhs.source == rhs.source && lhs.data == rhs.data
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        type = try values.decode(ArtworkType.self, forKey: .type)
        mimeType = try values.decode(String.self, forKey: .mimeType)
        description = try values.decode(String.self, forKey: .description)
        width = try values.decodeIfPresent(Int.self, forKey: .width)
        height = try values.decodeIfPresent(Int.self, forKey: .height)
        source = try values.decode(ArtworkSource.self, forKey: .source)
        data = try values.decodeIfPresent(Data.self, forKey: .data)
        hashCache = ArtworkHashCache()
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(type, forKey: .type)
        try values.encode(mimeType, forKey: .mimeType)
        try values.encode(description, forKey: .description)
        try values.encodeIfPresent(width, forKey: .width)
        try values.encodeIfPresent(height, forKey: .height)
        try values.encode(source, forKey: .source)
        try values.encodeIfPresent(data, forKey: .data)
    }
}

public struct ArtworkCollection: Codable, Sendable, Equatable {
    public private(set) var images: [Artwork]

    public init(images: [Artwork] = []) {
        self.images = images
    }

    public var isEmpty: Bool {
        images.isEmpty
    }

    public mutating func append(_ artwork: Artwork) {
        images.append(artwork)
    }

    public mutating func remove(id: UUID) {
        images.removeAll { $0.id == id }
    }

    public func first(of type: ArtworkType) -> Artwork? {
        images.first { $0.type == type }
    }
}
