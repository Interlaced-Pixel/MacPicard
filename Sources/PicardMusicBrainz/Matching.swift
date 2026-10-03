import Foundation
import PicardFoundation

public struct LocalTrackCandidate: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let title: String
    public let artist: String?
    public let durationInMilliseconds: Int?
    public let trackNumber: Int?
    public let discNumber: Int?
    public let recordingID: String?
    public let isrcs: [String]

    public init(
        id: UUID = UUID(),
        title: String,
        artist: String? = nil,
        durationInMilliseconds: Int? = nil,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        recordingID: String? = nil,
        isrcs: [String] = []
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.durationInMilliseconds = durationInMilliseconds
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.recordingID = recordingID
        self.isrcs = isrcs
    }

    public init(metadata: Metadata, id: UUID = UUID(), durationInMilliseconds: Int? = nil) {
        self.init(
            id: id,
            title: metadata.firstValue(for: "title") ?? "",
            artist: metadata.firstValue(for: "artist"),
            durationInMilliseconds: durationInMilliseconds ?? Self.integerValue(metadata.firstValue(for: "~length")),
            trackNumber: Self.numberValue(metadata.firstValue(for: "tracknumber")),
            discNumber: Self.numberValue(metadata.firstValue(for: "discnumber")),
            recordingID: metadata.firstValue(for: "musicbrainz_recordingid") ?? metadata.firstValue(for: "musicbrainz_trackid"),
            isrcs: metadata.values(for: "isrc")
        )
    }

    private static func numberValue(_ value: String?) -> Int? {
        guard let value else { return nil }
        return Int(value.split(separator: "/", maxSplits: 1).first ?? Substring(value))
    }

    private static func integerValue(_ value: String?) -> Int? {
        guard let value else { return nil }
        return Int(value)
    }
}

public struct LocalAlbumCandidate: Codable, Sendable, Equatable {
    public let releaseID: String?
    public let albumTitle: String?
    public let albumArtist: String?
    public let date: String?
    public let barcode: String?
    public let catalogNumbers: [String]
    public let labelNames: [String]
    public let releaseGroupID: String?
    public let tracks: [LocalTrackCandidate]

    public init(
        releaseID: String? = nil,
        albumTitle: String?,
        albumArtist: String?,
        date: String? = nil,
        barcode: String? = nil,
        catalogNumbers: [String] = [],
        labelNames: [String] = [],
        releaseGroupID: String? = nil,
        tracks: [LocalTrackCandidate] = []
    ) {
        self.releaseID = releaseID
        self.albumTitle = albumTitle
        self.albumArtist = albumArtist
        self.date = date
        self.barcode = barcode
        self.catalogNumbers = catalogNumbers
        self.labelNames = labelNames
        self.releaseGroupID = releaseGroupID
        self.tracks = tracks
    }

    public init(metadata: Metadata, tracks: [LocalTrackCandidate] = []) {
        self.init(
            releaseID: metadata.firstValue(for: "musicbrainz_albumid") ?? metadata.firstValue(for: "musicbrainz_releaseid"),
            albumTitle: metadata.firstValue(for: "album"),
            albumArtist: metadata.firstValue(for: "albumartist") ?? metadata.firstValue(for: "artist"),
            date: metadata.firstValue(for: "date"),
            barcode: metadata.firstValue(for: "barcode"),
            catalogNumbers: metadata.values(for: "catalognumber"),
            labelNames: metadata.values(for: "label"),
            releaseGroupID: metadata.firstValue(for: "musicbrainz_releasegroupid"),
            tracks: tracks
        )
    }

    public var trackCount: Int {
        tracks.count
    }
}

public struct ReleaseMatchPreferences: Codable, Sendable, Equatable {
    public var preferredCountries: [String]
    public var minimumSimilarity: Double
    public var minimumMargin: Double
    public var minimumTrackSimilarity: Double

    public init(
        preferredCountries: [String] = [],
        minimumSimilarity: Double = 0.25,
        minimumMargin: Double = 0.02,
        minimumTrackSimilarity: Double = 0.35
    ) {
        self.preferredCountries = preferredCountries
        self.minimumSimilarity = minimumSimilarity
        self.minimumMargin = minimumMargin
        self.minimumTrackSimilarity = minimumTrackSimilarity
    }
}

public enum ReleaseMatchDecision: String, Codable, Sendable, Equatable {
    case exact
    case matched
    case ambiguous
    case rejected
}

