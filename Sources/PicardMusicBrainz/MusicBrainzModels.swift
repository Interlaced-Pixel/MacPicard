import Foundation

public struct MusicBrainzArtistCredit: Codable, Sendable, Equatable {
    public let id: String?
    public let name: String
    public let joinPhrase: String

    public init(id: String?, name: String, joinPhrase: String = "") {
        self.id = id
        self.name = name
        self.joinPhrase = joinPhrase
    }
}

public struct MusicBrainzTrack: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let recordingID: String?
    public let title: String
    public let artistCredit: String
    public let lengthInMilliseconds: Int?
    public let number: String
    public let position: Int
    public let isrcs: [String]

    public init(
        id: String,
        recordingID: String?,
        title: String,
        artistCredit: String,
        lengthInMilliseconds: Int?,
        number: String,
        position: Int,
        isrcs: [String]
    ) {
        self.id = id
        self.recordingID = recordingID
        self.title = title
        self.artistCredit = artistCredit
        self.lengthInMilliseconds = lengthInMilliseconds
        self.number = number
        self.position = position
        self.isrcs = isrcs
    }
}

public struct MusicBrainzMedium: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let position: Int
    public let format: String?
    public let tracks: [MusicBrainzTrack]

    public init(id: String? = nil, position: Int, format: String?, tracks: [MusicBrainzTrack]) {
        self.id = id ?? "medium-\(position)"
        self.position = position
        self.format = format
        self.tracks = tracks
    }
}

public struct MusicBrainzReleaseSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let artistCredit: String
    public let date: String?
    public let country: String?
    public let barcode: String?
    public let status: String?
    public let releaseGroupID: String?
    public let releaseGroupType: String?
    public let labelNames: [String]
    public let catalogNumbers: [String]
    public let mediaCount: Int
    public let trackCount: Int
    public let searchScore: Int?

    public init(
        id: String,
        title: String,
        artistCredit: String,
        date: String?,
        country: String?,
        barcode: String?,
        status: String?,
        releaseGroupID: String?,
        releaseGroupType: String?,
        labelNames: [String],
        catalogNumbers: [String],
        mediaCount: Int,
        trackCount: Int,
        searchScore: Int?
    ) {
        self.id = id
        self.title = title
        self.artistCredit = artistCredit
        self.date = date
        self.country = country
        self.barcode = barcode
        self.status = status
        self.releaseGroupID = releaseGroupID
        self.releaseGroupType = releaseGroupType
        self.labelNames = labelNames
        self.catalogNumbers = catalogNumbers
        self.mediaCount = mediaCount
        self.trackCount = trackCount
        self.searchScore = searchScore
    }
}

public struct MusicBrainzRelease: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let artistCredits: [MusicBrainzArtistCredit]
    public let date: String?
    public let country: String?
    public let barcode: String?
    public let status: String?
    public let releaseGroupID: String?
    public let releaseGroupType: String?
    public let labelNames: [String]
    public let catalogNumbers: [String]
    public let media: [MusicBrainzMedium]
    public let coverArtAvailable: Bool?

    public init(
        id: String,
        title: String,
        artistCredits: [MusicBrainzArtistCredit],
        date: String?,
        country: String?,
        barcode: String?,
        status: String?,
        releaseGroupID: String?,
        releaseGroupType: String?,
        labelNames: [String],
        catalogNumbers: [String],
        media: [MusicBrainzMedium],
        coverArtAvailable: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.artistCredits = artistCredits
        self.date = date
        self.country = country
        self.barcode = barcode
        self.status = status
        self.releaseGroupID = releaseGroupID
        self.releaseGroupType = releaseGroupType
        self.labelNames = labelNames
        self.catalogNumbers = catalogNumbers
        self.media = media
        self.coverArtAvailable = coverArtAvailable
    }

    public var artistCredit: String {
        artistCredits.map { $0.name + $0.joinPhrase }.joined()
    }

    public var tracks: [MusicBrainzTrack] {
        media.flatMap(\.tracks)
    }

    public var summary: MusicBrainzReleaseSummary {
        MusicBrainzReleaseSummary(
            id: id,
            title: title,
            artistCredit: artistCredit,
            date: date,
            country: country,
            barcode: barcode,
            status: status,
            releaseGroupID: releaseGroupID,
            releaseGroupType: releaseGroupType,
            labelNames: labelNames,
            catalogNumbers: catalogNumbers,
            mediaCount: media.count,
            trackCount: tracks.count,
            searchScore: nil
        )
    }
}

struct MusicBrainzSearchResponse: Decodable {
    let releases: [APIRelease]
}

