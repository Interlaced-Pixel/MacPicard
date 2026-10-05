import CryptoKit
import Foundation

/// Immutable content-addressed bytes shared by current/original artwork and
/// every track in an archive. References are committed only after their blob.
/// No automatic deletion: recovery and operation-history references stay valid.
public final class ArtworkBlobStore: @unchecked Sendable {
    public static let codingKey = CodingUserInfoKey(rawValue: "MacPicard.ArtworkBlobStore")!
    public let directory: URL
    private let lock = NSLock()
    private let memoryLimit: Int
    private var cache: [String: Data] = [:]
    private var order: [String] = []
    private var memoryBytes = 0
    private var written = Set<String>()

    public init(directory: URL, memoryLimit: Int = 32 * 1024 * 1024) {
        self.directory = directory
        self.memoryLimit = max(0, memoryLimit)
    }

    public func store(_ data: Data, hash: String) throws {
        try validate(hash)
        guard data.count <= 64 * 1024 * 1024 else { throw PicardError.sessionEncoding("Artwork blob exceeds 64 MiB.") }
        lock.lock(); defer { lock.unlock() }
        if written.contains(hash) { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(hash)
        if FileManager.default.fileExists(atPath: url.path) {
            let existing = try Data(contentsOf: url, options: .mappedIfSafe)
            guard Self.hash(existing) == hash else { throw PicardError.sessionEncoding("Artwork blob checksum mismatch: \(hash)") }
        } else {
            guard Self.hash(data) == hash else { throw PicardError.sessionEncoding("Artwork hash does not match its bytes.") }
            try DurableArchive.replace(data, at: url)
        }
        written.insert(hash)
        remember(data, hash: hash)
    }

    public func load(_ hash: String) throws -> Data {
        try validate(hash)
        lock.lock(); defer { lock.unlock() }
        if let bytes = cache[hash] { return bytes }
        let url = directory.appendingPathComponent(hash)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 64 * 1024 * 1024 else { throw PicardError.sessionEncoding("Artwork blob exceeds 64 MiB.") }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard Self.hash(data) == hash else { throw PicardError.sessionEncoding("Artwork blob checksum mismatch: \(hash)") }
        remember(data, hash: hash)
        return data
    }

    private func remember(_ data: Data, hash: String) {
        guard data.count <= memoryLimit else { return }
        if let previous = cache.removeValue(forKey: hash) { memoryBytes -= previous.count }
        order.removeAll { $0 == hash }
        cache[hash] = data; order.append(hash); memoryBytes += data.count
        while memoryBytes > memoryLimit || order.count > 256 {
            if let removed = cache.removeValue(forKey: order.removeFirst()) { memoryBytes -= removed.count }
        }
    }

    private func validate(_ hash: String) throws {
        guard hash.utf8.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw PicardError.sessionEncoding("Invalid artwork blob reference.")
        }
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
