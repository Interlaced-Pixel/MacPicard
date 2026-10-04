import CryptoKit
import Foundation

public struct AppVersion: Codable, Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: String?

    public init(_ value: String) throws {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") { trimmed.removeFirst() }
        guard !trimmed.isEmpty else { throw AppUpdateError.invalidVersion(value) }
        let pieces = trimmed.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = pieces[0].split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count == 3,
              numbers.allSatisfy({ $0.allSatisfy(\.isNumber) }),
              let major = Int(numbers[0]), let minor = Int(numbers[1]), let patch = Int(numbers[2]) else {
            throw AppUpdateError.invalidVersion(value)
        }
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = pieces.count == 2 ? String(pieces[1]) : nil
    }

    public var description: String {
        var value = "\(major).\(minor).\(patch)"
        if let prerelease, !prerelease.isEmpty { value += "-\(prerelease)" }
        return value
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let numbers = [lhs.major, lhs.minor, lhs.patch]
        let otherNumbers = [rhs.major, rhs.minor, rhs.patch]
        if numbers != otherNumbers { return numbers.lexicographicallyPrecedes(otherNumbers) }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil): return false
        case (nil, .some): return false
        case (.some, nil): return true
        case let (.some(left), .some(right)): return left.compare(right, options: .numeric) == .orderedAscending
        }
    }
}

public struct AppUpdateRelease: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let version: AppVersion
    public let name: String
    public let notes: String
    public let releaseURL: URL
    public let publishedAt: Date?
    public let archiveURL: URL?
    public let checksumURL: URL?
    public let isPrerelease: Bool

    public init(
        id: String,
        version: AppVersion,
        name: String,
        notes: String,
        releaseURL: URL,
        publishedAt: Date?,
        archiveURL: URL?,
        checksumURL: URL?,
        isPrerelease: Bool
    ) {
        self.id = id
        self.version = version
        self.name = name
        self.notes = notes
        self.releaseURL = releaseURL
        self.publishedAt = publishedAt
        self.archiveURL = archiveURL
        self.checksumURL = checksumURL
        self.isPrerelease = isPrerelease
    }
}

public struct AppUpdateProgress: Equatable, Sendable {
    public enum Phase: String, Sendable { case downloading, staging, installing }
    public let phase: Phase
    public let completedBytes: Int64
    public let totalBytes: Int64?

    public init(phase: Phase, completedBytes: Int64, totalBytes: Int64?) {
        self.phase = phase
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
    }

    public var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
    }
}

public enum AppUpdateError: Error, LocalizedError, Equatable, Sendable {
    case invalidVersion(String)
    case invalidResponse
    case invalidRelease(String)
    case network(String)
    case checksumMissing
    case checksumMismatch(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case let .invalidVersion(value): "The release version \(value) is not valid semantic versioning."
        case .invalidResponse: "The update service returned an invalid response."
        case let .invalidRelease(message): "The release cannot be installed: \(message)"
        case let .network(message): "The update check failed: \(message)"
        case .checksumMissing: "This release has no SHA-256 checksum and cannot be verified safely."
        case let .checksumMismatch(expected, actual): "The downloaded update failed checksum verification (expected \(expected), got \(actual))."
        }
    }
}

