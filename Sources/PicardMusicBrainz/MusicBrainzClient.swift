import CryptoKit
import Foundation
import PicardFoundation

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
        guard let url = request.url, APIRequestPolicy.isSecure(url) else {
            throw MusicBrainzError.invalidURL("A secure HTTPS endpoint is required.")
        }
        let (data, response) = try await URLSession.shared.data(for: request, delegate: SecureAPIRequestDelegate.shared)

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
    case invalidIdentifier(String)

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
        case let .invalidIdentifier(value):
            return "A valid MusicBrainz UUID is required: \(value)"
        }
    }
}

public enum MusicBrainzInclude: String, CaseIterable, Sendable {
    case artistCredits = "artist-credits"
    case labels
    case media
    case recordings
    case releaseGroups = "release-groups"
    case isrcs
    case tags
    case genres
}

public actor MusicBrainzResponseCache {
    public struct CachedResponse: Sendable {
        public let data: Data
        public let expiresAt: Date
    }
    private struct Entry: Codable {
        let expiresAt: Date
        let data: Data
    }

    private let directory: URL
    private let lifetime: TimeInterval
    private var memory: [String: Entry] = [:]
    private var order: [String] = []
    private var memoryBytes = 0

    public init(directory: URL, lifetime: TimeInterval = 86_400) {
        self.directory = directory
        self.lifetime = lifetime
    }

    public func data(for key: String) throws -> Data? {
        try response(for: key)?.data
    }
    public func response(for key: String) throws -> CachedResponse? {
        if let entry = memory[key] {
            if entry.expiresAt > Date() { return CachedResponse(data: entry.data, expiresAt: entry.expiresAt) }
            discardMemory(key)
        }
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
            remember(entry, key: key)
            return CachedResponse(data: entry.data, expiresAt: entry.expiresAt)
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
            remember(entry, key: key)
        } catch {
            throw MusicBrainzError.transport("Could not write cache: \(error.localizedDescription)")
        }
    }

    public func remove(_ key: String) {
        discardMemory(key)
        let fileURL = directory.appendingPathComponent(key).appendingPathExtension("json")
        try? FileManager.default.removeItem(at: fileURL)
    }
    public func freshExpiration() -> Date { Date().addingTimeInterval(lifetime) }
    private func discardMemory(_ key: String) {
        if let entry = memory.removeValue(forKey: key) { memoryBytes -= entry.data.count }
        order.removeAll { $0 == key }
    }
    private func remember(_ entry: Entry, key: String) {
        discardMemory(key)
        guard entry.data.count <= 16 * 1024 * 1024 else { return }
        memory[key] = entry; memoryBytes += entry.data.count; order.append(key)
        while memoryBytes > 16 * 1024 * 1024 || order.count > 64 { discardMemory(order[0]) }
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
    private let rateLimiter: APIRequestRateLimiter
    public static let matchingIncludes: Set<MusicBrainzInclude> = [.artistCredits, .labels, .media, .recordings, .releaseGroups, .isrcs]
    private struct DecodedRelease {
        let release: MusicBrainzRelease
        let expiresAt: Date
        let cost: Int
    }
    private struct ReleaseFlight {
        let generation: UUID
        let task: Task<MusicBrainzRelease, Error>
        var waiters: Set<UUID>
    }
    private var decodedReleases: [String: DecodedRelease] = [:]
    private var decodedOrder: [String] = []
    private var decodedBytes = 0
    private var releaseFlights: [String: ReleaseFlight] = [:]

    public init(
        baseURL: URL = MusicBrainzClient.defaultBaseURL,
        userAgent: String,
        authorizationHeader: String? = nil,
        transport: any MusicBrainzTransport = URLSessionMusicBrainzTransport(),
        cache: MusicBrainzResponseCache? = nil,
        minimumRequestInterval: Duration = .seconds(1),
        rateLimiter: APIRequestRateLimiter = .shared
    ) {
        self.baseURL = baseURL
        self.userAgent = userAgent
        self.authorizationHeader = authorizationHeader
        self.transport = transport
        self.cache = cache
        self.minimumRequestInterval = minimumRequestInterval
        self.rateLimiter = rateLimiter
    }

    public func searchReleases(query: String, limit: Int = 25) async throws -> [MusicBrainzReleaseSummary] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MusicBrainzError.invalidResponse("A search query is required.")
        }
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
        if let id = album.releaseID, UUID(uuidString: id) != nil {
            do { return [try await lookupRelease(id: id).summary] }
            catch is CancellationError { throw CancellationError() }
            catch { /* An unavailable saved ID falls back to ordinary search. */ }
        }
        let clauses = [
            album.albumTitle.flatMap { Self.searchClause("release", value: $0) },
            album.albumArtist.flatMap { Self.searchClause("artist", value: $0) },
            album.barcode.flatMap { Self.searchClause("barcode", value: $0) }
        ].compactMap { $0 }

        guard !clauses.isEmpty else {
            throw MusicBrainzError.invalidResponse("At least an album title, artist, or barcode is required.")
        }

        return try await searchReleases(query: clauses.joined(separator: " AND "), limit: limit)
    }

    public func lookupRelease(
        id: String,
        includes: Set<MusicBrainzInclude> = MusicBrainzClient.matchingIncludes
    ) async throws -> MusicBrainzRelease {
        let identifier = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else {
            throw MusicBrainzError.emptyIdentifier
        }
        guard let uuid = UUID(uuidString: identifier) else { throw MusicBrainzError.invalidIdentifier(identifier) }
        var includes = includes
        if includes.contains(.isrcs) { includes.insert(.recordings) }
        try Task.checkCancellation()
        let path = "release/\(uuid.uuidString.lowercased())"
        let queryItems = includes.isEmpty ? [] : [
                URLQueryItem(name: "inc", value: includes.map(\.rawValue).sorted().joined(separator: " "))
            ]
        let key = Self.cacheKey(for: try makeURL(path: path, queryItems: queryItems), authorization: authorizationHeader)
        if let entry = decodedReleases[key], entry.expiresAt > Date() { return entry.release }
        let waiter = UUID()
        let flight: ReleaseFlight
        if var existing = releaseFlights[key] {
            existing.waiters.insert(waiter); releaseFlights[key] = existing; flight = existing
        } else {
            let generation = UUID()
            let task = Task { try await self.loadRelease(path: path, queryItems: queryItems, key: key) }
            flight = ReleaseFlight(generation: generation, task: task, waiters: [waiter])
            releaseFlights[key] = flight
        }
        defer { if releaseFlights[key]?.generation == flight.generation { releaseFlights.removeValue(forKey: key) } }
        let release = try await withTaskCancellationHandler {
            try await flight.task.value
        } onCancel: {
            Task { await self.cancelReleaseWaiter(key: key, generation: flight.generation, waiter: waiter) }
        }
        try Task.checkCancellation()
        return release
    }

    private func cancelReleaseWaiter(key: String, generation: UUID, waiter: UUID) {
        guard var flight = releaseFlights[key], flight.generation == generation else { return }
        flight.waiters.remove(waiter)
        if flight.waiters.isEmpty { flight.task.cancel(); releaseFlights.removeValue(forKey: key) }
        else { releaseFlights[key] = flight }
    }
    private func loadRelease(path: String, queryItems: [URLQueryItem], key: String) async throws -> MusicBrainzRelease {
        let (response, expiration): (APIRelease, Date?) = try await getResponse(path: path, queryItems: queryItems)
        try Task.checkCancellation()
        let release = response.release()
        guard release.id.lowercased() == path.split(separator: "/").last?.lowercased() else {
            throw MusicBrainzError.invalidResponse("The response does not identify the requested release.")
        }
        let expiresAt = expiration ?? Date().addingTimeInterval(60)
        let cost = 1024 + release.tracks.reduce(0) { $0 + 1024 + $1.title.utf8.count + $1.artistCredit.utf8.count }
        if let old = decodedReleases.removeValue(forKey: key) { decodedBytes -= old.cost }
        decodedOrder.removeAll { $0 == key }
        if cost <= 8 * 1024 * 1024 {
            decodedReleases[key] = DecodedRelease(release: release, expiresAt: expiresAt, cost: cost)
            decodedOrder.append(key); decodedBytes += cost
            while decodedBytes > 8 * 1024 * 1024 || decodedOrder.count > 64 {
                if let removed = decodedReleases.removeValue(forKey: decodedOrder.removeFirst()) { decodedBytes -= removed.cost }
            }
        }
        return release
    }

    public func releasesForRecording(id: String, limit: Int = 25) async throws -> [MusicBrainzReleaseSummary] {
        guard let uuid = UUID(uuidString: id) else { throw MusicBrainzError.invalidIdentifier("A recording UUID is required.") }
        let response: MusicBrainzSearchResponse = try await get(path: "release", queryItems: [
            URLQueryItem(name: "recording", value: uuid.uuidString.lowercased()),
            URLQueryItem(name: "limit", value: String(max(1, min(limit, 100)))),
            URLQueryItem(name: "inc", value: "artist-credits labels release-groups media")
        ])
        return response.releases.map { $0.summary() }
    }

    private func get<Response: Decodable>(
        path: String,
        queryItems: [URLQueryItem]
    ) async throws -> Response {
        let (response, _): (Response, Date?) = try await getResponse(path: path, queryItems: queryItems)
        return response
    }
    private func getResponse<Response: Decodable>(path: String, queryItems: [URLQueryItem]) async throws -> (Response, Date?) {
        try Task.checkCancellation()
        let url = try makeURL(path: path, queryItems: queryItems)
        let key = Self.cacheKey(for: url, authorization: authorizationHeader)

        if let cache, let cached = try await cache.response(for: key) {
            try Task.checkCancellation()
            do {
                return (try decode(Response.self, from: cached.data), cached.expiresAt)
            } catch {
                await cache.remove(key)
            }
        }

        var lastError: MusicBrainzError?

        for attempt in 0..<3 {
            do {
                try Task.checkCancellation()
                try await rateLimiter.wait(for: url.host!.lowercased(), interval: minimumRequestInterval)
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.timeoutInterval = 30
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                if let authorizationHeader {
                    request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
                }

                let response = try await transport.data(for: request)

                if APIRequestPolicy.retryableStatusCodes.contains(response.statusCode) {
                    lastError = response.statusCode == 429 ? .rateLimited : .httpStatus(response.statusCode, "temporary server failure")
                    await rateLimiter.deferRequests(for: url.host!.lowercased(), delay: APIRequestPolicy.retryDelay(headers: response.headers, attempt: attempt))
                    if attempt < 2 {
                        continue
                    }
                    throw lastError ?? .rateLimited
                }

                guard (200..<300).contains(response.statusCode) else {
                    throw MusicBrainzError.httpStatus(
                        response.statusCode,
                        APIRequestPolicy.errorSummary(response.data)
                    )
                }

                let decoded = try decode(Response.self, from: response.data)
                let expiration = await cache?.freshExpiration()
                if let cache {
                    try? await cache.store(response.data, for: key)
                }
                return (decoded, expiration)
            } catch let error as MusicBrainzError {
                lastError = error
                if attempt == 2 || !Self.isRetryable(error) {
                    throw error
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled {
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
        components.queryItems = queryItems + [URLQueryItem(name: "fmt", value: "json")]
        guard let url = components.url, APIRequestPolicy.isSecure(url) else {
            throw MusicBrainzError.invalidURL(path)
        }
        return url
    }

    private static func searchClause(_ field: String, value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let reserved = Set("+-!(){}[]^\"~*?:\\/&|")
        let escaped = trimmed.map { reserved.contains($0) ? "\\\($0)" : String($0) }.joined()
        return "\(field):\"\(escaped)\""
    }

    private func decode<Response: Decodable>(_ type: Response.Type, from data: Data) throws -> Response {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw MusicBrainzError.decoding(String(describing: error))
        }
    }

    private static func cacheKey(for url: URL, authorization: String?) -> String {
        SHA256.hash(data: Data((url.absoluteString + (authorization.map { "\u{0}\($0)" } ?? "")).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func isRetryable(_ error: MusicBrainzError) -> Bool {
        switch error {
        case .transport:
            return true
        case let .httpStatus(status, _):
            return APIRequestPolicy.retryableStatusCodes.contains(status)
        default:
            return false
        }
    }
}
