import CryptoKit
import Foundation
import PicardFoundation

public actor FingerprintCache {
    private struct Entry: Codable {
        let identity: AudioFileIdentity
        let calculatorVersion: String
        let fingerprint: AudioFingerprint
    }
    private let directory: URL
    public init(directory: URL) { self.directory = directory }
    public func cached(url: URL, identity: AudioFileIdentity, version: String) throws -> AudioFingerprint? {
        let path = fileURL(url, version: version)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        guard let entry = try? JSONDecoder().decode(Entry.self, from: Data(contentsOf: path)), entry.identity.matches(identity), entry.calculatorVersion == version else { return nil }
        guard entry.fingerprint.durationInSeconds.isFinite, entry.fingerprint.durationInSeconds > 0,
              entry.fingerprint.durationInSeconds < Double(Int32.max) / 1_000, !entry.fingerprint.fingerprint.isEmpty else { return nil }
        return entry.fingerprint
    }
    public func store(_ fingerprint: AudioFingerprint, url: URL, identity: AudioFileIdentity, version: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = fileURL(url, version: version)
        try JSONEncoder().encode(Entry(identity: identity, calculatorVersion: version, fingerprint: fingerprint)).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
    private func fileURL(_ url: URL, version: String) -> URL {
        let key = Self.digest(url.standardizedFileURL.path + "\n" + version + "\nalgorithm=2,length=120")
        return directory.appendingPathComponent(key).appendingPathExtension("json")
    }
    public static func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
}

public actor FingerprintSubmissionLedger {
    private let url: URL
    private var entries: [String: String]?
    public init(url: URL) { self.url = url }
    /// Persist intent before sending a non-idempotent write. Uncertain attempts are never retried automatically.
    public func claim(fingerprint: AudioFingerprint, recordingID: String) throws -> String? {
        try load()
        let key = FingerprintCache.digest(fingerprint.fingerprint + "\n" + recordingID + "\n" + String(fingerprint.durationInSeconds))
        guard entries?[key] == nil else { return nil }
        entries?[key] = "attempting"
        do { try persist() } catch { entries?.removeValue(forKey: key); throw error }
        return key
    }
    public func finish(_ key: String, accepted: Bool) throws {
        try load(); entries?[key] = accepted ? "accepted" : "uncertain"; try persist()
    }
    private func load() throws {
        guard entries == nil else { return }
        if FileManager.default.fileExists(atPath: url.path) { entries = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url)) }
        else { entries = [:] }
    }
    private func persist() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entries ?? [:]).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
