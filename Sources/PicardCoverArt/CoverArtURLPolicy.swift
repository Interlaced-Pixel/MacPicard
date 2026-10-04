import Foundation

/// The archive still publishes HTTP artwork links in its JSON responses.
/// Upgrade only known archive hosts; never permit a cleartext network request.
enum CoverArtURLPolicy {
    static func secureURL(_ url: URL) throws -> URL {
        guard var components = URLComponents(url: url.absoluteURL, resolvingAgainstBaseURL: true),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil else {
            throw CoverArtError.invalidURL("An absolute URL without embedded credentials is required.")
        }
        switch components.scheme?.lowercased() {
        case "https":
            return url.absoluteURL
        case "http":
            guard host == "coverartarchive.org" || host == "archive.org" || host.hasSuffix(".archive.org"),
                  components.port == nil || components.port == 80 else {
                throw CoverArtError.insecureURL(host)
            }
            components.scheme = "https"
            components.port = nil
            guard let secured = components.url else { throw CoverArtError.invalidURL("Could not upgrade the archive URL.") }
            return secured
        default:
            throw CoverArtError.invalidURL("Use an absolute HTTPS image URL.")
        }
    }

    static func secureRequest(_ request: URLRequest) throws -> URLRequest {
        guard let url = request.url else { throw CoverArtError.invalidURL("Missing request URL") }
        var secured = request
        secured.url = try secureURL(url)
        return secured
    }
}

/// Task-specific delegation retains URLSession's default TLS and ATS checks.
/// Each redirect is validated too, including redirects from archive mirrors.
final class CoverArtRedirectDelegate: NSObject, URLSessionTaskDelegate {
    static let shared = CoverArtRedirectDelegate()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(try? CoverArtURLPolicy.secureRequest(request))
    }
}