public enum TrackMatchDecision: String, Codable, Sendable, Equatable {
    case exact
    case matched
    case ambiguous
    case unmatched
}

public struct TrackMatch: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let localTrackID: UUID
    public let releaseTrackID: String?
    public let score: Double
    public let decision: TrackMatchDecision

    public init(
        localTrackID: UUID,
        releaseTrackID: String?,
        score: Double,
        decision: TrackMatchDecision
    ) {
        self.id = UUID()
        self.localTrackID = localTrackID
        self.releaseTrackID = releaseTrackID
        self.score = score
        self.decision = decision
    }
}

public struct ReleaseMatchScore: Codable, Sendable, Equatable {
    public let total: Double
    public let identifier: Double
    public let albumTitle: Double
    public let artist: Double
    public let trackCount: Double
    public let tracks: Double
    public let duration: Double
    public let preferenceBonus: Double
    public let identifierMismatch: Bool

    public init(
        total: Double,
        identifier: Double,
        albumTitle: Double,
        artist: Double,
        trackCount: Double,
        tracks: Double,
        duration: Double,
        preferenceBonus: Double,
        identifierMismatch: Bool
    ) {
        self.total = total
        self.identifier = identifier
        self.albumTitle = albumTitle
        self.artist = artist
        self.trackCount = trackCount
        self.tracks = tracks
        self.duration = duration
        self.preferenceBonus = preferenceBonus
        self.identifierMismatch = identifierMismatch
    }
}

public struct ReleaseMatchResult: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let release: MusicBrainzReleaseSummary
    public let score: ReleaseMatchScore
    public let margin: Double
    public let decision: ReleaseMatchDecision
    public let trackMatches: [TrackMatch]

    public init(
        release: MusicBrainzReleaseSummary,
        score: ReleaseMatchScore,
        margin: Double,
        decision: ReleaseMatchDecision,
        trackMatches: [TrackMatch]
    ) {
        self.id = UUID()
        self.release = release
        self.score = score
        self.margin = margin
        self.decision = decision
        self.trackMatches = trackMatches
    }
}

public struct TrackMatcher: Sendable {
    public let minimumSimilarity: Double
    public let minimumMargin: Double

    public init(minimumSimilarity: Double = 0.35, minimumMargin: Double = 0.02) {
        self.minimumSimilarity = minimumSimilarity
        self.minimumMargin = minimumMargin
    }

    public func match(
        localTracks: [LocalTrackCandidate],
        releaseTracks: [MusicBrainzTrack]
    ) -> [TrackMatch] {
        guard !localTracks.isEmpty else { return [] }

        struct Pair {
            let localIndex: Int
            let remoteIndex: Int
            let score: Double
            let exact: Bool
        }

        var pairs: [Pair] = []
        for (localIndex, local) in localTracks.enumerated() {
            for (remoteIndex, remote) in releaseTracks.enumerated() {
                let result = score(local: local, remote: remote)
                pairs.append(Pair(localIndex: localIndex, remoteIndex: remoteIndex, score: result.score, exact: result.exact))
            }
        }

        let sortedPairs = pairs.sorted {
            if $0.score == $1.score {
                if $0.localIndex == $1.localIndex { return $0.remoteIndex < $1.remoteIndex }
                return $0.localIndex < $1.localIndex
            }
            return $0.score > $1.score
        }

        var assignedLocals: Set<Int> = []
        var assignedRemotes: Set<Int> = []
        var results: [TrackMatch] = []

        for pair in sortedPairs {
            guard !assignedLocals.contains(pair.localIndex), !assignedRemotes.contains(pair.remoteIndex) else {
                continue
            }
            guard pair.score >= minimumSimilarity else { continue }

            let local = localTracks[pair.localIndex]
            let remote = releaseTracks[pair.remoteIndex]
            let alternatives = pairs
                .filter { $0.localIndex == pair.localIndex && $0.remoteIndex != pair.remoteIndex }
                .map(\.score)
                .sorted(by: >)
            let secondScore = alternatives.first ?? 0
            let margin = pair.score - secondScore
            let decision: TrackMatchDecision

            if pair.exact {
                decision = .exact
            } else if margin < minimumMargin {
                decision = .ambiguous
            } else {
                decision = .matched
            }

            assignedLocals.insert(pair.localIndex)
            assignedRemotes.insert(pair.remoteIndex)
            results.append(
                TrackMatch(
                    localTrackID: local.id,
                    releaseTrackID: remote.id,
                    score: pair.score,
                    decision: decision
                )
            )
        }

        for (index, local) in localTracks.enumerated() where !assignedLocals.contains(index) {
            results.append(
                TrackMatch(
                    localTrackID: local.id,
                    releaseTrackID: nil,
                    score: 0,
                    decision: .unmatched
                )
            )
        }

        return results.sorted { $0.localTrackID.uuidString < $1.localTrackID.uuidString }
    }

