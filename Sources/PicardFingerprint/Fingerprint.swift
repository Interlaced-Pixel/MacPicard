import Foundation
import PicardMusicBrainz

public struct AudioFingerprint: Codable, Sendable, Equatable {
    public let fingerprint: String
    public let durationInSeconds: Double
    public let algorithm: String?

    public init(fingerprint: String, durationInSeconds: Double, algorithm: String? = nil) {
        self.fingerprint = fingerprint
        self.durationInSeconds = durationInSeconds
        self.algorithm = algorithm
    }
}

public enum FingerprintError: Error, LocalizedError, Sendable, Equatable {
    case unavailable(String)
    case invalidInput(String)
    case processFailed(Int32, String)
    case invalidOutput(String)
    case network(String)
    case invalidResponse(String)
    case authenticationRequired
    case consentRequired

    public var errorDescription: String? {
        switch self {
        case let .unavailable(message): return "Chromaprint is unavailable: \(message)"
        case let .invalidInput(message): return "Invalid fingerprint input: \(message)"
        case let .processFailed(status, message): return "Chromaprint failed with status \(status): \(message)"
        case let .invalidOutput(message): return "Chromaprint returned invalid output: \(message)"
        case let .network(message): return "AcoustID request failed: \(message)"
        case let .invalidResponse(message): return "AcoustID returned an invalid response: \(message)"
        case .authenticationRequired: return "AcoustID submission requires a user authentication token."
        case .consentRequired: return "AcoustID submission requires explicit user consent."
        }
    }
}

private struct FpcalcResponse: Decodable {
    let fingerprint: String?
    let duration: Double?
    let algorithm: String?
}

public enum ChromaprintDecoder {
    public static func decode(_ data: Data) throws -> AudioFingerprint {
        do {
            let response = try JSONDecoder().decode(FpcalcResponse.self, from: data)
            guard let fingerprint = response.fingerprint, !fingerprint.isEmpty,
                  let duration = response.duration, duration > 0 else {
                throw FingerprintError.invalidOutput("The JSON response did not contain a fingerprint and positive duration.")
            }
            return AudioFingerprint(
                fingerprint: fingerprint,
                durationInSeconds: duration,
                algorithm: response.algorithm
            )
        } catch let error as FingerprintError {
            throw error
        } catch {
            throw FingerprintError.invalidOutput(error.localizedDescription)
        }
    }
}

public actor ChromaprintFingerprintProvider {
    public static let defaultExecutableCandidates: [URL] = [
        URL(fileURLWithPath: "/opt/homebrew/bin/fpcalc"),
        URL(fileURLWithPath: "/usr/local/bin/fpcalc"),
        URL(fileURLWithPath: "/usr/bin/fpcalc")
    ]

    private let executableURL: URL?

    public init(executableURL: URL? = nil) {
        self.executableURL = executableURL ?? Self.defaultExecutableCandidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        })
    }

    public func fingerprint(url: URL) throws -> AudioFingerprint {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw FingerprintError.invalidInput("The audio file is not readable: \(url.path)")
        }
        guard let executableURL else {
            throw FingerprintError.unavailable("Install Chromaprint's fpcalc command-line tool.")
        }

        let output = Pipe()
        let errors = Pipe()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["-json", url.path]
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw FingerprintError.unavailable(error.localizedDescription)
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorMessage = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw FingerprintError.processFailed(process.terminationStatus, errorMessage)
        }
        return try ChromaprintDecoder.decode(data)
    }
}

public struct AcoustIDRecording: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String?
    public let artist: String?
    public let releaseIDs: [String]

    public init(id: String, title: String?, artist: String?, releaseIDs: [String]) {
        self.id = id
        self.title = title
        self.artist = artist
        self.releaseIDs = releaseIDs
    }
}

