import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import PicardFoundation
import UniformTypeIdentifiers

public enum CoverArtError: Error, LocalizedError, Sendable, Equatable {
    case invalidIdentifier
    case invalidURL(String)
    case insecureURL(String)
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
        case let .insecureURL(value): return "Cover art requires a secure HTTPS connection: \(value)"
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
            let secured = try CoverArtURLPolicy.secureRequest(request)
            let (bytes, response) = try await URLSession.shared.bytes(for: secured, delegate: CoverArtRedirectDelegate.shared)
            defer { bytes.task.cancel() }
            guard response.expectedContentLength <= ArtworkValidation.maximumBytes else {
                throw CoverArtError.invalidImage("The response exceeds 32 MiB.")
            }
            var data = Data()
            for try await byte in bytes {
                if data.count >= ArtworkValidation.maximumBytes { throw CoverArtError.invalidImage("The response exceeds 32 MiB.") }
                data.append(byte)
            }
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
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw CoverArtError.network(error.localizedDescription)
        }
    }
}

private struct CoverArtAPIResponse: Decodable {
    let images: [CoverArtAPIImage]
}

private struct CoverArtAPIImage: Decodable {
    let id: String?
    let types: [String]?
    let comment: String?
    let approved: Bool?
    let image: URL
    let thumbnails: [String: URL]?