    private func score(local: LocalTrackCandidate, remote: MusicBrainzTrack) -> (score: Double, exact: Bool) {
        if let localRecordingID = local.recordingID, localRecordingID == remote.recordingID {
            return (1, true)
        }

        if !local.isrcs.isEmpty, !Set(local.isrcs).isDisjoint(with: remote.isrcs) {
            return (1, true)
        }

        let title = Similarity.text(local.title, remote.title)
        let artist = Similarity.text(local.artist, remote.artistCredit)
        let duration = Similarity.duration(local.durationInMilliseconds, remote.lengthInMilliseconds)
        var total = (title * 0.60) + (artist * 0.15) + (duration * 0.25)

        if let localNumber = local.trackNumber, let remoteNumber = Int(remote.number.split(separator: "/").first ?? "") {
            total += localNumber == remoteNumber ? 0.05 : -0.10
        }

        return (max(0, min(1, total)), false)
    }
}

public struct ReleaseMatcher: Sendable {
    public let preferences: ReleaseMatchPreferences
    public let trackMatcher: TrackMatcher

    public init(preferences: ReleaseMatchPreferences = ReleaseMatchPreferences()) {
        self.preferences = preferences
        self.trackMatcher = TrackMatcher(
            minimumSimilarity: preferences.minimumTrackSimilarity,
            minimumMargin: preferences.minimumMargin
        )
    }

    public func bestMatch(
        local: LocalAlbumCandidate,
        candidates: [MusicBrainzReleaseSummary]
    ) -> ReleaseMatchResult? {
        rank(local: local, candidates: candidates).first
    }

    public func bestMatch(
        local: LocalAlbumCandidate,
        candidates: [MusicBrainzRelease]
    ) -> ReleaseMatchResult? {
        rank(local: local, candidates: candidates).first
    }

    public func rank(
        local: LocalAlbumCandidate,
        candidates: [MusicBrainzReleaseSummary]
    ) -> [ReleaseMatchResult] {
        guard !candidates.isEmpty else { return [] }

        let scored = candidates.map { candidate in
            (candidate, score(local: local, release: candidate))
        }.sorted {
            if $0.1.total == $1.1.total { return $0.0.id < $1.0.id }
            return $0.1.total > $1.1.total
        }

        let bestScore = scored[0].1.total
        let secondScore = scored.dropFirst().first?.1.total ?? 0
        let margin = bestScore - secondScore

        return scored.enumerated().map { index, item in
            let decision: ReleaseMatchDecision
            if item.1.total < preferences.minimumSimilarity {
                decision = .rejected
            } else if index == 0 && item.1.identifier >= 1 && !item.1.identifierMismatch {
                decision = .exact
            } else if index == 0 && margin < preferences.minimumMargin {
                decision = .ambiguous
            } else if index == 0 {
                decision = .matched
            } else {
                decision = .rejected
            }

            return ReleaseMatchResult(
                release: item.0,
                score: item.1,
                margin: index == 0 ? margin : 0,
                decision: decision,
                trackMatches: []
            )
        }
    }

    public func rank(
        local: LocalAlbumCandidate,
        candidates: [MusicBrainzRelease]
    ) -> [ReleaseMatchResult] {
        guard !candidates.isEmpty else { return [] }

        let scored = candidates.map { candidate in
            let trackMatches = trackMatcher.match(localTracks: local.tracks, releaseTracks: candidate.tracks)
            return (candidate, score(local: local, release: candidate, trackMatches: trackMatches), trackMatches)
        }.sorted {
            if $0.1.total == $1.1.total { return $0.0.id < $1.0.id }
            return $0.1.total > $1.1.total
        }

        let bestScore = scored[0].1.total
        let secondScore = scored.dropFirst().first?.1.total ?? 0
        let margin = bestScore - secondScore

        return scored.enumerated().map { index, item in
            let decision = decision(for: item.1, index: index, margin: margin)
            return ReleaseMatchResult(
                release: item.0.summary,
                score: item.1,
                margin: index == 0 ? margin : 0,
                decision: decision,
                trackMatches: item.2
            )
        }
    }

