import Foundation
import PicardFoundation
import PicardFingerprint
import PicardMusicBrainz
import XCTest
@testable import MacPicard

final class FingerprintWorkflowTests: XCTestCase {
    @MainActor
    func testOfflineGenerationIsBoundedCachedReadOnlyAndReportsCorruptFiles() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = CountingFingerprintProvider()
        let model = AppModel(); model.fingerprintProviderOverride = provider; model.fingerprintCacheDirectory = root.appendingPathComponent("cache")
        model.files = try (0..<5).map { try file(root: root, name: "\($0)") }
        let original = model.files, ids = Set(original.map(\.id))
        await model.runFingerprintScan(ids: ids, identify: false)
        XCTAssertEqual(model.files, original); XCTAssertEqual(model.fingerprintRun?.results.count, 5)
        let count = await provider.count, maximum = await provider.maximum
        XCTAssertEqual(count, 5); XCTAssertLessThanOrEqual(maximum, 2); XCTAssertGreaterThan(maximum, 1)
        await model.runFingerprintScan(ids: ids, identify: false)
        let cachedCount = await provider.count; XCTAssertEqual(cachedCount, 5)
        try Data("external change".utf8).write(to: original[0].url)
        await model.runFingerprintScan(ids: [original[0].id], identify: false)
        XCTAssertNotNil(model.fingerprintRun?.results.first?.error); XCTAssertEqual(model.files, original)
        let corrupt = try file(root: root, name: "corrupt")
        model.files = [corrupt]; await model.runFingerprintScan(ids: [corrupt.id], identify: false)
        XCTAssertNotNil(model.fingerprintRun?.results.first?.error); XCTAssertFalse(model.isWorking)
    }

    @MainActor
    func testIncorrectAndUntaggedAudioBecomeExplicitlyReviewableWithoutAutoApplying() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = FingerprintMusicBrainzTransport(), acoust = FingerprintAcoustTransport()
        let model = AppModel(musicBrainzClient: MusicBrainzClient(userAgent: "Tests/1.0", transport: transport, minimumRequestInterval: .zero))
        var configuration = model.configuration; configuration.automaticCoverArt = false; model.installConfiguration(configuration)
        model.fingerprintProviderOverride = CountingFingerprintProvider(); model.fingerprintCacheDirectory = root.appendingPathComponent("cache")
        model.acoustIDClientOverride = AcoustIDClient(apiKey: "fixture-key", userAgent: "Tests/1.0", transport: acoust, minimumRequestInterval: .zero)
        model.files = [try file(root: root, name: "wrong", title: "Wrong name"), try file(root: root, name: "unknown", title: "")]
        let original = model.files
        await model.runFingerprintScan(ids: Set(original.map(\.id)), identify: true)
        XCTAssertEqual(model.files, original)
        let results = try XCTUnwrap(model.fingerprintRun?.results); XCTAssertEqual(results.count, 2)
        for result in results {
            let candidate = try XCTUnwrap(result.candidates.first)
            XCTAssertEqual(candidate.fingerprintConfidence, 0.97)
            let opened = await model.reviewFingerprintCandidate(fileID: result.id, candidateID: candidate.id)
            XCTAssertTrue(opened); XCTAssertEqual(model.matchReview?.assignments[result.id], "remote-track")
            XCTAssertEqual(model.fingerprintReviewScores[result.id], 0.97)
            XCTAssertEqual(model.files, original, "Reviewing evidence must not stage tags")
        }
        XCTAssertTrue(model.applySelectedRelease())
        let approved = try XCTUnwrap(model.selectedFiles.first)
        XCTAssertEqual(approved.metadata.firstValue(for: "title"), "Song")
        XCTAssertEqual(model.verifiedRecordingMappings[approved.id], FingerprintMusicBrainzTransport.recordingID)
        XCTAssertEqual(try Data(contentsOf: approved.url), Data("fixture audio".utf8), "Apply is staged, never a disk write")
        model.sessionSaveTask?.cancel()
        let requests = await transport.requests
        XCTAssertTrue(requests.contains { $0.url?.lastPathComponent == "release" && URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "recording" && $0.value == FingerprintMusicBrainzTransport.recordingID }) == true })
    }

    @MainActor
    func testCancellationStopsBoundedGenerationAndLeavesTagsUntouched() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = CountingFingerprintProvider(delay: .seconds(30)), model = AppModel()
        model.fingerprintProviderOverride = provider; model.fingerprintCacheDirectory = root.appendingPathComponent("cache")
        model.files = try (0..<4).map { try file(root: root, name: "\($0)") }; model.selectedFileIDs = Set(model.files.map(\.id))
        let original = model.files; model.startFingerprintScan(identify: false)
        for _ in 0..<100 { if await provider.count > 0 { break }; try await Task.sleep(for: .milliseconds(10)) }
        model.cancelFingerprintOperation(); await model.fingerprintTask?.value
        XCTAssertEqual(model.files, original); XCTAssertFalse(model.isBusy); XCTAssertNil(model.errorMessage)
        let count = await provider.count; XCTAssertLessThanOrEqual(count, 2)
    }

    @MainActor
    func testSubmissionsRequireConsentVerifiedCurrentMappingsAndJournalUncertainWrites() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let acoust = FingerprintAcoustTransport(submissionStatus: 502), model = AppModel()
        model.files = [try file(root: root, name: "verified")]; let original = model.files[0]
        model.selectedFileIDs = [original.id]; model.fingerprintLedgerURL = root.appendingPathComponent("ledger.json")
        model.fingerprintProviderOverride = CountingFingerprintProvider(); model.fingerprintCacheDirectory = root.appendingPathComponent("cache")
        model.acoustIDClientOverride = AcoustIDClient(apiKey: "SECRET_KEY", userAgent: "Tests/1.0", transport: acoust, minimumRequestInterval: .zero)
        model.submissionTokenOverride = "SECRET_TOKEN"
        await model.runFingerprintScan(ids: [original.id], identify: false)
        model.prepareFingerprintSubmission(); XCTAssertNil(model.fingerprintSubmissionReview, "Unverified imported IDs are not submission authority")
        var edited = original, metadata = original.metadata; metadata.setValue(FingerprintMusicBrainzTransport.recordingID, for: "musicbrainz_trackid"); try edited.updateMetadata(metadata)
        model.files = [edited]; model.verifiedRecordingMappings[original.id] = FingerprintMusicBrainzTransport.recordingID
        model.prepareFingerprintSubmission(); XCTAssertNil(model.fingerprintSubmissionReview, "Changed tag baseline requires regeneration")
        await model.runFingerprintScan(ids: [original.id], identify: false)
        model.prepareFingerprintSubmission(); let review = try XCTUnwrap(model.fingerprintSubmissionReview)
        await model.submitReviewedFingerprints(reviewID: review.id, consent: false)
        let before = await acoust.submissions; XCTAssertEqual(before, 0)
        await model.submitReviewedFingerprints(reviewID: review.id, consent: true)
        let first = await acoust.submissions; XCTAssertEqual(first, 1)
        XCTAssertTrue(model.fingerprintSubmissionOutcomes[original.id]?.contains("Uncertain") == true)
        await model.submitReviewedFingerprints(reviewID: review.id, consent: true)
        let repeatCount = await acoust.submissions; XCTAssertEqual(repeatCount, 1)
        XCTAssertFalse((model.errorMessage ?? "").contains("SECRET"))
        XCTAssertFalse(try String(contentsOf: root.appendingPathComponent("ledger.json"), encoding: .utf8).contains("SECRET"))
        model.selectionChanged([original.id]); model.setMetadata("genre", value: "new")
        await model.submitReviewedFingerprints(reviewID: review.id, consent: true)
        let staleCount = await acoust.submissions; XCTAssertEqual(staleCount, 1)
        model.sessionSaveTask?.cancel()
    }

    @MainActor
    func testScanCancellationStopsServiceReadAndNeverPublishesFailure() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = CancellingFingerprintTransport()
        let model = AppModel(musicBrainzClient: MusicBrainzClient(userAgent: "Tests/1.0", transport: FingerprintMusicBrainzTransport(), minimumRequestInterval: .zero))
        model.fingerprintProviderOverride = CountingFingerprintProvider(); model.fingerprintCacheDirectory = root.appendingPathComponent("cache")
        model.acoustIDClientOverride = AcoustIDClient(apiKey: "fixture-key", userAgent: "Tests/1.0", transport: transport, minimumRequestInterval: .zero)
        model.files = [try file(root: root, name: "cancel")]; model.selectedFileIDs = [model.files[0].id]
        let original = model.files; model.startFingerprintScan()
        for _ in 0..<100 { if await transport.started { break }; try await Task.sleep(for: .milliseconds(10)) }
        model.cancelFingerprintOperation(); await model.fingerprintTask?.value
        let started = await transport.started; XCTAssertTrue(started)
        XCTAssertNil(model.errorMessage); XCTAssertFalse(model.isBusy); XCTAssertEqual(model.files, original)
    }

    @MainActor
    func testMissingToolSetupIsRecoverableAndReadOnly() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(); model.files = [try file(root: root, name: "missing")]
        var configuration = model.configuration; configuration.editing.fpcalcPath = root.appendingPathComponent("does-not-exist").path; model.installConfiguration(configuration)
        let original = model.files
        await model.runFingerprintScan(ids: [original[0].id], identify: false)
        XCTAssertNotNil(model.errorMessage); XCTAssertFalse(model.isWorking); XCTAssertEqual(model.files, original)
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    private func file(root: URL, name: String, title: String = "Wrong name") throws -> AudioFile {
        let url = root.appendingPathComponent(name + ".flac"); try Data("fixture audio".utf8).write(to: url)
        var file = AudioFile(url: url); try file.beginLoading()
        try file.finishLoading(metadata: Metadata(fields: ["title": [title], "artist": ["Wrong artist"], "album": ["Wrong album"]]), identity: AudioFileIdentity.capture(url: url), durationInMilliseconds: 180_000)
        return file
    }
}

