import Foundation
import Darwin
import PicardMusicBrainz
import PicardFoundation

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
    case httpStatus(Int, String)
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
        case let .httpStatus(status, message): return "AcoustID returned HTTP \(status): \(message)"
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
                  let duration = response.duration, duration.isFinite, duration > 0, duration < Double(Int32.max) / 1_000 else {
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

public protocol AudioFingerprintProviding: Sendable {
    func fingerprint(url: URL) async throws -> AudioFingerprint
}

public actor ChromaprintFingerprintProvider: AudioFingerprintProviding {
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

    public func fingerprint(url: URL) async throws -> AudioFingerprint {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw FingerprintError.invalidInput("The audio file is not readable: \(url.path)")
        }
        guard let executableURL else {
            throw FingerprintError.unavailable("Install Chromaprint's fpcalc command-line tool.")
        }

        let run = FingerprintProcess(executable: executableURL, arguments: ["-algorithm", "2", "-length", "120", "-json", url.path], timeoutSeconds: 120)
        let task = Task.detached(priority: .utility) { try run.execute() }
        return try await withTaskCancellationHandler {
            let data = try await task.value
            try Task.checkCancellation()
            return try ChromaprintDecoder.decode(data)
        } onCancel: { run.cancel(); task.cancel() }
    }

    public static func version(executableURL: URL) async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else { throw FingerprintError.unavailable("Choose an executable fpcalc in Settings.") }
        let run = FingerprintProcess(executable: executableURL, arguments: ["-version"], timeoutSeconds: 5)
        let task = Task.detached(priority: .utility) { try run.execute() }
        return try await withTaskCancellationHandler {
            let text = String(decoding: try await task.value, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            try Task.checkCancellation()
            guard text.lowercased().contains("fpcalc") else { throw FingerprintError.unavailable("The selected executable did not identify itself as fpcalc.") }
            return text
        } onCancel: { run.cancel(); task.cancel() }
    }
}