    enum CodingKeys: String, CodingKey { case id, types, comment, approved, image, thumbnails }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let string = try? container.decode(String.self, forKey: .id) {
            id = string
        } else {
            id = try container.decodeIfPresent(Int64.self, forKey: .id).map(String.init)
        }
        types = try container.decodeIfPresent([String].self, forKey: .types)
        comment = try container.decodeIfPresent(String.self, forKey: .comment)
        approved = try container.decodeIfPresent(Bool.self, forKey: .approved)
        image = try container.decode(URL.self, forKey: .image)
        thumbnails = try container.decodeIfPresent([String: URL].self, forKey: .thumbnails)
    }

    func model() throws -> CoverArtImage {
        let mappedTypes = (types ?? []).compactMap { ArtworkType(rawValue: $0.lowercased()) }
        var mappedThumbnails: [CoverArtImageSize: URL] = [:]
        for (key, url) in thumbnails ?? [:] {
            switch key {
            case "250": mappedThumbnails[.thumbnail250] = try CoverArtURLPolicy.secureURL(url)
            case "500": mappedThumbnails[.thumbnail500] = try CoverArtURLPolicy.secureURL(url)
            case "1200": mappedThumbnails[.thumbnail1200] = try CoverArtURLPolicy.secureURL(url)
            default: break
            }
        }
        return CoverArtImage(
            id: id ?? SHA256.hash(data: Data(image.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined(),
            types: mappedTypes,
            comment: comment ?? "",
            approved: approved ?? false,
            imageURL: try CoverArtURLPolicy.secureURL(image),
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
    private let rateLimiter: APIRequestRateLimiter
    private let cacheDirectory: URL?

    public init(
        baseURL: URL = CoverArtClient.defaultBaseURL,
        userAgent: String,
        transport: any CoverArtTransport = URLSessionCoverArtTransport(),
        cacheDirectory: URL? = nil,
        minimumRequestInterval: Duration = .seconds(1),
        rateLimiter: APIRequestRateLimiter = .shared
    ) {
        self.baseURL = baseURL
        self.userAgent = userAgent
        self.transport = transport
        self.cacheDirectory = cacheDirectory
        self.minimumRequestInterval = minimumRequestInterval
        self.rateLimiter = rateLimiter
    }

    public func release(identifier: String) async throws -> CoverArtRelease {
        try await fetch(path: "release/\(validatedIdentifier(identifier))")
    }

    public func releaseGroup(identifier: String) async throws -> CoverArtRelease {
        try await fetch(path: "release-group/\(validatedIdentifier(identifier))")
    }

    /// User-entered URLs must already be HTTPS. Legacy upgrading is only for archive responses.
    public func download(url: URL) async throws -> Artwork {
        guard url.scheme?.lowercased() == "https" else { throw CoverArtError.insecureURL("Use an HTTPS image URL.") }
        let secured = try CoverArtURLPolicy.secureURL(url)
        let data = try await fetchData(url: secured, accept: "image/*", validatesImage: true)
        let info = try ArtworkProcessor.inspect(data)
        return Artwork(mimeType: info.mimeType, width: info.width, height: info.height, source: .remote(secured), data: data)
    }

    public func download(_ image: CoverArtImage, size: CoverArtImageSize = .original) async throws -> Artwork {
        let url = try CoverArtURLPolicy.secureURL(image.url(for: size))
        let data = try await fetchData(url: url, accept: "image/*", validatesImage: true)
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
            return CoverArtRelease(identifier: path.split(separator: "/").last.map(String.init) ?? path, images: try response.images.map { try $0.model() })
        } catch let error as CoverArtError {
            removeCachedResponse(for: url)
            throw error
        } catch {
            removeCachedResponse(for: url)
            throw CoverArtError.decoding(error.localizedDescription)
        }
    }

    private func fetchData(url: URL, accept: String = "application/json", validatesImage: Bool = false) async throws -> Data {
        try Task.checkCancellation()
        let url = try CoverArtURLPolicy.secureURL(url)
        let key = cacheKey(for: url)
        if let cacheDirectory,
           let data = try? ArtworkProcessor.readBounded(cacheDirectory.appendingPathComponent(key)) {
            if !validatesImage || (try? ArtworkProcessor.inspect(data)) != nil {
                return data
            }
            removeCachedResponse(for: url)
        }

        for attempt in 0..<3 {
            try Task.checkCancellation()
            try await rateLimiter.wait(for: url.host!.lowercased(), interval: minimumRequestInterval)
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 30
            request.setValue(accept, forHTTPHeaderField: "Accept")
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

            do {
                let response = try await transport.data(for: request)
                if APIRequestPolicy.retryableStatusCodes.contains(response.statusCode) {
                    await rateLimiter.deferRequests(for: url.host!.lowercased(), delay: APIRequestPolicy.retryDelay(headers: response.headers, attempt: attempt))
                    if attempt < 2 { continue }
                }
                guard (200..<300).contains(response.statusCode) else {
                    throw CoverArtError.httpStatus(response.statusCode, APIRequestPolicy.errorSummary(response.data))
                }
                guard response.data.count <= ArtworkValidation.maximumBytes else { throw CoverArtError.invalidImage("The response exceeds 32 MiB.") }
                if validatesImage { _ = try ArtworkProcessor.inspect(response.data) }
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
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                if attempt == 2 { throw CoverArtError.network(error.localizedDescription) }
            }
        }
        throw CoverArtError.network("The request failed without a response.")
    }

    private func validatedIdentifier(_ identifier: String) throws -> String {
        let value = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let identifier = UUID(uuidString: value) else { throw CoverArtError.invalidIdentifier }
        return identifier.uuidString.lowercased()
    }

    private func makeURL(path: String) throws -> URL {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw CoverArtError.invalidURL(path)
        }
        return url
    }

    private func removeCachedResponse(for url: URL) {
        guard let cacheDirectory else { return }
        try? FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent(cacheKey(for: url)))
    }

    private func cacheKey(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func isRetryable(_ error: CoverArtError) -> Bool {
        if case .network = error { return true }
        if case let .httpStatus(status, _) = error { return APIRequestPolicy.retryableStatusCodes.contains(status) }
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

public enum ArtworkOutputFormat: String, Codable, Sendable, CaseIterable {
    case png
    case jpeg

    fileprivate var uti: CFString {
        switch self {
        case .png: return UTType.png.identifier as CFString
        case .jpeg: return UTType.jpeg.identifier as CFString
        }
    }

    public var mimeType: String {
        switch self {
        case .png: return "image/png"
        case .jpeg: return "image/jpeg"
        }
    }
}

public struct ArtworkProcessor: Sendable {
    public init() {}

    public static func inspect(_ data: Data) throws -> ArtworkImageInfo {
        do {
            let info = try ArtworkValidation.inspect(data)
            return ArtworkImageInfo(mimeType: info.mimeType, width: info.width, height: info.height)
        } catch { throw CoverArtError.invalidImage(error.localizedDescription) }
    }

    public static func readBounded(_ url: URL) throws -> Data {
        guard url.isFileURL, try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw CoverArtError.invalidImage("Choose a regular image file.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: ArtworkValidation.maximumBytes + 1) ?? Data()
        guard data.count <= ArtworkValidation.maximumBytes else { throw CoverArtError.invalidImage("The image exceeds 32 MiB.") }
        return data
    }

    public static func importFile(_ url: URL, type: ArtworkType = .front) throws -> Artwork {
        let data = try readBounded(url)
        let info = try inspect(data)
        return Artwork(type: type, mimeType: info.mimeType, width: info.width, height: info.height, source: .localFile(url), data: data)
    }

    public static func resize(_ data: Data, maximumPixelSize: Int, format: ArtworkOutputFormat? = nil, quality: Double = 0.92) throws -> Data {
        let info = try inspect(data)
        guard (1...ArtworkValidation.maximumSide).contains(maximumPixelSize), quality.isFinite, (0...1).contains(quality) else {
            throw CoverArtError.processing("Invalid maximum dimensions or JPEG quality.")
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: min(maximumPixelSize, max(info.width, info.height)),
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else {
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
        let encodesJPEG = format == .jpeg || (format == nil && info.mimeType == "image/jpeg")
        if encodesJPEG {
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let resized = context.makeImage() else { throw CoverArtError.processing("Could not render the resized image.") }

        let result = NSMutableData()
        guard let finalDestination = CGImageDestinationCreateWithData(result, format?.uti ?? (CGImageSourceGetType(source) ?? UTType.png.identifier as CFString), 1, nil) else {
            throw CoverArtError.processing("Could not create the encoded image destination.")
        }
        let properties: [CFString: Any] = encodesJPEG ? [kCGImageDestinationLossyCompressionQuality: quality] : [:]
        CGImageDestinationAddImage(finalDestination, resized, properties as CFDictionary)
        guard CGImageDestinationFinalize(finalDestination) else { throw CoverArtError.processing("Could not encode the resized image.") }
        let encoded = result as Data
        _ = try inspect(encoded)
        return encoded
    }

    public static func deduplicate(_ artwork: [Artwork]) -> [Artwork] {
        var hashes = Set<String>()
        return artwork.filter { artwork in
            guard let hash = artwork.contentHash else { return true }
            return hashes.insert("\(artwork.type.rawValue):\(hash)").inserted
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
            guard let type = Self.type(for: url), let image = try? ArtworkProcessor.importFile(url, type: type) else { continue }
            artwork.append(image)
        }
        return ArtworkCollection(images: ArtworkProcessor.deduplicate(artwork))
    }

    private static func type(for url: URL) -> ArtworkType? {
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        if ["back", "backcover", "back-cover"].contains(where: stem.contains) { return .back }
        if ["front", "cover", "folder", "albumart", "album-art"].contains(where: stem.contains) { return .front }
        if ["booklet", "leaflet", "scan"].contains(where: stem.contains) { return .booklet }
        if stem.contains("media") || stem.contains("disc") { return .media }
        let extensionName = url.pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "heic", "heif", "webp"].contains(extensionName) ? .other : nil
    }
}
