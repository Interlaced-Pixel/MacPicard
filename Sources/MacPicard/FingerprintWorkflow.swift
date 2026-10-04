import Foundation
import PicardFingerprint
import PicardFoundation
import PicardMusicBrainz

struct FingerprintCandidate: Identifiable, Sendable {
    let recordingID: String
    let fingerprintConfidence: Double
    let release: MusicBrainzRelease
    let result: ReleaseMatchResult
    var id: String { release.id + ":" + recordingID }
}

struct FingerprintFileResult: Identifiable, Sendable {
    let baseline: ReviewFileBaseline
    let fingerprint: AudioFingerprint?
    let candidates: [FingerprintCandidate]
    let error: String?
    var id: UUID { baseline.id }
}

struct FingerprintRun: Identifiable, Sendable {
    let id: UUID
    let workspaceID: UUID?
    let identifying: Bool
    var results: [FingerprintFileResult]
    var completed: Bool
}

struct FingerprintSubmissionItem: Identifiable, Sendable {
    let baseline: ReviewFileBaseline
    let fingerprint: AudioFingerprint
    let recordingID: String
    var id: UUID { baseline.id }
}

struct FingerprintSubmissionReview: Identifiable, Sendable {
    let id = UUID()
    let workspaceID: UUID?
    let items: [FingerprintSubmissionItem]
}

actor FingerprintScanProcessor {
    let provider: any AudioFingerprintProviding
    let cache: FingerprintCache
    let version: String
    let acoustID: AcoustIDClient?
    let musicBrainz: MusicBrainzClient?
    init(provider: any AudioFingerprintProviding, cache: FingerprintCache, version: String, acoustID: AcoustIDClient?, musicBrainz: MusicBrainzClient?) {
        self.provider = provider; self.cache = cache; self.version = version; self.acoustID = acoustID; self.musicBrainz = musicBrainz
    }
    func process(_ file: AudioFile, identify: Bool) async throws -> FingerprintFileResult {
        try Task.checkCancellation()
        let identity = try AudioFileIdentity.capture(url: file.url)
        guard file.identity?.matches(identity) == true else { throw FingerprintError.invalidInput("This file changed on disk. Refresh it before scanning.") }
        let fingerprint: AudioFingerprint
        if let cached = try await cache.cached(url: file.url, identity: identity, version: version) { fingerprint = cached }
        else {
            fingerprint = try await provider.fingerprint(url: file.url)
            try Task.checkCancellation()
            guard !fingerprint.fingerprint.isEmpty, fingerprint.durationInSeconds.isFinite,
                  fingerprint.durationInSeconds > 0, fingerprint.durationInSeconds < Double(Int32.max) / 1_000 else { throw FingerprintError.invalidOutput("Invalid duration or empty fingerprint.") }
            guard identity.matches(try AudioFileIdentity.capture(url: file.url)) else { throw FingerprintError.invalidInput("Audio changed while calculating. Refresh and retry.") }
            try await cache.store(fingerprint, url: file.url, identity: identity, version: version)
        }
        var candidates: [FingerprintCandidate] = []
        if identify {
            guard let acoustID, let musicBrainz else { throw FingerprintError.unavailable("Identification service configuration is unavailable in this build. Contact Interlaced Pixel.") }
            let matches = try await acoustID.lookup(fingerprint)
            var releasesByID: [String: MusicBrainzRelease] = [:]
            for match in matches.sorted(by: { $0.score > $1.score }).prefix(3) {
                guard match.score.isFinite, (0...1).contains(match.score) else { continue }
                for recording in match.recordings.prefix(3) {
                    guard UUID(uuidString: recording.id) != nil else { continue }
                    var releaseIDs = recording.releaseIDs
                    if releaseIDs.isEmpty { releaseIDs = try await musicBrainz.releasesForRecording(id: recording.id).map(\.id) }
                    for releaseID in releaseIDs.prefix(5) {
                        try Task.checkCancellation()
                        guard UUID(uuidString: releaseID) != nil, candidates.count < 8 else { continue }
                        let release: MusicBrainzRelease
                        if let existing = releasesByID[releaseID] { release = existing }
                        else { release = try await musicBrainz.lookupRelease(id: releaseID); releasesByID[releaseID] = release }
                        guard release.tracks.contains(where: { $0.recordingID == recording.id }), !candidates.contains(where: { $0.recordingID == recording.id && $0.release.id == release.id }) else { continue }
                        let local = LocalTrackCandidate(id: file.id, title: file.metadata.firstValue(for: "title") ?? "",
                            artist: file.metadata.firstValue(for: "artist"), durationInMilliseconds: Int(fingerprint.durationInSeconds * 1_000), recordingID: recording.id)
                        let album = LocalAlbumCandidate(metadata: file.metadata, tracks: [local])
                        if let result = ReleaseMatcher().rank(local: album, candidates: [release]).first {
                            candidates.append(FingerprintCandidate(recordingID: recording.id, fingerprintConfidence: match.score, release: release, result: result))
                        }
                    }
                }
            }
        }
        return FingerprintFileResult(baseline: ReviewFileBaseline(file), fingerprint: fingerprint, candidates: candidates, error: nil)
    }
}

