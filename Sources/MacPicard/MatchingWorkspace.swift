import Foundation
import PicardFoundation
import PicardMusicBrainz

struct ReviewFileBaseline: Codable, Sendable, Equatable {
    let id: UUID
    let url: URL
    let metadata: Metadata
    let originalMetadata: Metadata
    let identity: AudioFileIdentity?
    init(_ file: AudioFile) {
        id = file.id; url = file.url; metadata = file.metadata; originalMetadata = file.originalMetadata; identity = file.identity
    }
    func matches(_ file: AudioFile?) -> Bool {
        guard let file, [.ready, .changed, .saved].contains(file.state) else { return false }
        return id == file.id && url == file.url && metadata == file.metadata && originalMetadata == file.originalMetadata
            && (identity == nil ? file.identity == nil : identity?.matches(file.identity) == true)
    }
}

struct LibraryReviewCheckpoint: Codable, Sendable {
    var schema = 1
    let workspaceID: UUID
    let country: String
    let groups: [AppModel.AlbumGroup]
    var run: AppModel.LibraryMatchRun
}

actor ReviewCheckpointStore {
    static let shared = ReviewCheckpointStore()
    private struct Root: Codable { let storageSchema: Int; let generation: UUID; let checkpoint: LibraryReviewCheckpoint }
    private struct Delta: Codable { let generation: UUID; let completedAt: Date; let proposals: [AppModel.LibraryMatchProposal] }
    private struct State { let generation: UUID; var length: UInt64; var positions: [String: Int] }
    private var states: [URL: State] = [:]
    private var stateOrder: [URL] = []

    private func remember(_ state: State, for url: URL) {
        states[url] = state
        stateOrder.removeAll { $0 == url }; stateOrder.append(url)
        while stateOrder.count > 4 { states.removeValue(forKey: stateOrder.removeFirst()) }
    }

    func reset(_ checkpoint: LibraryReviewCheckpoint, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let generation = UUID()
        try DurableArchive.replace(JSONEncoder().encode(Root(storageSchema: 2, generation: generation, checkpoint: checkpoint)), at: url)
        // A generation tag prevents old deltas from replaying if the app dies
        // between the atomic root replacement and clearing its append log.
        try DurableArchive.replace(Data(), at: url.appendingPathExtension("jsonl"))
        remember(State(generation: generation, length: 0, positions: Dictionary(uniqueKeysWithValues: checkpoint.run.proposals.enumerated().map { ($0.element.id, $0.offset) })), for: url)
    }
    func save(_ checkpoint: LibraryReviewCheckpoint, to url: URL, changedProposalIDs: Set<String>? = nil) throws {
        guard var state = states[url] else { try reset(checkpoint, to: url); return }
        let proposals = changedProposalIDs.map { ids in ids.sorted().compactMap { id -> AppModel.LibraryMatchProposal? in
            let index = state.positions[id] ?? (checkpoint.run.proposals.last?.id == id ? checkpoint.run.proposals.count - 1 : checkpoint.run.proposals.firstIndex { $0.id == id })
            guard let index, checkpoint.run.proposals.indices.contains(index), checkpoint.run.proposals[index].id == id else { return nil }
            state.positions[id] = index
            return checkpoint.run.proposals[index]
        } } ?? checkpoint.run.proposals
        if let changedProposalIDs, proposals.count != changedProposalIDs.count {
            throw PicardError.invalidConfiguration("The review checkpoint contains an unknown proposal.")
        }
        var data = try JSONEncoder().encode(Delta(generation: state.generation, completedAt: checkpoint.run.completedAt, proposals: proposals))
        data.append(0x0A)
        let handle = try FileHandle(forWritingTo: url.appendingPathExtension("jsonl")); defer { try? handle.close() }
        try handle.truncate(atOffset: state.length); try handle.seekToEnd()
        try handle.write(contentsOf: data); try handle.synchronize()
        state.length += UInt64(data.count); remember(state, for: url)
    }
    func load(_ url: URL) throws -> LibraryReviewCheckpoint {
        let decoder = JSONDecoder(), data = try Data(contentsOf: url)
        guard let root = try? decoder.decode(Root.self, from: data) else {
            let legacy = try decoder.decode(LibraryReviewCheckpoint.self, from: data)
            guard legacy.schema == 1 else { throw PicardError.invalidConfiguration("This review checkpoint uses an unsupported version.") }
            return legacy
        }
        guard root.storageSchema == 2 else { throw PicardError.invalidConfiguration("This review checkpoint uses an unsupported version.") }
        var checkpoint = root.checkpoint
        guard checkpoint.schema == 1 else { throw PicardError.invalidConfiguration("This review checkpoint uses an unsupported version.") }
        var positions = Dictionary(uniqueKeysWithValues: checkpoint.run.proposals.enumerated().map { ($0.element.id, $0.offset) })
        let deltaURL = url.appendingPathExtension("jsonl")
        var length = 0
        if FileManager.default.fileExists(atPath: deltaURL.path) {
            let deltas = try Data(contentsOf: deltaURL)
            length = deltas.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
            for line in deltas.prefix(length).split(separator: 0x0A) {
                let delta = try decoder.decode(Delta.self, from: Data(line))
                guard delta.generation == root.generation else { continue }
                for proposal in delta.proposals {
                    if let index = positions[proposal.id] { checkpoint.run.proposals[index] = proposal }
                    else { positions[proposal.id] = checkpoint.run.proposals.count; checkpoint.run.proposals.append(proposal) }
                }
                checkpoint.run = AppModel.LibraryMatchRun(proposals: checkpoint.run.proposals, autoApplyThreshold: checkpoint.run.autoApplyThreshold, completedAt: delta.completedAt)
            }
        }
        remember(State(generation: root.generation, length: UInt64(length), positions: positions), for: url)
        return checkpoint
    }
}

