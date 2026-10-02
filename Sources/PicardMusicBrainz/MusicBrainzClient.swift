import CryptoKit
import Foundation

public struct MusicBrainzHTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let data: Data

    public init(statusCode: Int, headers: [String: String] = [:], data: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.data = data
    }
}

public protocol MusicBrainzTransport: Sendable {
    func data(for request: URLRequest) async throws -> MusicBrainzHTTPResponse
}

public struct URLSessionMusicBrainzTransport: MusicBrainzTransport, Sendable {
    public init() {}

    public func data(for request: URLRequest) async throws -> MusicBrainzHTTPResponse {
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MusicBrainzError.invalidResponse("The server returned a non-HTTP response.")
        }

        var headers: [String: String] = [:]
        for (key, value) in httpResponse.allHeaderFields {
            headers[String(describing: key).lowercased()] = String(describing: value)
        }

        return MusicBrainzHTTPResponse(
            statusCode: httpResponse.statusCode,
            headers: headers,
            data: data
        )
    }
}

public enum MusicBrainzError: Error, LocalizedError, Sendable, Equatable {
    case invalidURL(String)
    case transport(String)
    case invalidResponse(String)
    case httpStatus(Int, String)
    case decoding(String)
    case rateLimited
    case emptyIdentifier

    public var errorDescription: String? {
        switch self {
        case let .invalidURL(value):
            return "MusicBrainz URL is invalid: \(value)"
        case let .transport(message):
            return "MusicBrainz network request failed: \(message)"
        case let .invalidResponse(message):
            return "MusicBrainz returned an invalid response: \(message)"
        case let .httpStatus(status, body):
            return "MusicBrainz returned HTTP \(status): \(body)"
        case let .decoding(message):
            return "MusicBrainz response decoding failed: \(message)"
        case .rateLimited:
            return "MusicBrainz rate limit was reached."
        case .emptyIdentifier:
            return "A MusicBrainz identifier is required."
        }
    }
}

public enum MusicBrainzInclude: String, CaseIterable, Sendable {
    case artists
    case artistCredits = "artist-credits"
    case labels
    case media
    case recordings
    case releaseGroups = "release-groups"
    case isrcs
    case tags
    case genres
    case relationships
}

public actor MusicBrainzResponseCache {
    private struct Entry: Codable {
        let expiresAt: Date
        let data: Data
    }

    private let directory: URL
    private let lifetime: TimeInterval

    public init(directory: URL, lifetime: TimeInterval = 86_400) {
        self.directory = directory
        self.lifetime = lifetime
    }

    public func data(for key: String) throws -> Data? {
        let fileURL = directory.appendingPathComponent(key).appendingPathExtension("json")
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        do {
            let entry = try JSONDecoder().decode(Entry.self, from: Data(contentsOf: fileURL))
            guard entry.expiresAt > Date() else {
                try? FileManager.default.removeItem(at: fileURL)
                return nil
            }
            return entry.data
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
    }

    public func store(_ data: Data, for key: String) throws {
        let fileURL = directory.appendingPathComponent(key).appendingPathExtension("json")
        let entry = Entry(expiresAt: Date().addingTimeInterval(lifetime), data: data)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoded = try JSONEncoder().encode(entry)
            try encoded.write(to: fileURL, options: [.atomic])
        } catch {
            throw MusicBrainzError.transport("Could not write cache: \(error.localizedDescription)")
        }
    }

    public func remove(_ key: String) {
        let fileURL = directory.appendingPathComponent(key).appendingPathExtension("json")
        try? FileManager.default.removeItem(at: fileURL)
    }
}