public actor AppUpdateService {
    public static let defaultEndpoint = URL(string: "https://api.github.com/repos/Interlaced-Pixel/MacPicard/releases/latest")!

    private let session: URLSession
    private let endpoint: URL

    public init(endpoint: URL = AppUpdateService.defaultEndpoint, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    public func check(currentVersion: AppVersion, includePrereleases: Bool = false) async throws -> AppUpdateRelease? {
        let request = makeRequest(url: endpoint, accept: "application/vnd.github+json")
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw AppUpdateError.network(error.localizedDescription) }
        try validate(response)

        let payload: GitHubRelease
        do { payload = try JSONDecoder.github.decode(GitHubRelease.self, from: data) }
        catch { throw AppUpdateError.invalidResponse }
        guard !payload.draft, includePrereleases || !payload.prerelease else { return nil }
        let version = try AppVersion(payload.tagName)
        guard version > currentVersion else { return nil }
        guard let releaseURL = URL(string: payload.htmlURL), isAllowedURL(releaseURL) else {
            throw AppUpdateError.invalidRelease("the release page URL is not trusted")
        }

        let archive = payload.assets.first { asset in
            asset.name.lowercased().hasSuffix(".zip") && asset.name.lowercased().contains("macpicard")
        } ?? payload.assets.first { $0.name.lowercased().hasSuffix(".zip") }
        let checksum = payload.assets.first { asset in
            let name = asset.name.lowercased()
            return name.hasSuffix(".sha256") || name.hasSuffix(".sha256sum")
        }
        return AppUpdateRelease(
            id: String(payload.id),
            version: version,
            name: payload.name?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "MacPicard \(version)",
            notes: payload.body ?? "",
            releaseURL: releaseURL,
            publishedAt: payload.publishedAt,
            archiveURL: archive.flatMap { URL(string: $0.browserDownloadURL) }.flatMap(Self.trustedDownloadURL),
            checksumURL: checksum.flatMap { URL(string: $0.browserDownloadURL) }.flatMap(Self.trustedDownloadURL),
            isPrerelease: payload.prerelease
        )
    }

    public func downloadAndVerify(
        _ release: AppUpdateRelease,
        progress: @escaping @Sendable (AppUpdateProgress) -> Void = { _ in }
    ) async throws -> URL {
        guard let archiveURL = release.archiveURL, let checksumURL = release.checksumURL else {
            throw AppUpdateError.checksumMissing
        }
        let checksumData: Data
        let checksumResponse: URLResponse
        do {
            (checksumData, checksumResponse) = try await session.data(for: makeRequest(url: checksumURL, accept: "text/plain"))
        } catch { throw AppUpdateError.network(error.localizedDescription) }
        try validate(checksumResponse)
        let expected = try Self.parseChecksum(String(decoding: checksumData, as: UTF8.self), archiveURL: archiveURL)

        let archiveRequest = makeRequest(url: archiveURL, accept: "application/zip")
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do { (bytes, response) = try await session.bytes(for: archiveRequest) }
        catch { throw AppUpdateError.network(error.localizedDescription) }
        try validate(response)
        let expectedLength = response.expectedContentLength > 0 ? response.expectedContentLength : nil
        var archiveData = Data()
        if let expectedLength { archiveData.reserveCapacity(Int(min(expectedLength, Int64(Int.max)))) }
        var digest = SHA256()
        var digestBuffer = Data()
        digestBuffer.reserveCapacity(64 * 1024)
        var completed: Int64 = 0
        for try await byte in bytes {
            try Task.checkCancellation()
            digestBuffer.append(byte)
            completed += 1
            if digestBuffer.count == 64 * 1024 {
                archiveData.append(digestBuffer)
                digest.update(data: digestBuffer)
                digestBuffer.removeAll(keepingCapacity: true)
            }
            if completed.isMultiple(of: 256 * 1024) {
                progress(AppUpdateProgress(phase: .downloading, completedBytes: completed, totalBytes: expectedLength))
            }
        }
        if !digestBuffer.isEmpty {
            archiveData.append(digestBuffer)
            digest.update(data: digestBuffer)
        }
        progress(AppUpdateProgress(phase: .downloading, completedBytes: completed, totalBytes: expectedLength ?? completed))
        let actual = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard expected == actual else { throw AppUpdateError.checksumMismatch(expected: expected, actual: actual) }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacPicard-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let archivePath = directory.appendingPathComponent("MacPicard.zip")
        try archiveData.write(to: archivePath, options: [.atomic])
        return archivePath
    }

    private func makeRequest(url: URL, accept: String) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("MacPicard updater", forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        return request
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AppUpdateError.network("the server returned an unexpected status")
        }
    }

    private func isAllowedURL(_ url: URL) -> Bool {
        url.scheme == "https" && ["github.com", "api.github.com"].contains(url.host?.lowercased())
    }

    private static func trustedDownloadURL(_ url: URL) -> URL? {
        guard url.scheme == "https", let host = url.host?.lowercased(),
              host == "github.com" || host == "objects.githubusercontent.com" || host.hasSuffix(".githubusercontent.com") else { return nil }
        return url
    }

    private static func parseChecksum(_ text: String, archiveURL: URL) throws -> String {
        let expectedName = archiveURL.lastPathComponent
        for line in text.split(whereSeparator: { $0.isNewline }) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let value = fields.first, value.count == 64, value.allSatisfy({ $0.isHexDigit }) else { continue }
            if fields.count == 1 || fields.dropFirst().joined().contains(expectedName) {
                return value.lowercased()
            }
        }
        throw AppUpdateError.checksumMissing
    }

    private struct GitHubRelease: Decodable {
        let id: Int
        let tagName: String
        let name: String?
        let body: String?
        let htmlURL: String
        let publishedAt: Date?
        let prerelease: Bool
        let draft: Bool
        let assets: [Asset]

        enum CodingKeys: String, CodingKey { case id, name, body, prerelease, draft, assets, tagName = "tag_name", htmlURL = "html_url", publishedAt = "published_at" }
        struct Asset: Decodable { let name: String; let browserDownloadURL: String; enum CodingKeys: String, CodingKey { case name, browserDownloadURL = "browser_download_url" } }
    }
}

private extension JSONDecoder {
    static var github: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
