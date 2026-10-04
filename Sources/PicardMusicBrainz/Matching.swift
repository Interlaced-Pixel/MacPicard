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
        match(localTracks: localTracks, releaseTracks: releaseTracks, discs: [:])
    }

    public func match(localTracks: [LocalTrackCandidate], release: MusicBrainzRelease) -> [TrackMatch] {
        let discs = release.media.reduce(into: [String: Int]()) { result, medium in
            for track in medium.tracks { result[track.id] = medium.position }
        }
        return match(localTracks: localTracks, releaseTracks: release.tracks, discs: discs)
    }

    public func evidence(local: LocalTrackCandidate, remote: MusicBrainzTrack, disc: Int? = nil) -> TrackMatchEvidence {
        var reasons: [String] = []
        let recording = local.recordingID?.lowercased() == remote.recordingID?.lowercased() && local.recordingID?.isEmpty == false
        let isrc = !Set(local.isrcs.map { $0.uppercased() }).isDisjoint(with: remote.isrcs.map { $0.uppercased() })
        let exact = recording || isrc
        if recording { reasons.append("Recording ID matches") }
        if isrc { reasons.append("ISRC matches") }
        let title = local.title.isEmpty ? 0 : Similarity.text(local.title, remote.title)
        var weight = 0.60
        var total = title * weight
        if title >= 0.99 { reasons.append("Title matches") }
        else if title >= 0.70 { reasons.append("Similar title") }
        if let artist = local.artist, !artist.isEmpty, !remote.artistCredit.isEmpty {
            let similarity = Similarity.text(artist, remote.artistCredit)
            total += similarity * 0.15; weight += 0.15
            if similarity >= 0.85 { reasons.append("Artist matches") }
        }
        var lengthMismatch = false
        if let duration = local.durationInMilliseconds, let remoteDuration = remote.lengthInMilliseconds, duration > 0, remoteDuration > 0 {
            total += Similarity.duration(duration, remoteDuration) * 0.25; weight += 0.25
            let difference = abs(duration - remoteDuration)
            reasons.append(difference <= 2_000 ? "Length within 2 seconds" : "Length differs by \(difference / 1_000) seconds")
            lengthMismatch = difference > 15_000
        }
        total = exact ? 0.93 : total / weight * 0.95
        if let localNumber = local.trackNumber, let remoteNumber = Int(remote.number.split(separator: "/").first ?? "") {
            total += localNumber == remoteNumber ? 0.02 : -0.025
            if localNumber == remoteNumber { reasons.append("Track number matches") }
        }
        if let localDisc = local.discNumber, let disc {
            total += localDisc == disc ? 0.025 : -0.04
            reasons.append(localDisc == disc ? "Disc matches" : "Different disc")
        }
        if lengthMismatch && !exact { total = min(total, 0.68) }
        return TrackMatchEvidence(score: max(0, min(1, total)), exact: exact, reasons: reasons)
    }

    private func match(localTracks: [LocalTrackCandidate], releaseTracks: [MusicBrainzTrack], discs: [String: Int]) -> [TrackMatch] {
        guard !localTracks.isEmpty else { return [] }
        // Optimize the entire album, not a greedy first-come pairing. Dummy columns
        // allow any file to remain unmatched, including incomplete collections.
        let evidence = localTracks.map { local in
            releaseTracks.map { self.evidence(local: local, remote: $0, disc: discs[$0.id]) }
        }
        let exactBonus = Double(localTracks.count + 1)
        let weights = evidence.map { row in
            row.map { item in item.score >= minimumSimilarity ? item.score + (item.exact ? exactBonus : 0) : -1_000_000 }
                + Array(repeating: max(0, minimumSimilarity - 0.000_001), count: localTracks.count)
        }
        let assignment = MaximumTrackAssignment.solve(weights)
        return localTracks.indices.map { localIndex in
            let remoteIndex = assignment[localIndex]
            guard remoteIndex < releaseTracks.count else {
                return TrackMatch(localTrackID: localTracks[localIndex].id, releaseTrackID: nil, score: 0, decision: .unmatched)
            }
            let item = evidence[localIndex][remoteIndex]
            let localAlternative = evidence[localIndex].enumerated().filter { $0.offset != remoteIndex }.map(\.element.score).max() ?? 0
            let competitor = evidence.indices.filter { $0 != localIndex }.map { evidence[$0][remoteIndex].score }.max() ?? 0
            let ambiguous = item.score - max(localAlternative, competitor) < minimumMargin
            return TrackMatch(localTrackID: localTracks[localIndex].id, releaseTrackID: releaseTracks[remoteIndex].id,
                              score: item.score, decision: ambiguous ? .ambiguous : item.exact ? .exact : .matched)
        }
    }
}

public struct TrackMatchEvidence: Sendable, Equatable {
    public let score: Double
    public let exact: Bool
    public let reasons: [String]
}

/// Rectangular Hungarian assignment with deterministic tie breaking. Columns >= rows.
private enum MaximumTrackAssignment {
    static func solve(_ weights: [[Double]]) -> [Int] {
        let rows = weights.count
        guard rows > 0 else { return [] }
        let columns = weights[0].count
        var u = [Double](repeating: 0, count: rows + 1)
        var v = [Double](repeating: 0, count: columns + 1)
        var p = [Int](repeating: 0, count: columns + 1)
        var way = [Int](repeating: 0, count: columns + 1)
        for row in 1...rows {
            p[0] = row
            var column = 0
            var minimum = [Double](repeating: .infinity, count: columns + 1)
            var used = [Bool](repeating: false, count: columns + 1)
            repeat {
                used[column] = true
                let activeRow = p[column]
                var delta = Double.infinity
                var next = 0
                for candidate in 1...columns where !used[candidate] {
                    let cost = -weights[activeRow - 1][candidate - 1] - u[activeRow] - v[candidate]
                    if cost < minimum[candidate] { minimum[candidate] = cost; way[candidate] = column }
                    if minimum[candidate] < delta { delta = minimum[candidate]; next = candidate }
                }
                for candidate in 0...columns {
                    if used[candidate] { u[p[candidate]] += delta; v[candidate] -= delta }
                    else { minimum[candidate] -= delta }
                }
                column = next
            } while p[column] != 0
            repeat {
                let previous = way[column]
                p[column] = p[previous]
                column = previous
            } while column != 0
        }
        var result = [Int](repeating: columns, count: rows)
        for column in 1...columns where p[column] > 0 { result[p[column] - 1] = column - 1 }
        return result
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
            let trackMatches = trackMatcher.match(localTracks: local.tracks, release: candidate)
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
        let trackMatches = trackMatcher.match(localTracks: local.tracks, release: release)
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