enum ReleaseReference {
    static func identifier(_ text: String) throws -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let uuid = UUID(uuidString: text) { return uuid.uuidString.lowercased() }
        guard let url = URL(string: text), url.scheme == "https", ["musicbrainz.org", "www.musicbrainz.org"].contains(url.host?.lowercased() ?? ""),
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { throw MusicBrainzError.invalidIdentifier("Enter a release UUID or an HTTPS MusicBrainz release URL.") }
        let parts = url.path.split(separator: "/")
        guard parts.count == 2, parts[0] == "release", let uuid = UUID(uuidString: String(parts[1])) else {
            throw MusicBrainzError.invalidIdentifier("The URL must identify a release, not a recording or release group.")
        }
        return uuid.uuidString.lowercased()
    }
}

extension AppModel {
    var checkpointLocation: URL? {
        if let reviewCheckpointURL { return reviewCheckpointURL }
        guard let id = activeWorkspaceID, let paths = snapshot?.paths else { return nil }
        return paths.applicationSupportDirectory.appendingPathComponent("ReviewJobs").appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    func startLibraryMatch(threshold: Double, resume: Bool = false) {
        guard !isBusy else { return }
        libraryMatchTask = Task { [weak self] in await self?.runLibraryMatch(threshold: threshold, resume: resume) }
    }
    func cancelLibraryMatch() { libraryMatchTask?.cancel() }

    func restoreReviewCheckpoint() async {
        guard libraryMatchRun == nil, let url = checkpointLocation, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let checkpoint = try await ReviewCheckpointStore.shared.load(url)
            guard checkpoint.workspaceID == activeWorkspaceID, checkpoint.country == configuration.preferredReleaseCountry else {
                recordActivity("A saved review belongs to different matching preferences; run again."); return
            }
            libraryMatchRun = checkpoint.run
            recordActivity("Restored review results. Stale proposals must be looked up again; nothing was applied.")
        } catch { present(error) }
    }

