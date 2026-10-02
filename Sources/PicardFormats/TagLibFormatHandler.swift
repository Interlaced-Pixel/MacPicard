import Foundation
import PicardFoundation
import TagLibSwift

public struct TagLibFormatHandler: Sendable {
    public let format: AudioFormat

    public init(format: AudioFormat) {
        self.format = format
    }

    public func read(url: URL) throws -> FormatReadResult {
        guard let file = TagLibSwift.AudioFile(path: url.path), file.isValid else {
            throw FormatError.cannotOpen(path: url.path, format: format)
        }

        let metadata = Metadata(
            fields: file.properties.reduce(into: [String: [String]]()) { result, item in
                result[item.key.lowercased()] = item.value
            }
        )
        let artwork = ArtworkCollection(images: file.pictures.map { picture in
            Artwork(
                type: Self.artworkType(from: picture.pictureType),
                mimeType: picture.mimeType,
                description: picture.description,
                source: .embedded,
                data: picture.data
            )
        })

        let audioProperties = file.audioProperties.map {
            FormatAudioProperties(
                lengthInMilliseconds: $0.lengthInMilliseconds,
                bitrate: $0.bitrate,
                sampleRate: $0.sampleRate,
                channels: $0.channels,
                bitsPerSample: $0.bitsPerSample
            )
        }

        return FormatReadResult(
            format: format,
            metadata: metadata,
            artwork: artwork,
            audioProperties: audioProperties
        )
    }

    public func write(
        url: URL,
        metadata: Metadata,
        artwork: ArtworkCollection
    ) throws -> FormatWriteResult {
        guard let file = TagLibSwift.AudioFile(path: url.path), file.isValid else {
            throw FormatError.cannotOpen(path: url.path, format: format)
        }

        let properties = metadata.rawFields().reduce(into: [String: [String]]()) { result, item in
            result[item.key.uppercased()] = item.value
        }
        let unsupported = file.setProperties(properties)

        guard unsupported.isEmpty else {
            throw FormatError.unsupportedMetadata(path: url.path, keys: unsupported.keys.sorted())
        }

        let pictures = try artwork.images.map { artwork in
            guard let data = artwork.data else {
                throw FormatError.artworkMissingData(path: url.path, artworkID: artwork.id)
            }

            return TagLibSwift.Picture(
                data: data,
                mimeType: artwork.mimeType,
                description: artwork.description,
                pictureType: Self.pictureType(from: artwork.type)
            )
        }

        guard file.setPictures(pictures) else {
            throw FormatError.artworkWriteRejected(path: url.path, format: format)
        }

        do {
            try file.save()
        } catch {
            throw FormatError.cannotSave(path: url.path, format: format, reason: error.localizedDescription)
        }

        return FormatWriteResult(
            format: format,
            writtenMetadataKeys: properties.keys.sorted(),
            writtenArtworkCount: pictures.count
        )
    }

    private static func artworkType(from type: TagLibSwift.Picture.PictureType) -> ArtworkType {
        switch type {
        case .frontCover: return .front
        case .backCover: return .back
        case .leafletPage: return .leaflet
        case .media: return .media
        default: return .other
        }
    }

    private static func pictureType(from type: ArtworkType) -> TagLibSwift.Picture.PictureType {
        switch type {
        case .front: return .frontCover
        case .back: return .backCover
        case .booklet, .leaflet: return .leafletPage
        case .media: return .media
        case .obi, .other: return .other
        }
    }
}