private actor CancellingFingerprintTransport: AcoustIDTransport {
    var started = false
    func data(for request: URLRequest) async throws -> AcoustIDHTTPResponse {
        started = true; try await Task.sleep(for: .seconds(30))
        return AcoustIDHTTPResponse(statusCode: 200, data: Data())
    }
}

private actor CountingFingerprintProvider: AudioFingerprintProviding {
    var count = 0, active = 0, maximum = 0
    let delay: Duration
    init(delay: Duration = .milliseconds(40)) { self.delay = delay }
    func fingerprint(url: URL) async throws -> AudioFingerprint {
        count += 1; active += 1; maximum = max(maximum, active); defer { active -= 1 }
        try await Task.sleep(for: delay)
        if url.lastPathComponent.contains("corrupt") { throw FingerprintError.processFailed(1, "PRIVATE_DIAGNOSTIC") }
        return AudioFingerprint(fingerprint: "AQAB", durationInSeconds: 180)
    }
}

private actor FingerprintAcoustTransport: AcoustIDTransport {
    let submissionStatus: Int
    var submissions = 0
    init(submissionStatus: Int = 200) { self.submissionStatus = submissionStatus }
    func data(for request: URLRequest) async throws -> AcoustIDHTTPResponse {
        if request.url?.lastPathComponent == "submit" {
            submissions += 1
            return AcoustIDHTTPResponse(statusCode: submissionStatus, data: submissionStatus == 200 ? Data(#"{"status":"ok"}"#.utf8) : Data("SECRET_SERVER_RESPONSE".utf8))
        }
        return AcoustIDHTTPResponse(statusCode: 200, data: Data(#"{"status":"ok","results":[{"id":"acoust-result","score":0.97,"recordings":[{"id":"22222222-2222-2222-2222-222222222222","title":"Song"}]}]}"#.utf8))
    }
}

private actor FingerprintMusicBrainzTransport: MusicBrainzTransport {
    static let recordingID = "22222222-2222-2222-2222-222222222222"
    var requests: [URLRequest] = []
    func data(for request: URLRequest) async throws -> MusicBrainzHTTPResponse {
        requests.append(request)
        let release = #"{"id":"11111111-1111-1111-1111-111111111111","title":"Album","artist-credit":[{"name":"Artist"}],"media":[{"position":1,"tracks":[{"id":"remote-track","number":"1","position":1,"title":"Song","length":180000,"artist-credit":[{"name":"Artist"}],"recording":{"id":"22222222-2222-2222-2222-222222222222"}}]}]}"#
        let data = request.url?.lastPathComponent == "release" ? "{\"releases\":[\(release)]}" : release
        return MusicBrainzHTTPResponse(statusCode: 200, data: Data(data.utf8))
    }
}