struct APIRelease: Decodable {
    let id: String
    let title: String
    let artistCredits: [APIArtistCredit]
    let date: String?
    let country: String?
    let barcode: String?
    let status: String?
    let releaseGroup: APIReleaseGroup?
    let labelInfo: [APILabelInfo]
    let media: [APIMedium]
    let releaseEvents: [APIReleaseEvent]
    let trackCount: Int?
    let score: Int?
    let coverArt: APICoverArt?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case artistCredits = "artist-credit"
        case date
        case country
        case barcode
        case status
        case releaseGroup = "release-group"
        case labelInfo = "label-info"
        case media
        case releaseEvents = "release-events"
        case trackCount = "track-count"
        case score
        case coverArt = "cover-art-archive"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        artistCredits = try container.decodeIfPresent([APIArtistCredit].self, forKey: .artistCredits) ?? []
        date = try container.decodeIfPresent(String.self, forKey: .date)
        country = try container.decodeIfPresent(String.self, forKey: .country)
        barcode = try container.decodeIfPresent(String.self, forKey: .barcode)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        releaseGroup = try container.decodeIfPresent(APIReleaseGroup.self, forKey: .releaseGroup)
        labelInfo = try container.decodeIfPresent([APILabelInfo].self, forKey: .labelInfo) ?? []
        media = try container.decodeIfPresent([APIMedium].self, forKey: .media) ?? []
        releaseEvents = try container.decodeIfPresent([APIReleaseEvent].self, forKey: .releaseEvents) ?? []
        trackCount = try container.decodeIfPresent(Int.self, forKey: .trackCount)
        score = try container.decodeIfPresent(Int.self, forKey: .score)
        coverArt = try container.decodeIfPresent(APICoverArt.self, forKey: .coverArt)
    }

    func summary() -> MusicBrainzReleaseSummary {
        let mediaTrackCount = media.reduce(0) { $0 + ($1.trackCount ?? $1.tracks.count) }
        return MusicBrainzReleaseSummary(
            id: id,
            title: title,
            artistCredit: Self.displayArtistCredit(artistCredits),
            date: date ?? releaseEvents.first?.date,
            country: country ?? releaseEvents.first?.country,
            barcode: barcode,
            status: status,
            releaseGroupID: releaseGroup?.id,
            releaseGroupType: releaseGroup?.primaryType,
            labelNames: labelInfo.compactMap(\.label?.name),
            catalogNumbers: labelInfo.compactMap(\.catalogNumber),
            mediaCount: media.count,
            trackCount: trackCount ?? mediaTrackCount,
            searchScore: score
        )
    }

    func release() -> MusicBrainzRelease {
        MusicBrainzRelease(
            id: id,
            title: title,
            artistCredits: artistCredits.map(\.model),
            date: date ?? releaseEvents.first?.date,
            country: country ?? releaseEvents.first?.country,
            barcode: barcode,
            status: status,
            releaseGroupID: releaseGroup?.id,
            releaseGroupType: releaseGroup?.primaryType,
            labelNames: labelInfo.compactMap(\.label?.name),
            catalogNumbers: labelInfo.compactMap(\.catalogNumber),
            media: media.map(\.model),
            coverArtAvailable: coverArt?.artwork
        )
    }

    static func displayArtistCredit(_ credits: [APIArtistCredit]) -> String {
        credits.map { ($0.name ?? $0.artist?.name ?? "") + ($0.joinPhrase ?? "") }.joined()
    }
}

struct APICoverArt: Decodable { let artwork: Bool? }

struct APIArtistCredit: Decodable {
    let name: String?
    let joinPhrase: String?
    let artist: APIArtist?

    enum CodingKeys: String, CodingKey {
        case name
        case joinPhrase = "joinphrase"
        case artist
    }

    var model: MusicBrainzArtistCredit {
        MusicBrainzArtistCredit(
            id: artist?.id,
            name: name ?? artist?.name ?? "",
            joinPhrase: joinPhrase ?? ""
        )
    }
}

struct APIArtist: Decodable {
    let id: String?
    let name: String?
}

struct APIReleaseGroup: Decodable {
    let id: String?
    let primaryType: String?

    enum CodingKeys: String, CodingKey {
        case id
        case primaryType = "primary-type"
    }
}

struct APILabelInfo: Decodable {
    let catalogNumber: String?
    let label: APILabel?

    enum CodingKeys: String, CodingKey {
        case catalogNumber = "catalog-number"
        case label
    }
}

struct APILabel: Decodable {
    let name: String?
}

struct APIReleaseEvent: Decodable {
    let date: String?
    let country: String?
}

struct APIMedium: Decodable {
    let id: String?
    let position: Int
    let format: String?
    let trackCount: Int?
    let tracks: [APITrack]

    enum CodingKeys: String, CodingKey {
        case position
        case id
        case format
        case trackCount = "track-count"
        case tracks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        position = try container.decodeIfPresent(Int.self, forKey: .position) ?? 0
        format = try container.decodeIfPresent(String.self, forKey: .format)
        trackCount = try container.decodeIfPresent(Int.self, forKey: .trackCount)
        tracks = try container.decodeIfPresent([APITrack].self, forKey: .tracks) ?? []
    }

    var model: MusicBrainzMedium {
        MusicBrainzMedium(id: id, position: position, format: format, tracks: tracks.map(\.model))
    }
}

struct APITrack: Decodable {
    let id: String
    let number: String
    let position: Int
    let title: String
    let length: Int?
    let recording: APIRecording?
    let artistCredits: [APIArtistCredit]

    enum CodingKeys: String, CodingKey {
        case id
        case number
        case position
        case title
        case length
        case recording
        case artistCredits = "artist-credit"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        number = try container.decodeIfPresent(String.self, forKey: .number) ?? ""
        position = try container.decodeIfPresent(Int.self, forKey: .position) ?? 0
        title = try container.decode(String.self, forKey: .title)
        length = try container.decodeIfPresent(Int.self, forKey: .length)
        recording = try container.decodeIfPresent(APIRecording.self, forKey: .recording)
        artistCredits = try container.decodeIfPresent([APIArtistCredit].self, forKey: .artistCredits) ?? []
    }

    var model: MusicBrainzTrack {
        MusicBrainzTrack(
            id: id,
            recordingID: recording?.id,
            title: title,
            artistCredit: APIRelease.displayArtistCredit(artistCredits),
            lengthInMilliseconds: length ?? recording?.length,
            number: number,
            position: position,
            isrcs: recording?.isrcs ?? []
        )
    }
}

struct APIRecording: Decodable {
    let id: String?
    let title: String?
    let length: Int?
    let isrcs: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case length
        case isrcs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        length = try container.decodeIfPresent(Int.self, forKey: .length)
        isrcs = try container.decodeIfPresent([String].self, forKey: .isrcs) ?? []
    }
}
