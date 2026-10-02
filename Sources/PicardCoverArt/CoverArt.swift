import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import PicardFoundation
import UniformTypeIdentifiers

public enum CoverArtError: Error, LocalizedError, Sendable, Equatable {
    case invalidIdentifier
    case invalidURL(String)
    case network(String)
    case httpStatus(Int, String)
    case decoding(String)
    case invalidImage(String)
    case unsupportedImageFormat(String)
    case processing(String)

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier: return "A MusicBrainz release or release-group identifier is required."
        case let .invalidURL(value): return "Cover Art Archive URL is invalid: \(value)"
        case let .network(message): return "Cover Art Archive request failed: \(message)"
        case let .httpStatus(status, body): return "Cover Art Archive returned HTTP \(status): \(body)"
        case let .decoding(message): return "Cover Art Archive response decoding failed: \(message)"
        case let .invalidImage(message): return "The downloaded image is invalid: \(message)"
        case let .unsupportedImageFormat(message): return "The image format is unsupported: \(message)"
        case let .processing(message): return "Image processing failed: \(message)"
        }
    }
}

public enum CoverArtImageSize: String, Codable, Sendable, CaseIterable {
    case thumbnail250 = "250"
    case thumbnail500 = "500"
    case thumbnail1200 = "1200"
    case original
}

public struct CoverArtImage: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let types: [ArtworkType]
    public let comment: String
    public let approved: Bool
    public let imageURL: URL
    public let thumbnails: [CoverArtImageSize: URL]

    public init(
        id: String,
        types: [ArtworkType],
        comment: String = "",
        approved: Bool = false,
        imageURL: URL,
        thumbnails: [CoverArtImageSize: URL] = [:]
    ) {
        self.id = id
        self.types = types
        self.comment = comment
        self.approved = approved
        self.imageURL = imageURL
        self.thumbnails = thumbnails
    }

    public var primaryType: ArtworkType {
        types.first ?? .other
    }

    public func url(for size: CoverArtImageSize) -> URL {
        thumbnails[size] ?? imageURL
    }
}

public struct CoverArtRelease: Codable, Sendable, Equatable {
    public let identifier: String
    public let images: [CoverArtImage]

    public init(identifier: String, images: [CoverArtImage]) {
        self.identifier = identifier
        self.images = images
    }
}

public struct CoverArtHTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let data: Data

    public init(statusCode: Int, headers: [String: String] = [:], data: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.data = data
    }
}

public protocol CoverArtTransport: Sendable {
    func data(for request: URLRequest) async throws -> CoverArtHTTPResponse
}

public struct URLSessionCoverArtTransport: CoverArtTransport, Sendable {
    public init() {}

    public func data(for request: URLRequest) async throws -> CoverArtHTTPResponse {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw CoverArtError.network("The server returned a non-HTTP response.")
            }
            var headers: [String: String] = [:]
            for (key, value) in httpResponse.allHeaderFields {
                headers[String(describing: key).lowercased()] = String(describing: value)
            }
            return CoverArtHTTPResponse(statusCode: httpResponse.statusCode, headers: headers, data: data)
        } catch let error as CoverArtError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CoverArtError.network(error.localizedDescription)
        }
    }
}

private struct CoverArtAPIResponse: Decodable {
    let images: [CoverArtAPIImage]
}

private struct CoverArtAPIImage: Decodable {
    let id: Int?
    let types: [String]?
    let comment: String?
    let approved: Bool?
    let image: URL
    let thumbnails: [String: URL]?

    var model: CoverArtImage {
        let mappedTypes = (types ?? []).compactMap { ArtworkType(rawValue: $0.lowercased()) }
        var mappedThumbnails: [CoverArtImageSize: URL] = [:]
        for (key, url) in thumbnails ?? [:] {
            switch key {
            case "250": mappedThumbnails[.thumbnail250] = url
            case "500": mappedThumbnails[.thumbnail500] = url
            case "1200": mappedThumbnails[.thumbnail1200] = url
            default: break
            }
        }
        return CoverArtImage(
            id: String(id ?? abs(image.absoluteString.hashValue)),
            types: mappedTypes,
            comment: comment ?? "",
            approved: approved ?? false,
            imageURL: image,
            thumbnails: mappedThumbnails
        )
    }
}

