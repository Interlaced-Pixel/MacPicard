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

public struct Artwork: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var type: ArtworkType
    public var mimeType: String
    public var description: String
    public var width: Int?
    public var height: Int?
    public var source: ArtworkSource
    public var data: Data?

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
    }

    public var contentHash: String? {
        guard let data else {
            return nil
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