    public func score(local: LocalAlbumCandidate, release: MusicBrainzReleaseSummary) -> ReleaseMatchScore {
        let identifierResult = identifierScore(local: local, release: release)
        let albumTitle = Similarity.text(local.albumTitle, release.title)
        let artist = Similarity.text(local.albumArtist, release.artistCredit)
        let trackCount = Similarity.count(local.trackCount, release.trackCount)
        let preferenceBonus = preferredCountryBonus(for: release.country)

        let base = (identifierResult.score * 0.20)
            + (albumTitle * 0.32)
            + (artist * 0.18)
            + (trackCount * 0.12)
            + (preferenceBonus)
        let cappedBase = identifierResult.mismatch ? min(base, 0.40) : base
        let total = min(1, cappedBase + trackCountContribution(local: local, release: release))

        return ReleaseMatchScore(
            total: total,
            identifier: identifierResult.score,
            albumTitle: albumTitle,
            artist: artist,
            trackCount: trackCount,
            tracks: 0,
            duration: 0,
            preferenceBonus: preferenceBonus,
            identifierMismatch: identifierResult.mismatch
        )
    }

    public func score(local: LocalAlbumCandidate, release: MusicBrainzRelease) -> ReleaseMatchScore {
        let trackMatches = trackMatcher.match(localTracks: local.tracks, releaseTracks: release.tracks)
        return score(local: local, release: release, trackMatches: trackMatches)
    }

    private func score(
        local: LocalAlbumCandidate,
        release: MusicBrainzRelease,
        trackMatches: [TrackMatch]
    ) -> ReleaseMatchScore {
        let identifierResult = identifierScore(local: local, release: release.summary)
        let albumTitle = Similarity.text(local.albumTitle, release.title)
        let artist = Similarity.text(local.albumArtist, release.artistCredit)
        let trackCount = Similarity.count(local.trackCount, release.tracks.count)
        let preferenceBonus = preferredCountryBonus(for: release.country)

        let matchedTracks = trackMatches.filter { $0.releaseTrackID != nil }
        let trackSimilarity: Double
        if matchedTracks.isEmpty {
            trackSimilarity = local.tracks.isEmpty ? 0.5 : 0
        } else {
            trackSimilarity = matchedTracks.map(\.score).reduce(0, +) / Double(matchedTracks.count)
        }
        let durationSimilarity = durationSimilarity(local: local.tracks, release: release.tracks, matches: matchedTracks)

        let base = (identifierResult.score * 0.20)
            + (albumTitle * 0.25)
            + (artist * 0.15)
            + (trackCount * 0.10)
            + (trackSimilarity * 0.22)
            + (durationSimilarity * 0.05)
            + preferenceBonus
        let cappedBase = identifierResult.mismatch ? min(base, 0.40) : base
        let total = min(1, cappedBase + trackCountContribution(local: local, release: release.summary))

        return ReleaseMatchScore(
            total: total,
            identifier: identifierResult.score,
            albumTitle: albumTitle,
            artist: artist,
            trackCount: trackCount,
            tracks: trackSimilarity,
            duration: durationSimilarity,
            preferenceBonus: preferenceBonus,
            identifierMismatch: identifierResult.mismatch
        )
    }

    private func decision(for score: ReleaseMatchScore, index: Int, margin: Double) -> ReleaseMatchDecision {
        if score.total < preferences.minimumSimilarity {
            return .rejected
        }
        if index == 0 && score.identifier >= 1 && !score.identifierMismatch {
            return .exact
        }
        if index == 0 && margin < preferences.minimumMargin {
            return .ambiguous
        }
        return index == 0 ? .matched : .rejected
    }

    private func preferredCountryBonus(for country: String?) -> Double {
        preferences.preferredCountries.contains {
            Similarity.normalize($0) == Similarity.normalize(country ?? "")
        } ? 0.03 : 0
    }

    private func durationSimilarity(
        local: [LocalTrackCandidate],
        release: [MusicBrainzTrack],
        matches: [TrackMatch]
    ) -> Double {
        let localByID = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        let releaseByID = Dictionary(uniqueKeysWithValues: release.map { ($0.id, $0) })
        let values = matches.compactMap { match -> Double? in
            guard let localTrack = localByID[match.localTrackID],
                  let releaseTrackID = match.releaseTrackID,
                  let releaseTrack = releaseByID[releaseTrackID] else {
                return nil
            }
            return Similarity.duration(localTrack.durationInMilliseconds, releaseTrack.lengthInMilliseconds)
        }
        return values.isEmpty ? (local.isEmpty ? 0.5 : 0) : values.reduce(0, +) / Double(values.count)
    }