public struct AcoustIDMatch: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let score: Double
    public let recordings: [AcoustIDRecording]

    public init(id: String, score: Double, recordings: [AcoustIDRecording]) {
        self.id = id
        self.score = score
        self.recordings = recordings
    }
}

public struct AcoustIDSubmission: Codable, Sendable, Equatable {
    public let fingerprint: String
    public let durationInSeconds: Double
    public let recordingID: String

    public init(fingerprint: String, durationInSeconds: Double, recordingID: String) {
        self.fingerprint = fingerprint
        self.durationInSeconds = durationInSeconds
        self.recordingID = recordingID
    }
}

public struct AcoustIDHTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let data: Data

    public init(statusCode: Int, headers: [String: String] = [:], data: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.data = data
    }
}

public protocol AcoustIDTransport: Sendable {
    func data(for request: URLRequest) async throws -> AcoustIDHTTPResponse
}

public struct URLSessionAcoustIDTransport: AcoustIDTransport, Sendable {
    public init() {}

    public func data(for request: URLRequest) async throws -> AcoustIDHTTPResponse {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw FingerprintError.invalidResponse("The server returned a non-HTTP response.")
            }
            var headers: [String: String] = [:]
            for (key, value) in httpResponse.allHeaderFields {
                headers[String(describing: key).lowercased()] = String(describing: value)
            }
            return AcoustIDHTTPResponse(statusCode: httpResponse.statusCode, headers: headers, data: data)
        } catch let error as FingerprintError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw FingerprintError.network(error.localizedDescription)
        }
    }
}

private struct AcoustIDResponse: Decodable {
    let status: String
    let error: AcoustIDAPIError?
    let results: [AcoustIDResult]

    enum CodingKeys: String, CodingKey {
        case status
        case error
        case results
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(String.self, forKey: .status)
        error = try container.decodeIfPresent(AcoustIDAPIError.self, forKey: .error)
        results = try container.decodeIfPresent([AcoustIDResult].self, forKey: .results) ?? []
    }
}

private struct AcoustIDAPIError: Decodable {
    let code: Int?
    let message: String?
}

private struct AcoustIDResult: Decodable {
    let id: String
    let score: Double
    let recordings: [AcoustIDAPIRecording]?
}

private struct AcoustIDAPIRecording: Decodable {
    let id: String
    let title: String?
    let artists: [AcoustIDAPIArtist]?
    let releases: [AcoustIDAPIRelease]?
}

private struct AcoustIDAPIArtist: Decodable {
    let name: String?
}

private struct AcoustIDAPIRelease: Decodable {
    let id: String?
}

