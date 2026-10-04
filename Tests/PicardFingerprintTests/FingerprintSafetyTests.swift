import Foundation
import PicardFoundation
import XCTest
@testable import PicardFingerprint

final class FingerprintSafetyTests: XCTestCase {
    func testCacheInvalidatesChangedIdentityAndCalculatorVersion() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("test.flac"); try Data("audio".utf8).write(to: audio)
        let identity = try AudioFileIdentity.capture(url: audio), cache = FingerprintCache(directory: root.appendingPathComponent("cache"))
        let fingerprint = AudioFingerprint(fingerprint: "AQAB", durationInSeconds: 180)
        try await cache.store(fingerprint, url: audio, identity: identity, version: "1")
        let hit = try await cache.cached(url: audio, identity: identity, version: "1")
        XCTAssertEqual(hit, fingerprint)
        let otherVersion = try await cache.cached(url: audio, identity: identity, version: "2")
        XCTAssertNil(otherVersion)
        try Data("changed audio".utf8).write(to: audio)
        let changed = try await cache.cached(url: audio, identity: AudioFileIdentity.capture(url: audio), version: "1")
        XCTAssertNil(changed)
        let entry = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("cache"), includingPropertiesForKeys: nil).first)
        try Data("truncated".utf8).write(to: entry)
        let corrupt = try await cache.cached(url: audio, identity: identity, version: "1")
        XCTAssertNil(corrupt)
    }

    func testSubmissionLedgerPersistsIntentAndBlocksAcceptedAndUncertainRepeatsWithoutRawSecrets() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("ledger.json"), fingerprint = AudioFingerprint(fingerprint: "PRIVATE_FINGERPRINT", durationInSeconds: 180)
        let ledger = FingerprintSubmissionLedger(url: url)
        let claimed = try await ledger.claim(fingerprint: fingerprint, recordingID: "recording")
        let key = try XCTUnwrap(claimed)
        let interrupted = try await FingerprintSubmissionLedger(url: url).claim(fingerprint: fingerprint, recordingID: "recording")
        XCTAssertNil(interrupted)
        try await ledger.finish(key, accepted: false)
        let uncertain = try await FingerprintSubmissionLedger(url: url).claim(fingerprint: fingerprint, recordingID: "recording")
        XCTAssertNil(uncertain)
        try await ledger.finish(key, accepted: true)
        let accepted = try await FingerprintSubmissionLedger(url: url).claim(fingerprint: fingerprint, recordingID: "recording")
        XCTAssertNil(accepted)
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("PRIVATE_FINGERPRINT"))
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testCancellationTerminatesCalculatorWithoutBlockingAwaiter() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("fpcalc"), audio = root.appendingPathComponent("audio.flac")
        try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try Data("fixture".utf8).write(to: audio)
        let task = Task { try await ChromaprintFingerprintProvider(executableURL: executable).fingerprint(url: audio) }
        try await Task.sleep(for: .milliseconds(100))
        let start = ContinuousClock.now; task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        XCTAssertLessThan(start.duration(to: .now), .seconds(3))
    }

    func testCalculatorFailureDoesNotExposeDiagnosticPayload() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("fpcalc"), audio = root.appendingPathComponent("audio.flac")
        try Data("#!/bin/sh\nprintf 'PRIVATE_SECRET' >&2\nexit 1\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try Data("fixture".utf8).write(to: audio)
        do { _ = try await ChromaprintFingerprintProvider(executableURL: executable).fingerprint(url: audio); XCTFail("Expected failure") }
        catch { XCTAssertFalse(error.localizedDescription.contains("PRIVATE_SECRET")) }
    }

    func testOfficialCalculatorOnRealAudioWhenConfigured() async throws {
        guard let path = ProcessInfo.processInfo.environment["MACPICARD_FPCALC_TEST_PATH"],
              let audio = ProcessInfo.processInfo.environment["MACPICARD_FPCALC_TEST_AUDIO"] else { throw XCTSkip("Set official fpcalc and generated audio fixture paths for real-tool validation") }
        let executable = URL(fileURLWithPath: path)
        let version = try await ChromaprintFingerprintProvider.version(executableURL: executable)
        XCTAssertTrue(version.contains("fpcalc"))
        let result = try await ChromaprintFingerprintProvider(executableURL: executable).fingerprint(url: URL(fileURLWithPath: audio))
        XCTAssertFalse(result.fingerprint.isEmpty); XCTAssertGreaterThan(result.durationInSeconds, 10)
        if let formats = ProcessInfo.processInfo.environment["MACPICARD_FPCALC_TEST_FORMATS"] {
            for ext in ["mp3", "m4a", "ogg", "opus", "wav"] {
                let fingerprint = try await ChromaprintFingerprintProvider(executableURL: executable).fingerprint(url: URL(fileURLWithPath: formats).appendingPathComponent("fixture." + ext))
                XCTAssertFalse(fingerprint.fingerprint.isEmpty, ext); XCTAssertGreaterThan(fingerprint.durationInSeconds, 10, ext)
            }
        }
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let corrupt = root.appendingPathComponent("corrupt.flac"); try Data("not audio".utf8).write(to: corrupt)
        do { _ = try await ChromaprintFingerprintProvider(executableURL: executable).fingerprint(url: corrupt); XCTFail("Corrupt audio must be rejected") }
        catch { XCTAssertTrue(error is FingerprintError) }
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
}