    private func identifierScore(
        local: LocalAlbumCandidate,
        release: MusicBrainzReleaseSummary
    ) -> (score: Double, mismatch: Bool) {
        if let localReleaseID = local.releaseID, !localReleaseID.isEmpty {
            return (localReleaseID == release.id ? 1 : 0, localReleaseID != release.id)
        }

        if let localReleaseGroupID = local.releaseGroupID,
           let releaseGroupID = release.releaseGroupID,
           !localReleaseGroupID.isEmpty,
           !releaseGroupID.isEmpty {
            return (localReleaseGroupID == releaseGroupID ? 0.95 : 0, localReleaseGroupID != releaseGroupID)
        }

        if let localBarcode = local.barcode, !localBarcode.isEmpty, let releaseBarcode = release.barcode, !releaseBarcode.isEmpty {
            return (
                Similarity.normalizeIdentifier(localBarcode) == Similarity.normalizeIdentifier(releaseBarcode) ? 1 : 0,
                Similarity.normalizeIdentifier(localBarcode) != Similarity.normalizeIdentifier(releaseBarcode)
            )
        }

        let localCatalogs = Set(local.catalogNumbers.map(Similarity.normalizeIdentifier))
        let releaseCatalogs = Set(release.catalogNumbers.map(Similarity.normalizeIdentifier))
        if !localCatalogs.isEmpty, !releaseCatalogs.isEmpty {
            return (!localCatalogs.isDisjoint(with: releaseCatalogs) ? 0.9 : 0, localCatalogs.isDisjoint(with: releaseCatalogs))
        }

        return (0, false)
    }

    private func trackCountContribution(local: LocalAlbumCandidate, release: MusicBrainzReleaseSummary) -> Double {
        guard local.trackCount > 0, release.trackCount > 0 else { return 0 }
        let difference = abs(local.trackCount - release.trackCount)
        return difference == 0 ? 0.18 : max(0, 0.18 - (Double(difference) * 0.06))
    }
}

private enum Similarity {
    static func text(_ lhs: String?, _ rhs: String?) -> Double {
        guard let lhs, let rhs, !lhs.isEmpty, !rhs.isEmpty else { return 0.5 }
        let left = normalize(lhs)
        let right = normalize(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0.5 }
        if left == right { return 1 }

        let leftTokens = Set(left.split(separator: " ").map(String.init))
        let rightTokens = Set(right.split(separator: " ").map(String.init))
        let unionCount = leftTokens.union(rightTokens).count
        let tokenScore = unionCount == 0 ? 0 : Double(leftTokens.intersection(rightTokens).count) / Double(unionCount)
        let editScore = levenshteinRatio(left, right)
        return (tokenScore * 0.55) + (editScore * 0.45)
    }

    static func duration(_ lhs: Int?, _ rhs: Int?) -> Double {
        guard let lhs, let rhs else { return 0.5 }
        let difference = abs(lhs - rhs)
        guard difference <= 30_000 else { return 0 }
        return 1 - (Double(difference) / 30_000)
    }

    static func count(_ lhs: Int, _ rhs: Int) -> Double {
        guard lhs > 0, rhs > 0 else { return 0.5 }
        guard lhs != rhs else { return 1 }
        return max(0, 1 - (Double(abs(lhs - rhs)) / Double(max(lhs, rhs))))
    }

    static func normalize(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .replacingOccurrences(of: "&", with: " and ")
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ")
    }

    static func normalizeIdentifier(_ value: String) -> String {
        value.filter { $0.isLetter || $0.isNumber }.uppercased()
    }

    private static func levenshteinRatio(_ lhs: String, _ rhs: String) -> Double {
        let left = Array(lhs)
        let right = Array(rhs)
        guard !left.isEmpty || !right.isEmpty else { return 1 }
        guard !left.isEmpty, !right.isEmpty else { return 0 }

        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1]
            current.reserveCapacity(right.count + 1)
            for (rightIndex, rightCharacter) in right.enumerated() {
                let insertion = current[rightIndex] + 1
                let deletion = previous[rightIndex + 1] + 1
                let substitution = previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                current.append(min(insertion, deletion, substitution))
            }
            previous = current
        }

        let distance = previous[right.count]
        return 1 - (Double(distance) / Double(max(left.count, right.count)))
    }
}
