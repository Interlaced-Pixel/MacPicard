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

    func testBundledCalculatorWorksWithoutConfigurationOnGeneratedWAV() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("first-launch.wav")
        let original = waveFixture(); try original.write(to: audio)
        let executable = try ChromaprintFingerprintProvider.bundledExecutableURL()
        XCTAssertFalse(executable.path.contains("/opt/homebrew/"))
        XCTAssertFalse(executable.path.contains("/usr/local/"))
        let version = try await ChromaprintFingerprintProvider.version(executableURL: executable)
        XCTAssertTrue(version.contains("1.6.1"))
        let result = try await ChromaprintFingerprintProvider().fingerprint(url: audio)
        XCTAssertFalse(result.fingerprint.isEmpty)
        XCTAssertEqual(result.durationInSeconds, 30, accuracy: 0.1)
        XCTAssertEqual(try Data(contentsOf: audio), original)
        let corrupt = root.appendingPathComponent("corrupt.wav"); try Data("broken audio".utf8).write(to: corrupt)
        do { _ = try await ChromaprintFingerprintProvider().fingerprint(url: corrupt); XCTFail("Expected rejection") }
        catch { XCTAssertTrue(error is FingerprintError) }
    }

    func testInstalledAppDoesNotFallbackOutsideItsBundle() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try fixtureBundle(root: root)
        XCTAssertThrowsError(try ChromaprintFingerprintProvider.bundledExecutableURL(in: bundle)) { error in
            XCTAssertFalse(error.localizedDescription.contains("Homebrew"))
            XCTAssertTrue(error.localizedDescription.contains("Reinstall MacPicard"))
        }
    }

    func testPublisherConfigurationLoadsOnlyFromAppResourcesAndRedactsInvalidValues() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try fixtureBundle(root: root)
        XCTAssertThrowsError(try AcoustIDApplicationConfiguration.applicationKey(in: bundle))
        let url = bundle.resourceURL!.appendingPathComponent("AcoustID.plist")
        try PropertyListSerialization.data(fromPropertyList: ["ApplicationKey": "FixtureAppKey123"], format: .xml, options: 0).write(to: url)
        XCTAssertEqual(try AcoustIDApplicationConfiguration.applicationKey(in: bundle), "FixtureAppKey123")
        for invalid in ["", "PRIVATE_INVALID_KEY!", " Contains spaces ", String(repeating: "a", count: 257)] {
            try PropertyListSerialization.data(fromPropertyList: ["ApplicationKey": invalid], format: .xml, options: 0).write(to: url)
            XCTAssertThrowsError(try AcoustIDApplicationConfiguration.applicationKey(in: bundle)) { error in
                if !invalid.isEmpty { XCTAssertFalse(error.localizedDescription.contains(invalid)) }
                XCTAssertFalse(error.localizedDescription.contains("Settings"))
            }
        }
    }

    private func fixtureBundle(root: URL) throws -> Bundle {
        let app = root.appendingPathComponent("Fixture.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "com.interlacedpixel.test." + UUID().uuidString, "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        return try XCTUnwrap(Bundle(url: app))
    }

    /// Deterministic PCM audio generated in Swift; no fixture encoder or external software needed.
    private func waveFixture() -> Data {
        let rate = 22_050, count = rate * 30
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        data.append(Data("RIFF".utf8)); append(UInt32(36 + count * 2)); data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(rate)); append(UInt32(rate * 2))
        append(UInt16(2)); append(UInt16(16)); data.append(Data("data".utf8)); append(UInt32(count * 2))
        for sample in 0..<count { append(Int16(sin(Double(sample) * 2 * .pi * 440 / Double(rate)) * 12_000)) }
        return data
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
}