    func runLibraryMatch(threshold: Double, resume: Bool = false) async {
        guard !isBusy, let musicBrainzClient, let workspaceID = activeWorkspaceID, activeWorkspace?.kind == .library else { return }
        guard (0.60...0.95).contains(threshold) else { present(PicardError.invalidConfiguration("The matching threshold must be 60–95%.")); return }
        isWorking = true; progress = 0; errorMessage = nil
        defer { isWorking = false; progress = nil }
        let country = configuration.preferredReleaseCountry
        let groups = orderedAlbumGroups
        let groupsByID = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var proposals: [LibraryMatchProposal] = []
        if resume, let url = checkpointLocation, let checkpoint = try? await ReviewCheckpointStore.shared.load(url),
           checkpoint.workspaceID == workspaceID, checkpoint.country == country, checkpoint.run.autoApplyThreshold == threshold {
            proposals = checkpoint.run.proposals.filter { proposal in
                groupsByID[proposal.id]?.fileIDs == proposal.fileIDs
                    && !proposal.baselines.isEmpty && proposal.baselines.allSatisfy { $0.matches(file(id: $0.id)) }
            }
        }
        let completed = Set(proposals.map(\.id))
        libraryMatchRun = LibraryMatchRun(proposals: proposals, autoApplyThreshold: threshold, completedAt: Date())
        if let url = checkpointLocation, let run = libraryMatchRun {
            do { try await ReviewCheckpointStore.shared.reset(LibraryReviewCheckpoint(workspaceID: workspaceID, country: country, groups: groups, run: run), to: url) }
            catch { present(error); return }
        }
        let matcher = ReleaseMatcher(preferences: releaseMatchPreferences)
        for (offset, group) in groups.enumerated() where !completed.contains(group.id) {
            if Task.isCancelled || workspaceID != activeWorkspaceID { break }
            let targets = group.fileIDs.compactMap { file(id: $0) }
            guard let primary = targets.first else { continue }
            let baselines = targets.map(ReviewFileBaseline.init)
            statusMessage = "Matching \(offset + 1)/\(groups.count): \(group.title)"
            let local = LocalAlbumCandidate(metadata: primary.metadata, tracks: targets.map { Self.localCandidate($0) })
            var proposal: LibraryMatchProposal
            do {
                let summaries = try await musicBrainzClient.searchReleases(for: local, limit: 10)
                var releases: [MusicBrainzRelease] = []
                let ranked = try await BackgroundComputation.run { matcher.rank(local: local, candidates: summaries) }
                for candidate in ranked.prefix(3) {
                    try Task.checkCancellation()
                    do { releases.append(try await musicBrainzClient.lookupRelease(id: candidate.release.id)) }
                    catch is CancellationError { throw CancellationError() }
                    catch { recordActivity("A release variant could not be loaded; other variants will still be reviewed.") }
                }
                let details = releases
                let result = try await BackgroundComputation.run { matcher.rank(local: local, candidates: details).first }
                try Task.checkCancellation()
                let release = releases.first { $0.id == result?.release.id }
                proposal = LibraryMatchProposal(id: group.id, albumTitle: group.title, artist: group.artist, fileIDs: group.fileIDs,
                    result: result, release: release, status: .review, errorMessage: result == nil ? "No detailed release match found." : nil, baselines: baselines)
                if result == nil { proposal.status = .noMatch }
                else if Self.proposalMeetsThreshold(proposal, threshold: threshold) { proposal.status = .matched }
            } catch is CancellationError { break }
            catch {
                if Task.isCancelled { break }
                proposal = LibraryMatchProposal(id: group.id, albumTitle: group.title, artist: group.artist, fileIDs: group.fileIDs,
                    result: nil, release: nil, status: .failed, errorMessage: error.localizedDescription, baselines: baselines)
            }
            guard workspaceID == activeWorkspaceID else { return }
            proposals.append(proposal)
            libraryMatchRun = LibraryMatchRun(proposals: proposals, autoApplyThreshold: threshold, completedAt: Date())
            progress = Double(proposals.count) / Double(max(1, groups.count))
            if let url = checkpointLocation, let run = libraryMatchRun {
                do { try await ReviewCheckpointStore.shared.save(LibraryReviewCheckpoint(workspaceID: workspaceID, country: country, groups: groups, run: run), to: url, changedProposalIDs: [proposal.id]) }
                catch { present(error); break }
            }
        }
        if libraryMatchRun == nil { libraryMatchRun = LibraryMatchRun(proposals: proposals, autoApplyThreshold: threshold, completedAt: Date()) }
        statusMessage = Task.isCancelled ? "Matching cancelled. Completed read results are checkpointed; no tags changed." : "Read \(proposals.count) album proposals. Review before staging; Save Tags remains separate."
    }