public actor MusicBrainzClient {
    public static let defaultBaseURL = URL(string: "https://musicbrainz.org/ws/2")!

    private let baseURL: URL
    private let userAgent: String
    private let authorizationHeader: String?
    private let transport: any MusicBrainzTransport
    private let cache: MusicBrainzResponseCache?
    private let minimumRequestInterval: Duration
    private var lastRequest: ContinuousClock.Instant?

    public init(
        baseURL: URL = MusicBrainzClient.defaultBaseURL,
        userAgent: String,
        authorizationHeader: String? = nil,
        transport: any MusicBrainzTransport = URLSessionMusicBrainzTransport(),
        cache: MusicBrainzResponseCache? = nil,
        minimumRequestInterval: Duration = .seconds(1)
    ) {
        self.baseURL = baseURL
        self.userAgent = userAgent
        self.authorizationHeader = authorizationHeader
        self.transport = transport
        self.cache = cache
        self.minimumRequestInterval = minimumRequestInterval
    }

    public func searchReleases(query: String, limit: Int = 25) async throws -> [MusicBrainzReleaseSummary] {
        let response: MusicBrainzSearchResponse = try await get(
            path: "release",
            queryItems: [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "limit", value: String(max(1, min(limit, 100))))
            ]
        )
        return response.releases.map { $0.summary() }
    }

    public func searchReleases(for album: LocalAlbumCandidate, limit: Int = 25) async throws -> [MusicBrainzReleaseSummary] {
        let clauses = [
            album.albumTitle.map { "release:\"\($0)\"" },
            album.albumArtist.map { "artist:\"\($0)\"" },
            album.barcode.map { "barcode:\"\($0)\"" }
        ].compactMap { $0 }

        guard !clauses.isEmpty else {
            throw MusicBrainzError.invalidResponse("At least an album title, artist, or barcode is required.")
        }

        return try await searchReleases(query: clauses.joined(separator: " AND "), limit: limit)
    }

    public func lookupRelease(
        id: String,
        includes: Set<MusicBrainzInclude> = Set(MusicBrainzInclude.allCases)
    ) async throws -> MusicBrainzRelease {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MusicBrainzError.emptyIdentifier
        }

        let response: APIRelease = try await get(
            path: "release/\(id)",
            queryItems: [
                URLQueryItem(name: "inc", value: includes.map(\.rawValue).sorted().joined(separator: ","))
            ]
        )
        return response.release()
    }

    private func get<Response: Decodable>(
        path: String,
        queryItems: [URLQueryItem]
    ) async throws -> Response {
        let url = try makeURL(path: path, queryItems: queryItems)
        let key = Self.cacheKey(for: url)

        if let cache, let cachedData = try await cache.data(for: key) {
            do {
                return try decode(Response.self, from: cachedData)
            } catch {
                await cache.remove(key)
            }
        }

        var lastError: MusicBrainzError?

        for attempt in 0..<3 {
            do {
                try Task.checkCancellation()
                try await waitForRateLimit()
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.timeoutInterval = 30
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                if let authorizationHeader {
                    request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
                }

                let response = try await transport.data(for: request)

                if response.statusCode == 429 || response.statusCode == 503 || response.statusCode == 502 || response.statusCode == 504 {
                    lastError = response.statusCode == 429 ? .rateLimited : .httpStatus(response.statusCode, "temporary server failure")
                    if attempt < 2 {
                        try await Task.sleep(for: retryDelay(response: response, attempt: attempt))
                        continue
                    }
                    throw lastError ?? .rateLimited
                }

                guard (200..<300).contains(response.statusCode) else {
                    throw MusicBrainzError.httpStatus(
                        response.statusCode,
                        Self.responseBodySummary(response.data)
                    )
                }

                if let cache {
                    try? await cache.store(response.data, for: key)
                }
                return try decode(Response.self, from: response.data)
            } catch let error as MusicBrainzError {
                lastError = error
                if attempt == 2 || !Self.isRetryable(error) {
                    throw error
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled {
                    throw CancellationError()
                }
                let wrapped = MusicBrainzError.transport(error.localizedDescription)
                lastError = wrapped
                if attempt == 2 {
                    throw wrapped
                }
            }
        }

        throw lastError ?? .transport("The request failed without a response.")
    }

    private func makeURL(path: String, queryItems: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw MusicBrainzError.invalidURL(path)
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw MusicBrainzError.invalidURL(path)
        }
        return url
    }

    private func waitForRateLimit() async throws {
        let now = ContinuousClock.now
        if let lastRequest {
            let elapsed = lastRequest.duration(to: now)
            if elapsed < minimumRequestInterval {
                try await Task.sleep(for: minimumRequestInterval - elapsed)
            }
        }
        lastRequest = ContinuousClock.now
    }

    private func retryDelay(response: MusicBrainzHTTPResponse, attempt: Int) -> Duration {
        if let retryAfter = response.headers["retry-after"], let seconds = Double(retryAfter) {
            return .milliseconds(Int64(min(max(seconds * 1_000, 250), 10_000)))
        }
        return .milliseconds(Int64(500 * (attempt + 1)))
    }

    private func decode<Response: Decodable>(_ type: Response.Type, from data: Data) throws -> Response {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw MusicBrainzError.decoding(String(describing: error))
        }
    }

    private static func cacheKey(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func responseBodySummary(_ data: Data) -> String {
        let body = String(decoding: data.prefix(512), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? "empty response" : body
    }

    private static func isRetryable(_ error: MusicBrainzError) -> Bool {
        switch error {
        case .transport:
            return true
        case let .httpStatus(status, _):
            return [429, 502, 503, 504].contains(status)
        default:
            return false
        }
    }
}
