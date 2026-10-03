import Foundation
import XCTest
@testable import PicardFoundation

final class APIRequestPolicyTests: XCTestCase {
    func testConcurrentCallersCannotBurstAfterSuspending() async throws {
        let limiter = APIRequestRateLimiter()
        let times = try await withThrowingTaskGroup(of: ContinuousClock.Instant.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    try await limiter.wait(for: "service", interval: .milliseconds(30))
                    return ContinuousClock.now
                }
            }
            var result: [ContinuousClock.Instant] = []
            for try await time in group { result.append(time) }
            return result.sorted()
        }
        for pair in zip(times, times.dropFirst()) {
            XCTAssertGreaterThanOrEqual(pair.0.duration(to: pair.1), .milliseconds(25))
        }
    }

    func testRateLimitCancellationAndIndependentServices() async throws {
        let limiter = APIRequestRateLimiter()
        await limiter.deferRequests(for: "busy", delay: .seconds(10))
        let waiting = Task { try await limiter.wait(for: "busy", interval: .seconds(1)) }
        waiting.cancel()
        do { try await waiting.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        let start = ContinuousClock.now
        try await limiter.wait(for: "other", interval: .seconds(1))
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(100))
    }

    func testRetryAfterSupportsSecondsDatesAndDoesNotTruncateDelay() {
        XCTAssertTrue(APIRequestPolicy.retryableStatusCodes.contains(500))
        XCTAssertFalse(APIRequestPolicy.retryableStatusCodes.contains(400))
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let future = formatter.string(from: now.addingTimeInterval(120))
        XCTAssertEqual(APIRequestPolicy.retryDelay(headers: ["Retry-After": "120"], attempt: 0), .seconds(120))
        XCTAssertEqual(APIRequestPolicy.retryDelay(headers: ["retry-after": future], attempt: 0, now: now), .seconds(120))
        XCTAssertEqual(APIRequestPolicy.retryDelay(headers: ["retry-after": "NaN"], attempt: 1), .seconds(1))
        XCTAssertEqual(APIRequestPolicy.retryDelay(headers: ["retry-after": "-10"], attempt: 0), .milliseconds(500))
    }

    func testFormEncodingPreservesLiteralPlusAndUnicode() throws {
        let value = "a+b & = café /? #"
        let data = APIRequestPolicy.formEncoded([URLQueryItem(name: "fingerprint.0", value: value)])
        let body = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(body.contains("%2B"))
        XCTAssertFalse(body.contains("+"))
        let components = try XCTUnwrap(URLComponents(string: "https://api.example/?\(body)"))
        XCTAssertEqual(components.queryItems?.first?.value, value)
    }

    func testErrorSummaryExtractsServiceMessage() {
        XCTAssertEqual(APIRequestPolicy.errorSummary(Data(#"{"error":"invalid inc","help":"long help URL"}"#.utf8)), "invalid inc")
        XCTAssertEqual(APIRequestPolicy.errorSummary(Data(#"{"error":{"code":4,"message":"invalid client"}}"#.utf8)), "invalid client")
    }

    func testDefaultUserAgentUpgradesOldConfigurationAndPreservesCustomization() throws {
        let old = try JSONDecoder().decode(AppConfiguration.self, from: Data(#"{"requestUserAgent":"MacPicard/0.1.0"}"#.utf8))
        XCTAssertEqual(old.requestUserAgent, AppConfiguration.defaultUserAgent)
        XCTAssertTrue(old.requestUserAgent.contains("https://"))
        XCTAssertEqual(AppConfiguration(requestUserAgent: "MyTagger/2.0 (me@example.com)").requestUserAgent, "MyTagger/2.0 (me@example.com)")
    }

    func testMetadataRedirectsCannotLeakCredentialsOrDowngrade() async throws {
        let source = URL(string: "https://musicbrainz.org/ws/2/release")!
        let task = URLSession.shared.dataTask(with: source)
        defer { task.cancel() }
        let response = try XCTUnwrap(HTTPURLResponse(url: source, statusCode: 307, httpVersion: nil, headerFields: nil))
        for (target, allowed) in [
            ("https://musicbrainz.org/ws/2/release/", true),
            ("http://musicbrainz.org/ws/2/release/", false),
            ("https://other.example/", false),
            ("https://musicbrainz.org:4443/", false),
            ("https://user:pass@musicbrainz.org/", false)
        ] {
            let result: URLRequest? = await withCheckedContinuation { continuation in
                SecureAPIRequestDelegate.shared.urlSession(
                    URLSession.shared, task: task, willPerformHTTPRedirection: response,
                    newRequest: URLRequest(url: URL(string: target)!),
                    completionHandler: { continuation.resume(returning: $0) }
                )
            }
            XCTAssertEqual(result != nil, allowed)
        }
    }
}
