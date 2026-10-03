import Foundation

/// Shared by all instances of a service client, not just a single actor.
/// Recheck the gate after every suspension so concurrent callers cannot burst.
public actor APIRequestRateLimiter {
    public static let shared = APIRequestRateLimiter()
    private var nextRequest: [String: ContinuousClock.Instant] = [:]

    public init() {}

    public func wait(for service: String, interval: Duration) async throws {
        while true {
            try Task.checkCancellation()
            let now = ContinuousClock.now
            if let next = nextRequest[service], next > now {
                try await Task.sleep(until: next, clock: .continuous)
                continue
            }
            nextRequest[service] = now.advanced(by: max(.zero, interval))
            return
        }
    }

    public func deferRequests(for service: String, delay: Duration) {
        let deadline = ContinuousClock.now.advanced(by: max(.zero, delay))
        nextRequest[service] = max(nextRequest[service] ?? deadline, deadline)
    }
}

public enum APIRequestPolicy {
    public static let retryableStatusCodes: Set<Int> = [429, 500, 502, 503, 504]

    public static func isSecure(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false
            && url.user == nil && url.password == nil
    }

    /// Also encode literal plus signs: form parsers otherwise turn them into spaces.
    public static func formEncoded(_ items: [URLQueryItem]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func encode(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        return Data(items.map { "\(encode($0.name))=\(encode($0.value ?? ""))" }.joined(separator: "&").utf8)
    }

    /// Retry-After can be seconds or an HTTP date. Never shorten the server's delay.
    public static func retryDelay(headers: [String: String], attempt: Int, now: Date = Date()) -> Duration {
        if let value = headers.first(where: { $0.key.lowercased() == "retry-after" })?.value {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let seconds: Double?
            if let numeric = Double(trimmed), numeric.isFinite, numeric >= 0 {
                seconds = numeric
            } else {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
                seconds = formatter.date(from: trimmed).map { max(0, $0.timeIntervalSince(now)) }
            }
            if let seconds, seconds.isFinite {
                // Duration's seconds initializer uses Int64; avoid hostile numeric overflow.
                return .seconds(min(seconds, Double(Int32.max)))
            }
        }
        return .milliseconds(500 * Int64(attempt + 1))
    }

    public static func errorSummary(_ data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let message = object["error"] as? String { return String(message.prefix(512)) }
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
                return String(message.prefix(512))
            }
            if let message = object["message"] as? String { return String(message.prefix(512)) }
        }
        let value = String(decoding: data.prefix(512), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "empty response" : value
    }
}

/// Metadata APIs may not downgrade to cleartext, even through a server redirect.
public final class SecureAPIRequestDelegate: NSObject, URLSessionTaskDelegate {
    public static let shared = SecureAPIRequestDelegate()

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let url = request.url, APIRequestPolicy.isSecure(url),
              url.host?.lowercased() == response.url?.host?.lowercased(),
              (url.port ?? 443) == (response.url?.port ?? 443) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