public actor AcoustIDClient {
    public static let defaultBaseURL = URL(string: "https://api.acoustid.org/v2")!

    private let apiKey: String
    private let userAgent: String
    private let baseURL: URL
    private let transport: any AcoustIDTransport
    private let minimumRequestInterval: Duration
    private var lastRequest: ContinuousClock.Instant?

    public init(
        apiKey: String,
        userAgent: String,
        baseURL: URL = AcoustIDClient.defaultBaseURL,
        transport: any AcoustIDTransport = URLSessionAcoustIDTransport(),
        minimumRequestInterval: Duration = .seconds(1)
    ) {
        self.apiKey = apiKey
        self.userAgent = userAgent
        self.baseURL = baseURL
        self.transport = transport
        self.minimumRequestInterval = minimumRequestInterval
    }

    public func lookup(_ fingerprint: AudioFingerprint, meta: [String] = ["recordings", "releases"]) async throws -> [AcoustIDMatch] {
        guard !apiKey.isEmpty else { throw FingerprintError.invalidInput("The AcoustID client key is empty.") }
        let url = try makeURL(path: "lookup", queryItems: [
            URLQueryItem(name: "client", value: apiKey),
            URLQueryItem(name: "duration", value: String(Int(fingerprint.durationInSeconds.rounded()))),
            URLQueryItem(name: "fingerprint", value: fingerprint.fingerprint),
            URLQueryItem(name: "meta", value: meta.joined(separator: ","))
        ])
        let response: AcoustIDResponse = try await request(url: url, method: "GET", body: nil)
        return response.results.map(Self.makeMatch)
    }

    public func submit(
        _ submission: AcoustIDSubmission,
        userToken: String?,
        consentGiven: Bool
    ) async throws {
        guard consentGiven else { throw FingerprintError.consentRequired }
        guard let userToken, !userToken.isEmpty else { throw FingerprintError.authenticationRequired }

        let url = try makeURL(path: "submit", queryItems: [])
        let body = [
            URLQueryItem(name: "client", value: apiKey),
            URLQueryItem(name: "user", value: userToken),
            URLQueryItem(name: "duration", value: String(Int(submission.durationInSeconds.rounded()))),
            URLQueryItem(name: "fingerprint", value: submission.fingerprint),
            URLQueryItem(name: "mbid", value: submission.recordingID)
        ]
        let encoded = body.map { item in
            let value = item.value ?? ""
            return "\(Self.formEncode(item.name))=\(Self.formEncode(value))"
        }.joined(separator: "&")
        _ = try await request(url: url, method: "POST", body: Data(encoded.utf8)) as AcoustIDResponse
    }

    private func request<Response: Decodable>(url: URL, method: String, body: Data?) async throws -> Response {
        for attempt in 0..<3 {
            try Task.checkCancellation()
            try await waitForRateLimit()
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.timeoutInterval = 30
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            if body != nil { request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type") }
            request.httpBody = body

            do {
                let response = try await transport.data(for: request)
                if [429, 502, 503, 504].contains(response.statusCode), attempt < 2 {
                    try await Task.sleep(for: retryDelay(response: response, attempt: attempt))
                    continue
                }
                guard (200..<300).contains(response.statusCode) else {
                    throw FingerprintError.network("HTTP \(response.statusCode): \(Self.bodySummary(response.data))")
                }
                do {
                    let decoded = try JSONDecoder().decode(Response.self, from: response.data)
                    if let acoustID = decoded as? AcoustIDResponse, acoustID.status != "ok" {
                        throw FingerprintError.invalidResponse(acoustID.error?.message ?? acoustID.status)
                    }
                    return decoded
                } catch let error as FingerprintError {
                    throw error
                } catch {
                    throw FingerprintError.invalidResponse(error.localizedDescription)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as FingerprintError {
                if attempt == 2 { throw error }
                if case .network = error { continue }
                throw error
            } catch {
                if Task.isCancelled { throw CancellationError() }
                if attempt == 2 { throw FingerprintError.network(error.localizedDescription) }
            }
        }
        throw FingerprintError.network("The request failed without a response.")
    }

    private func makeURL(path: String, queryItems: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw FingerprintError.invalidResponse("Could not construct AcoustID URL.")
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw FingerprintError.invalidResponse("Could not encode AcoustID query parameters.")
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

    private func retryDelay(response: AcoustIDHTTPResponse, attempt: Int) -> Duration {
        if let value = response.headers["retry-after"], let seconds = Double(value) {
            return .milliseconds(Int64(min(max(seconds * 1_000, 250), 10_000)))
        }
        return .milliseconds(Int64(500 * (attempt + 1)))
    }

    private static func makeMatch(_ result: AcoustIDResult) -> AcoustIDMatch {
        AcoustIDMatch(
            id: result.id,
            score: result.score,
            recordings: (result.recordings ?? []).map { recording in
                AcoustIDRecording(
                    id: recording.id,
                    title: recording.title,
                    artist: recording.artists?.compactMap(\.name).joined(separator: ", "),
                    releaseIDs: (recording.releases ?? []).compactMap(\.id)
                )
            }
        )
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func bodySummary(_ data: Data) -> String {
        let value = String(decoding: data.prefix(512), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "empty response" : value
    }
}