public actor CoverArtClient {
    public static let defaultBaseURL = URL(string: "https://coverartarchive.org")!

    private let baseURL: URL
    private let userAgent: String
    private let transport: any CoverArtTransport
    private let minimumRequestInterval: Duration
    private var lastRequest: ContinuousClock.Instant?
    private let cacheDirectory: URL?

    public init(
        baseURL: URL = CoverArtClient.defaultBaseURL,
        userAgent: String,
        transport: any CoverArtTransport = URLSessionCoverArtTransport(),
        cacheDirectory: URL? = nil,
        minimumRequestInterval: Duration = .seconds(1)
    ) {
        self.baseURL = baseURL
        self.userAgent = userAgent
        self.transport = transport
        self.cacheDirectory = cacheDirectory
        self.minimumRequestInterval = minimumRequestInterval
    }

    public func release(identifier: String) async throws -> CoverArtRelease {
        try await fetch(path: "release/\(validatedIdentifier(identifier))")
    }

    public func releaseGroup(identifier: String) async throws -> CoverArtRelease {
        try await fetch(path: "release-group/\(validatedIdentifier(identifier))")
    }

    public func download(_ image: CoverArtImage, size: CoverArtImageSize = .original) async throws -> Artwork {
        let url = image.url(for: size)
        let data = try await fetchData(url: url)
        let info = try ArtworkProcessor.inspect(data)
        return Artwork(
            type: image.primaryType,
            mimeType: info.mimeType,
            description: image.comment,
            width: info.width,
            height: info.height,
            source: .remote(url),
            data: data
        )
    }

    private func fetch(path: String) async throws -> CoverArtRelease {
        let url = try makeURL(path: path)
        let data = try await fetchData(url: url)
        do {
            let response = try JSONDecoder().decode(CoverArtAPIResponse.self, from: data)
            return CoverArtRelease(identifier: path.split(separator: "/").last.map(String.init) ?? path, images: response.images.map(\.model))
        } catch {
            throw CoverArtError.decoding(error.localizedDescription)
        }
    }

    private func fetchData(url: URL) async throws -> Data {
        let key = cacheKey(for: url)
        if let cacheDirectory,
           let data = try? Data(contentsOf: cacheDirectory.appendingPathComponent(key)) {
            return data
        }

        for attempt in 0..<3 {
            try Task.checkCancellation()
            try await waitForRateLimit()
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 30
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

            do {
                let response = try await transport.data(for: request)
                if [429, 502, 503, 504].contains(response.statusCode), attempt < 2 {
                    try await Task.sleep(for: retryDelay(response: response, attempt: attempt))
                    continue
                }
                guard (200..<300).contains(response.statusCode) else {
                    throw CoverArtError.httpStatus(response.statusCode, Self.bodySummary(response.data))
                }
                if let cacheDirectory {
                    try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
                    try? response.data.write(to: cacheDirectory.appendingPathComponent(key), options: [.atomic])
                }
                return response.data
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as CoverArtError {
                if attempt == 2 || !Self.isRetryable(error) { throw error }
            } catch {
                if Task.isCancelled { throw CancellationError() }
                if attempt == 2 { throw CoverArtError.network(error.localizedDescription) }
            }
        }
        throw CoverArtError.network("The request failed without a response.")
    }

    private func validatedIdentifier(_ identifier: String) throws -> String {
        let value = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("/") else { throw CoverArtError.invalidIdentifier }
        return value
    }

    private func makeURL(path: String) throws -> URL {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw CoverArtError.invalidURL(path)
        }
        return url
    }

    private func waitForRateLimit() async throws {
        let now = ContinuousClock.now
        if let lastRequest {
            let elapsed = lastRequest.duration(to: now)
            if elapsed < minimumRequestInterval { try await Task.sleep(for: minimumRequestInterval - elapsed) }
        }
        lastRequest = ContinuousClock.now
    }

    private func retryDelay(response: CoverArtHTTPResponse, attempt: Int) -> Duration {
        if let value = response.headers["retry-after"], let seconds = Double(value) {
            return .milliseconds(Int64(min(max(seconds * 1_000, 250), 10_000)))
        }
        return .milliseconds(Int64(500 * (attempt + 1)))
    }

    private func cacheKey(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func bodySummary(_ data: Data) -> String {
        let value = String(decoding: data.prefix(512), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "empty response" : value
    }

    private static func isRetryable(_ error: CoverArtError) -> Bool {
        if case .network = error { return true }
        if case let .httpStatus(status, _) = error { return [429, 502, 503, 504].contains(status) }
        return false
    }
}

public struct ArtworkImageInfo: Codable, Sendable, Equatable {
    public let mimeType: String
    public let width: Int
    public let height: Int

    public init(mimeType: String, width: Int, height: Int) {
        self.mimeType = mimeType
        self.width = width
        self.height = height
    }
}

public enum ArtworkOutputFormat: String, Codable, Sendable {
    case png
    case jpeg

    fileprivate var uti: CFString {
        switch self {
        case .png: return UTType.png.identifier as CFString
        case .jpeg: return UTType.jpeg.identifier as CFString
        }
    }

    fileprivate var mimeType: String {
        switch self {
        case .png: return "image/png"
        case .jpeg: return "image/jpeg"
        }
    }
}

public struct ArtworkProcessor: Sendable {
    public init() {}

    public static func inspect(_ data: Data) throws -> ArtworkImageInfo {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CoverArtError.invalidImage("ImageIO could not decode the image data.")
        }
        let typeIdentifier = CGImageSourceGetType(source) as String? ?? UTType.png.identifier
        let mimeType = UTType(typeIdentifier)?.preferredMIMEType ?? "application/octet-stream"
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? image.width
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? image.height
        return ArtworkImageInfo(mimeType: mimeType, width: width, height: height)
    }

    public static func resize(_ data: Data, maximumPixelSize: Int, format: ArtworkOutputFormat? = nil, quality: Double = 0.92) throws -> Data {
        guard maximumPixelSize > 0 else { throw CoverArtError.processing("The maximum pixel size must be positive.") }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CoverArtError.invalidImage("ImageIO could not decode the image data.")
        }
        let scale = min(1, Double(maximumPixelSize) / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw CoverArtError.processing("Could not create an image rendering context.")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let resized = context.makeImage() else { throw CoverArtError.processing("Could not render the resized image.") }

        let result = NSMutableData()
        guard let finalDestination = CGImageDestinationCreateWithData(result, format?.uti ?? (CGImageSourceGetType(source) ?? UTType.png.identifier as CFString), 1, nil) else {
            throw CoverArtError.processing("Could not create the encoded image destination.")
        }
        let properties: [CFString: Any] = format == .jpeg ? [kCGImageDestinationLossyCompressionQuality: max(0, min(1, quality))] : [:]
        CGImageDestinationAddImage(finalDestination, resized, properties as CFDictionary)
        guard CGImageDestinationFinalize(finalDestination) else { throw CoverArtError.processing("Could not encode the resized image.") }
        return result as Data
    }

    public static func deduplicate(_ artwork: [Artwork]) -> [Artwork] {
        var hashes = Set<String>()
        return artwork.filter { artwork in
            guard let hash = artwork.contentHash else { return true }
            return hashes.insert(hash).inserted
        }
    }
}

public struct LocalArtworkFinder: Sendable {
    public init() {}

    public func discover(in directory: URL) throws -> ArtworkCollection {
        let keys: [URLResourceKey] = [.isRegularFileKey, .nameKey, .contentTypeKey]
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        var artwork: [Artwork] = []
        for url in urls.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            guard let type = Self.type(for: url), let data = try? Data(contentsOf: url), let info = try? ArtworkProcessor.inspect(data) else { continue }
            artwork.append(Artwork(type: type, mimeType: info.mimeType, source: .localFile(url), data: data))
        }
        return ArtworkCollection(images: ArtworkProcessor.deduplicate(artwork))
    }

    private static func type(for url: URL) -> ArtworkType? {
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        if ["front", "cover", "folder", "albumart", "album-art"].contains(where: stem.contains) { return .front }
        if ["back", "backcover", "back-cover"].contains(where: stem.contains) { return .back }
        if ["booklet", "leaflet", "scan"].contains(where: stem.contains) { return .booklet }
        if stem.contains("media") || stem.contains("disc") { return .media }
        let extensionName = url.pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "heic", "heif", "webp"].contains(extensionName) ? .other : nil
    }
}