/// Process is protected by the lock; pipe draining happens only on a utility worker.
private final class FingerprintProcess: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private let output = Pipe()
    private var cancelled = false
    private var timedOut = false
    private let timeoutSeconds: Double
    init(executable: URL, arguments: [String], timeoutSeconds: Double) {
        self.timeoutSeconds = timeoutSeconds
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        // Tool diagnostics can contain private paths or fingerprints; never relay them to logs/UI.
        process.standardError = FileHandle.nullDevice
    }
    func cancel(timedOut: Bool = false) {
        lock.lock(); cancelled = true; self.timedOut = self.timedOut || timedOut
        if process.isRunning { process.terminate() }
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { [self] in
            lock.lock(); defer { lock.unlock() }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
    func execute() throws -> Data {
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do { try process.run() } catch { lock.unlock(); throw FingerprintError.unavailable("The configured fpcalc executable could not be started.") }
        lock.unlock()
        let timeout = DispatchWorkItem { [self] in cancel(timedOut: true) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds, execute: timeout)
        defer { timeout.cancel() }
        var data = Data()
        do {
            while let chunk = try output.fileHandleForReading.read(upToCount: 8_192), !chunk.isEmpty {
                data.append(chunk)
                if data.count > 1_048_576 { cancel(); throw FingerprintError.invalidOutput("Calculator output exceeded the safety limit.") }
            }
        } catch { cancel(); process.waitUntilExit(); throw error }
        process.waitUntilExit()
        lock.lock(); let wasCancelled = cancelled; let didTimeOut = timedOut; lock.unlock()
        if didTimeOut { throw FingerprintError.unavailable("The calculator timed out. Check the executable and audio file, then retry explicitly.") }
        if wasCancelled { throw CancellationError() }
        guard process.terminationStatus == 0 else { throw FingerprintError.processFailed(process.terminationStatus, "Check that this audio file is valid and supported by fpcalc.") }
        return data
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
            guard let url = request.url, APIRequestPolicy.isSecure(url) else {
                throw FingerprintError.invalidInput("A secure HTTPS endpoint is required.")
            }
            let (data, response) = try await URLSession.shared.data(for: request, delegate: SecureAPIRequestDelegate.shared)
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
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
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
    private let rateLimiter: APIRequestRateLimiter
    private static let allowedMetadata: Set<String> = ["recordings", "recordingids", "releases", "releaseids", "releasegroups", "releasegroupids", "tracks", "compress", "usermeta", "sources", "isrcs"]

    public init(
        apiKey: String,
        userAgent: String,
        baseURL: URL = AcoustIDClient.defaultBaseURL,
        transport: any AcoustIDTransport = URLSessionAcoustIDTransport(),
        minimumRequestInterval: Duration = .seconds(1),
        rateLimiter: APIRequestRateLimiter = .shared
    ) {
        self.apiKey = apiKey
        self.userAgent = userAgent
        self.baseURL = baseURL
        self.transport = transport
        self.minimumRequestInterval = minimumRequestInterval
        self.rateLimiter = rateLimiter
    }

    public func lookup(_ fingerprint: AudioFingerprint, meta: [String] = ["recordings", "releases"]) async throws -> [AcoustIDMatch] {
        try validate(fingerprint: fingerprint.fingerprint, duration: fingerprint.durationInSeconds)
        guard meta.allSatisfy({ Self.allowedMetadata.contains($0) }) else {
            throw FingerprintError.invalidInput("An unsupported AcoustID metadata option was requested.")
        }
        let url = try makeURL(path: "lookup", queryItems: [])
        let body = APIRequestPolicy.formEncoded([
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "client", value: apiKey),
            URLQueryItem(name: "duration", value: String(Int(fingerprint.durationInSeconds.rounded()))),
            URLQueryItem(name: "fingerprint", value: fingerprint.fingerprint),
            URLQueryItem(name: "meta", value: Array(Set(meta)).sorted().joined(separator: " "))
        ])
        let response: AcoustIDResponse = try await request(url: url, method: "POST", body: body, canRetry: true)
        return response.results.map(Self.makeMatch)
    }

    public func submit(
        _ submission: AcoustIDSubmission,
        userToken: String?,
        consentGiven: Bool
    ) async throws {
        guard consentGiven else { throw FingerprintError.consentRequired }
        guard let userToken, !userToken.isEmpty else { throw FingerprintError.authenticationRequired }
        try validate(fingerprint: submission.fingerprint, duration: submission.durationInSeconds)
        guard UUID(uuidString: submission.recordingID) != nil else {
            throw FingerprintError.invalidInput("Submission requires a MusicBrainz recording UUID.")
        }

        let url = try makeURL(path: "submit", queryItems: [])
        let body = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "client", value: apiKey),
            URLQueryItem(name: "user", value: userToken),
            URLQueryItem(name: "duration.0", value: String(Int(submission.durationInSeconds.rounded()))),
            URLQueryItem(name: "fingerprint.0", value: submission.fingerprint),
            URLQueryItem(name: "mbid.0", value: submission.recordingID)
        ]
        // Submissions have no idempotency key. Never duplicate a possibly accepted write.
        _ = try await request(url: url, method: "POST", body: APIRequestPolicy.formEncoded(body), canRetry: false) as AcoustIDResponse
    }

    private func request<Response: Decodable>(url: URL, method: String, body: Data?, canRetry: Bool) async throws -> Response {
        let attempts = canRetry ? 3 : 1
        for attempt in 0..<attempts {
            try Task.checkCancellation()
            try await rateLimiter.wait(for: url.host!.lowercased(), interval: minimumRequestInterval)
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.timeoutInterval = 30
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            if body != nil { request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type") }
            request.httpBody = body

            do {
                let response = try await transport.data(for: request)
                if APIRequestPolicy.retryableStatusCodes.contains(response.statusCode) {
                    await rateLimiter.deferRequests(for: url.host!.lowercased(), delay: APIRequestPolicy.retryDelay(headers: response.headers, attempt: attempt))
                    if attempt < attempts - 1 { continue }
                }
                guard (200..<300).contains(response.statusCode) else {
                    throw FingerprintError.httpStatus(response.statusCode, APIRequestPolicy.errorSummary(response.data))
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
                if attempt == attempts - 1 { throw error }
                if case .network = error { continue }
                throw error
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                if attempt == attempts - 1 { throw FingerprintError.network(error.localizedDescription) }
            }
        }
        throw FingerprintError.network("The request failed without a response.")
    }

    private func makeURL(path: String, queryItems: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw FingerprintError.invalidResponse("Could not construct AcoustID URL.")
        }
        components.queryItems = queryItems
        guard let url = components.url, APIRequestPolicy.isSecure(url) else {
            throw FingerprintError.invalidResponse("Could not encode AcoustID query parameters.")
        }
        return url
    }

    private func validate(fingerprint: String, duration: Double) throws {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FingerprintError.invalidInput("The AcoustID client key is empty.")
        }
        guard !fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              duration.isFinite, duration.rounded() >= 1, duration < Double(Int32.max) else {
            throw FingerprintError.invalidInput("A fingerprint and positive finite duration are required.")
        }
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

}