extension AppModel {
    func startFingerprintScan(scope: WorkspaceScope = .selection, identify: Bool = true) {
        guard !isBusy else { return }
        let ids = commandFileIDs(scope)
        guard !ids.isEmpty else { return }
        fingerprintJobIsScheduled = true
        fingerprintTask = Task { [weak self] in
            await self?.runFingerprintScan(ids: ids, identify: identify)
            self?.fingerprintJobIsScheduled = false
        }
    }
    func cancelFingerprintOperation() { fingerprintTask?.cancel() }

    func fingerprintClient() async throws -> AcoustIDClient {
        if let acoustIDClientOverride { return acoustIDClientOverride }
        let key = try AcoustIDApplicationConfiguration.applicationKey()
        return AcoustIDClient(apiKey: key, userAgent: configuration.requestUserAgent)
    }

    private func scanProcessor(identify: Bool) async throws -> FingerprintScanProcessor {
        let provider: any AudioFingerprintProviding
        let version: String
        if let fingerprintProviderOverride { provider = fingerprintProviderOverride; version = "injected-test-provider-algorithm2" }
        else {
            let executable = try ChromaprintFingerprintProvider.bundledExecutableURL()
            version = try await ChromaprintFingerprintProvider.version(executableURL: executable)
            provider = ChromaprintFingerprintProvider(executableURL: executable)
        }
        guard let directory = fingerprintCacheDirectory ?? snapshot?.paths.cacheDirectory.appendingPathComponent("Fingerprints") else {
            throw FingerprintError.unavailable("The workspace cache directory is unavailable. Restart the app.")
        }
        let client = identify ? try await fingerprintClient() : nil
        return FingerprintScanProcessor(provider: provider, cache: FingerprintCache(directory: directory), version: version, acoustID: client, musicBrainz: musicBrainzClient)
    }

    func runFingerprintScan(ids: Set<UUID>, identify: Bool) async {
        guard !isWorking, !isSwitchingWorkspace, !isLoading, !isPreparingOrganization else { return }
        let targets = files.filter { ids.contains($0.id) }
        guard !targets.isEmpty else { return }
        isWorking = true; progress = 0; errorMessage = nil
        let generation = UUID(), workspaceID = activeWorkspaceID
        fingerprintRun = FingerprintRun(id: generation, workspaceID: workspaceID, identifying: identify, results: [], completed: false)
        defer { isWorking = false; progress = nil }
        do {
            let processor = try await scanProcessor(identify: identify)
            try Task.checkCancellation()
            statusMessage = identify ? "Identifying \(targets.count) audio files…" : "Generating \(targets.count) local fingerprints…"
            try await withThrowingTaskGroup(of: FingerprintFileResult.self) { group in
                var next = 0
                func add(_ file: AudioFile) {
                    group.addTask {
                        do { return try await processor.process(file, identify: identify) }
                        catch is CancellationError { throw CancellationError() }
                        catch { return FingerprintFileResult(baseline: ReviewFileBaseline(file), fingerprint: nil, candidates: [], error: Self.safeFingerprintError(error)) }
                    }
                }
                for _ in 0..<min(2, targets.count) { add(targets[next]); next += 1 }
                while let result = try await group.next() {
                    try Task.checkCancellation()
                    guard activeWorkspaceID == workspaceID, fingerprintRun?.id == generation else { group.cancelAll(); throw CancellationError() }
                    fingerprintRun?.results.append(result)
                    progress = Double(fingerprintRun?.results.count ?? 0) / Double(targets.count)
                    if next < targets.count { add(targets[next]); next += 1 }
                }
            }
            fingerprintRun?.completed = true
            statusMessage = "\(identify ? "Scan" : "Generation") finished for \(targets.count) files. Metadata remains unchanged; review candidates explicitly."
        } catch is CancellationError {
            fingerprintRun?.completed = true
            statusMessage = "Fingerprint operation cancelled. Completed local cache entries are retained; no tags changed."
        } catch {
            fingerprintRun?.completed = true
            errorMessage = Self.safeFingerprintError(error)
        }
    }

    nonisolated static func safeFingerprintError(_ error: Error) -> String {
        if let error = error as? FingerprintError {
            switch error {
            case .authenticationRequired, .consentRequired: return error.localizedDescription
            case let .unavailable(message): return message
            case .invalidInput: return "The file is unavailable, changed, or has invalid audio. Refresh it and retry explicitly."
            case .processFailed: return "The built-in calculator could not decode this file. Check the audio, then retry."
            case .invalidOutput: return "The built-in calculator returned an invalid fingerprint. Check the audio or reinstall MacPicard."
            case let .httpStatus(code, _): return "AcoustID returned HTTP \(code). Check network access and credentials."
            case .network: return "The fingerprint service could not be reached. Retry the read explicitly."
            case .invalidResponse: return "The fingerprint service returned an invalid response. Check credentials and retry the read."
            }
        }
        if error is MusicBrainzError { return "The MusicBrainz release could not be resolved. Retry the scan or load a release manually." }
        return "Fingerprint processing failed. Check the audio, cache access, and network connection."
    }

