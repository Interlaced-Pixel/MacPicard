import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Shared bounds for network, local imports, previews and metadata writes.
public enum ArtworkValidation {
    public static let maximumBytes = 32 * 1024 * 1024
    public static let maximumPixels = 40_000_000
    public static let maximumSide = 16_384
    public static let maximumImages = 64
    public static let maximumCollectionBytes = 128 * 1024 * 1024

    public static func validateCollectionSize(_ images: [Artwork]) throws {
        guard images.count <= maximumImages else { throw Failure("At most 64 images per file.") }
        var remaining = maximumCollectionBytes
        for image in images {
            guard let count = image.data?.count, count <= maximumBytes, count <= remaining else {
                throw Failure("Artwork is limited to 32 MiB per image and 128 MiB per image set.")
            }
            remaining -= count
        }
    }

    public struct Info: Sendable, Equatable {
        public let mimeType: String
        public let width: Int
        public let height: Int
    }

    public static func inspect(_ data: Data) throws -> Info {
        guard !data.isEmpty, data.count <= maximumBytes else { throw Failure("Images must be no larger than 32 MiB.") }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0, width <= maximumSide, height <= maximumSide,
              width <= maximumPixels / height,
              let identifier = CGImageSourceGetType(source) as String?,
              let mime = UTType(identifier)?.preferredMIMEType else {
            throw Failure("Use a complete, single-frame image up to 40 megapixels and 16,384 pixels per side.")
        }
        // Decode a bounded preview to catch invalid raster data without allocating the full image.
        guard CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 256,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) != nil else { throw Failure("ImageIO could not decode the image.") }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return Info(mimeType: mime, width: (5...8).contains(orientation) ? height : width,
                    height: (5...8).contains(orientation) ? width : height)
    }

    public struct Failure: Error, LocalizedError, Sendable {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }
}
