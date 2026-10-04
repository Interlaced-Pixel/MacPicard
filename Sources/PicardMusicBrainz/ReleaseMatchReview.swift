import Foundation

public enum MatchReviewError: Error, LocalizedError {
    case invalidTracks, unknownFile, unknownTrack
    public var errorDescription: String? {
        switch self {
        case .invalidTracks: "The release or local selection has invalid or duplicate track/disc identifiers."
        case .unknownFile: "This file is no longer part of the match review."
        case .unknownTrack: "This track does not belong to the selected MusicBrainz release."
        }
    }
}

/// A transient, editable one-to-one mapping. No metadata changes until Apply.
public struct ReleaseMatchReview: Sendable, Equatable {
    public let release: MusicBrainzRelease
    public let localTracks: [LocalTrackCandidate]
    public private(set) var suggestions: [TrackMatch]
    public private(set) var assignments: [UUID: String] = [:]
    public private(set) var manualFileIDs = Set<UUID>()

    public init(release: MusicBrainzRelease, localTracks: [LocalTrackCandidate]) throws {
        guard Set(localTracks.map(\.id)).count == localTracks.count,
              Set(release.tracks.map(\.id)).count == release.tracks.count,
              release.tracks.allSatisfy({ !$0.id.isEmpty }),
              Set(release.media.map(\.id)).count == release.media.count,
              Set(release.media.map(\.position)).count == release.media.count,
              release.media.allSatisfy({ $0.position > 0 }) else { throw MatchReviewError.invalidTracks }
        self.release = release
        self.localTracks = localTracks
        suggestions = TrackMatcher(minimumMargin: 0.06).match(localTracks: localTracks, release: release)
        resetToSuggestions()
    }

    public var missingTracks: [MusicBrainzTrack] {
        let assigned = Set(assignments.values)
        return release.tracks.filter { !assigned.contains($0.id) }
    }
    public var unmatchedFileIDs: Set<UUID> { Set(localTracks.map(\.id)).subtracting(assignments.keys) }
    public var needsReviewCount: Int {
        suggestions.count { $0.decision == .ambiguous && assignments[$0.localTrackID] == nil }
    }

    /// Choosing an occupied track swaps assignments; it can never duplicate a slot.
    public mutating func assign(fileID: UUID, trackID: String?) throws {
        guard localTracks.contains(where: { $0.id == fileID }) else { throw MatchReviewError.unknownFile }
        if let trackID, !release.tracks.contains(where: { $0.id == trackID }) { throw MatchReviewError.unknownTrack }
        let previous = assignments[fileID]
        if let trackID, let owner = assignments.first(where: { $0.value == trackID && $0.key != fileID })?.key {
            assignments[owner] = previous
            manualFileIDs.insert(owner)
        }
        assignments[fileID] = trackID
        manualFileIDs.insert(fileID)
    }

    public mutating func resetToSuggestions() {
        assignments.removeAll(); manualFileIDs.removeAll()
        for match in suggestions where match.decision == .exact || (match.decision == .matched && match.score >= 0.72) {
            if let track = match.releaseTrackID { assignments[match.localTrackID] = track }
        }
    }

    public mutating func unmatchAll() {
        assignments.removeAll()
        manualFileIDs = Set(localTracks.map(\.id))
    }

    public func disc(for trackID: String) -> Int? {
        release.media.first { $0.tracks.contains { $0.id == trackID } }?.position
    }
}