    func reviewFingerprintCandidate(fileID: UUID, candidateID: String) async -> Bool {
        guard !isBusy, let run = fingerprintRun, run.workspaceID == activeWorkspaceID,
              let item = run.results.first(where: { $0.id == fileID }), item.baseline.matches(file(id: fileID)),
              let candidate = item.candidates.first(where: { $0.id == candidateID }) else { return false }
        searchQuery = ""; applyBrowserSearch(); browserFilter = .all
        selectedAlbumID = album(containing: fileID)?.id
        selectionChanged([fileID]); matchResults = [candidate.result]; lookupResults = [candidate.release.summary]
        await chooseMatch(candidate.result, recordingEvidence: [fileID: candidate.recordingID])
        guard matchReview != nil else { return false }
        fingerprintReviewScores = [fileID: candidate.fingerprintConfidence]
        return true
    }

    func prepareFingerprintSubmission(scope: WorkspaceScope = .selection) {
        guard !isBusy, let run = fingerprintRun, run.workspaceID == activeWorkspaceID else { return }
        let ids = commandFileIDs(scope)
        let items = run.results.compactMap { result -> FingerprintSubmissionItem? in
            guard ids.contains(result.id), let fingerprint = result.fingerprint, let file = file(id: result.id), result.baseline.matches(file),
                  let recordingID = verifiedRecordingMappings[file.id], UUID(uuidString: recordingID) != nil,
                  file.metadata.firstValue(for: "musicbrainz_trackid") == recordingID else { return nil }
            return FingerprintSubmissionItem(baseline: ReviewFileBaseline(file), fingerprint: fingerprint, recordingID: recordingID)
        }
        guard !items.isEmpty else {
            statusMessage = "No verified current fingerprints. Apply reviewed MusicBrainz mappings, generate fingerprints again, then select those files for submission."; return
        }
        fingerprintSubmissionReview = FingerprintSubmissionReview(workspaceID: activeWorkspaceID, items: items)
        fingerprintSubmissionOutcomes.removeAll()
    }

    func submitReviewedFingerprints(reviewID: UUID, consent: Bool) async {
        guard consent else { errorMessage = FingerprintError.consentRequired.localizedDescription; return }
        guard !isBusy, let review = fingerprintSubmissionReview, review.id == reviewID, review.workspaceID == activeWorkspaceID,
              review.items.allSatisfy({ $0.baseline.matches(file(id: $0.id)) && verifiedRecordingMappings[$0.id] == $0.recordingID }) else {
            statusMessage = "Submission review is stale. Regenerate and review the batch again."; return
        }
        isWorking = true; errorMessage = nil
        defer { isWorking = false; progress = nil }
        do {
            let client = try await fingerprintClient()
            let token: String?
            if let submissionTokenOverride { token = submissionTokenOverride }
            else if let runtime, let data = try await runtime.keychain.data(for: ServiceCredential.submissionToken.rawValue) { token = String(data: data, encoding: .utf8) }
            else { token = nil }
            guard let token, !token.isEmpty else { throw FingerprintError.authenticationRequired }
            guard let url = fingerprintLedgerURL ?? snapshot?.paths.applicationSupportDirectory.appendingPathComponent("Submissions/ledger.json") else { throw FingerprintError.unavailable("Submission journal directory is unavailable.") }
            let ledger = FingerprintSubmissionLedger(url: url)
            for (offset, item) in review.items.enumerated() {
                try Task.checkCancellation()
                guard review.workspaceID == activeWorkspaceID, item.baseline.matches(file(id: item.id)) else { break }
                let identity = try await Task.detached { try AudioFileIdentity.capture(url: item.baseline.url) }.value
                guard item.baseline.identity?.matches(identity) == true else { fingerprintSubmissionOutcomes[item.id] = "Audio changed; not sent"; continue }
                guard let key = try await ledger.claim(fingerprint: item.fingerprint, recordingID: item.recordingID) else {
                    fingerprintSubmissionOutcomes[item.id] = "Previously accepted or uncertain; not sent again"; continue
                }
                do {
                    try await client.submit(AcoustIDSubmission(fingerprint: item.fingerprint.fingerprint, durationInSeconds: item.fingerprint.durationInSeconds, recordingID: item.recordingID), userToken: token, consentGiven: true)
                    try await ledger.finish(key, accepted: true)
                    fingerprintSubmissionOutcomes[item.id] = "Accepted"
                } catch {
                    try? await ledger.finish(key, accepted: false)
                    fingerprintSubmissionOutcomes[item.id] = "Uncertain outcome; not automatically retried"
                    if error is CancellationError { throw error }
                    errorMessage = Self.safeFingerprintError(error)
                    break
                }
                progress = Double(offset + 1) / Double(review.items.count)
            }
            statusMessage = "Submission batch finished. Read each outcome; uncertain attempts require verification with AcoustID, never automatic retry."
        } catch is CancellationError { statusMessage = "Submission cancelled. Any attempted write remains journaled and is not automatically retried." }
        catch { errorMessage = Self.safeFingerprintError(error) }
    }
}
