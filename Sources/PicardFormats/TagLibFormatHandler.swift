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
            let info = try? ArtworkValidation.inspect(picture.data)
            return Artwork(
                type: format.storedArtworkType(Self.artworkType(from: picture.pictureType)),
                mimeType: picture.mimeType,
                description: picture.description,
                width: info?.width,
                height: info?.height,
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
        try format.validateArtwork(artwork)
        // The writer owns buffered native streams. End its lifetime before opening
        // a second reader: same-size Ogg/MP4 writes may otherwise appear unchanged.
        let result = try writeNative(url: url, metadata: metadata, artwork: artwork)
        let reopened = try read(url: url).artwork.images
        guard reopened.count == artwork.images.count,
              zip(reopened, artwork.images).allSatisfy({ actual, requested in
                  actual.data == requested.data && actual.mimeType == requested.mimeType &&
                  actual.type == format.storedArtworkType(requested.type) &&
                  (!format.supportsArtworkDescriptions || actual.description == requested.description)
              }) else {
            let differences = zip(reopened, artwork.images).enumerated().map { index, pair in
                "image \(index + 1): bytes \(pair.0.data == pair.1.data), MIME \(pair.0.mimeType == pair.1.mimeType), role \(pair.0.type.rawValue)/\(format.storedArtworkType(pair.1.type).rawValue), description \(pair.0.description == pair.1.description)"
            }.joined(separator: "; ")
            throw FormatError.cannotSave(path: url.path, format: format, reason: "Artwork read-back verification failed: requested \(artwork.images.count), reopened \(reopened.count). \(differences)")
        }
        return result
    }

    private func writeNative(url: URL, metadata: Metadata, artwork: ArtworkCollection) throws -> FormatWriteResult {
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
