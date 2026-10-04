import Foundation
import PicardFoundation

public extension AudioFormat {
    var artworkTypes: [ArtworkType] {
        self == .mp4 ? [.front] : [.front, .back, .leaflet, .media, .other]
    }
    var supportsArtworkDescriptions: Bool { self != .mp4 }

    func artworkForStorage(_ collection: ArtworkCollection) -> ArtworkCollection {
        ArtworkCollection(images: collection.images.map { image in
            var stored = image
            stored.type = storedArtworkType(image.type)
            if !supportsArtworkDescriptions { stored.description = "" }
            return stored
        })
    }

    func validateArtwork(_ collection: ArtworkCollection, validateImageData: Bool = true) throws {
        try ArtworkValidation.validateCollectionSize(collection.images)
        guard collection.images.count <= ArtworkValidation.maximumImages else {
            throw ArtworkValidation.Failure("At most 64 images can be embedded per file.")
        }
        for image in collection.images {
            try Task.checkCancellation()
            guard let data = image.data else { throw ArtworkValidation.Failure("An artwork image has no data.") }
            let mime = validateImageData ? try ArtworkValidation.inspect(data).mimeType : image.mimeType
            guard ["image/jpeg", "image/png"].contains(mime), mime == image.mimeType else {
                throw ArtworkValidation.Failure("Embedded artwork must be correctly identified JPEG or PNG. Convert it in Manage Artwork.")
            }
            if self == .mp4 && image.type != .front {
                throw ArtworkValidation.Failure("M4A stores an ordered cover-image list, not back/other image types. Export these separately or explicitly convert their type to Front.")
            }
        }
    }

    /// Semantic aliases map to the actual native picture roles; MP4 has no role or description fields.
    func storedArtworkType(_ type: ArtworkType) -> ArtworkType {
        if self == .mp4 { return .front }
        switch type { case .booklet: return .leaflet; case .obi: return .other; default: return type }
    }
}