    static func proposalMeetsThreshold(_ proposal: LibraryMatchProposal, threshold: Double) -> Bool {
        guard let result = proposal.result, let release = proposal.release,
              result.score.total >= threshold, !result.score.identifierMismatch, result.decision != .rejected, result.decision != .ambiguous,
              result.trackMatches.count == proposal.fileIDs.count, release.tracks.count == proposal.fileIDs.count,
              Set(result.trackMatches.map(\.localTrackID)) == Set(proposal.fileIDs),
              result.trackMatches.allSatisfy({ $0.releaseTrackID != nil && [.matched, .exact].contains($0.decision) }),
              Set(result.trackMatches.compactMap(\.releaseTrackID)).count == result.trackMatches.count else { return false }
        return true
    }
    func isEligibleLibraryProposal(_ proposal: LibraryMatchProposal, validateBaseline: Bool = true) -> Bool {
        guard proposal.status == .matched, Self.proposalMeetsThreshold(proposal, threshold: libraryMatchRun?.autoApplyThreshold ?? configuration.editing.matchThreshold) else { return false }
        if !validateBaseline { return true }
        guard Set(proposal.baselines.map(\.id)) == Set(proposal.fileIDs), !proposal.baselines.isEmpty else { return false }
        return proposal.baselines.allSatisfy { $0.matches(file(id: $0.id)) }
    }
    func setProposalStatus(_ id: String, _ status: LibraryMatchProposalStatus) {
        guard let index = libraryMatchRun?.proposals.firstIndex(where: { $0.id == id }) else { return }
        libraryMatchRun?.proposals[index].status = status
        let run = libraryMatchRun, workspaceID = activeWorkspaceID, country = configuration.preferredReleaseCountry, groups = orderedAlbumGroups, url = checkpointLocation
        let previous = reviewCheckpointTask
        reviewCheckpointTask = Task {
            await previous?.value
            guard let run, let workspaceID, let url else { return }
            do { try await ReviewCheckpointStore.shared.save(LibraryReviewCheckpoint(workspaceID: workspaceID, country: country, groups: groups, run: run), to: url, changedProposalIDs: [id]) }
            catch { present(error) }
        }
    }
    func reviewNextLibraryProposal() async {
        guard !isBusy, let proposal = libraryMatchRun?.proposals.first(where: { [.review, .noMatch, .failed].contains($0.status) && $0.id != currentLibraryReviewID }) else { return }
        prepareLibraryProposalForReview(proposal)
        if let result = proposal.result { await chooseMatch(result) } else { await lookup() }
    }

    func loadReleaseReference(_ text: String) async {
        guard !isBusy, canLookupSelection, let musicBrainzClient else { return }
        do {
            let id = try ReleaseReference.identifier(text)
            isWorking = true
            let workspace = activeWorkspaceID, ids = selectedFileIDs, originals = selectedFiles
            let release = try await musicBrainzClient.lookupRelease(id: id)
            let local = LocalAlbumCandidate(metadata: originals.first?.metadata ?? Metadata(), tracks: originals.map { Self.localCandidate($0) })
            let matcher = ReleaseMatcher(preferences: releaseMatchPreferences)
            let result = try await BackgroundComputation.run { matcher.rank(local: local, candidates: [release]).first }
            isWorking = false
            guard activeWorkspaceID == workspace, selectedFileIDs == ids, originals.allSatisfy({ file(id: $0.id) == $0 }) else { return }
            if let result { await chooseMatch(result) }
        } catch { isWorking = false; present(error) }
    }

    func regroupSelected(album: String, artist: String) {
        guard canEditSelection, !album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var edited = files
        for index in edited.indices where selectedFileIDs.contains(edited[index].id) {
            var tags = edited[index].metadata
            tags.setValue(album, for: "album"); tags.setValue(artist, for: "albumartist")
            do { try edited[index].updateMetadata(tags) } catch { present(error); return }
        }
        commitStagedEdits(edited, action: "Regroup selected files")
        selectedAlbumID = self.album(containing: selectedFileIDs.first ?? UUID())?.id
    }
}
