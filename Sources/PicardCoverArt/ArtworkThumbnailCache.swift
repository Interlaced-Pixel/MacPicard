import CoreGraphics
import Foundation
import ImageIO
import PicardFoundation

public struct ArtworkThumbnailRaster: @unchecked Sendable {
    public let image: CGImage
}

public actor ArtworkThumbnailCache {
    public static let shared = ArtworkThumbnailCache()
    private struct Key: Hashable { let hash: String; let pixels: Int }
    private struct Entry { let raster: ArtworkThumbnailRaster; let cost: Int }
    private var entries: [Key: Entry] = [:]
    private var order: [Key] = []
    private var flights: [Key: Task<ArtworkThumbnailRaster, Error>] = [:]
    private var cost = 0
    private let costLimit: Int
    public private(set) var decodeCount = 0
    public init(costLimit: Int = 16 * 1024 * 1024) { self.costLimit = costLimit }

    public func thumbnail(_ artwork: Artwork, pixels: Int) async throws -> ArtworkThumbnailRaster {
        try Task.checkCancellation()
        guard let data = artwork.data, data.count <= ArtworkValidation.maximumBytes, let hash = artwork.contentHash else {
            throw CoverArtError.invalidImage("Missing or oversized image.")
        }
        let key = Key(hash: hash, pixels: min(1200, max(1, pixels)))
        if let entry = entries[key] { return entry.raster }
        if let flight = flights[key] { let result = try await flight.value; try Task.checkCancellation(); return result }
        let flight = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            _ = try ArtworkValidation.inspect(data)
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: key.pixels,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { throw CoverArtError.invalidImage("ImageIO could not decode the preview.") }
            return ArtworkThumbnailRaster(image: image)
        }
        flights[key] = flight
        defer { flights.removeValue(forKey: key) }
        let raster = try await flight.value
        decodeCount += 1
        let bytes = raster.image.bytesPerRow * raster.image.height
        if bytes <= costLimit {
            entries[key] = Entry(raster: raster, cost: bytes); order.append(key); cost += bytes
            while cost > costLimit || order.count > 256 {
                if let removed = entries.removeValue(forKey: order.removeFirst()) { cost -= removed.cost }
            }
        }
        try Task.checkCancellation()
        return raster
    }
}
