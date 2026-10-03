import Foundation
import PicardFoundation
import XCTest
@testable import PicardFingerprint

final class FingerprintTests: XCTestCase {
    func testChromaprintJSONDecoding() throws {
        let data = Data(#"{"fingerprint":"AQAB","duration":183.5,"algorithm":"chromaprint"}"#.utf8)
        let fingerprint = try ChromaprintDecoder.decode(data)
        XCTAssertEqual(fingerprint.fingerprint, "AQAB")
        XCTAssertEqual(fingerprint.durationInSeconds, 183.5)
        XCTAssertEqual(fingerprint.algorithm, "chromaprint")
    }

    func testAcoustIDLookupBuildsRequestAndMapsRecordings() async throws {
        let transport = StubTransport(response: Data(#"""
        {
          "status": "ok",
          "results": [{
            "id": "acoustid-1",
            "score": 0.97,
            "recordings": [{
              "id": "recording-1",
              "title": "Example Track",
              "artists": [{"name": "Example Artist"}],
              "releases": [{"id": "release-1"}]
            }]
          }]
        }
        """#.utf8))
        let client = AcoustIDClient(
            apiKey: "client-key",
            userAgent: "MacPicardTests/1.0",
            baseURL: URL(string: "https://acoustid.example/v2")!,
            transport: transport,
            minimumRequestInterval: .zero
        )

        let matches = try await client.lookup(AudioFingerprint(fingerprint: "AQAB", durationInSeconds: 183.5))

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].recordings[0].id, "recording-1")
        XCTAssertEqual(matches[0].recordings[0].releaseIDs, ["release-1"])
        let request = await transport.request()
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "MacPicardTests/1.0")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertTrue(request.url!.query?.isEmpty ?? true, "Keys and long fingerprints must not be placed in the URL")
        let fields = try formFields(request)
        XCTAssertEqual(fields["duration"], "184")
        XCTAssertEqual(fields["meta"], "recordings releases")
        XCTAssertEqual(fields["format"], "json")
    }

    func testSubmissionContractUsesIndexedParametersAndDoesNotRetryWrites() async throws {
        let transport = ScenarioTransport(responses: [AcoustIDHTTPResponse(statusCode: 502, data: Data("unavailable".utf8))])
        let client = AcoustIDClient(apiKey: "client+key", userAgent: "Tests/1.0", baseURL: URL(string: "https://acoustid.example/v2")!, transport: transport, minimumRequestInterval: .zero)
        let recording = "87e36ab4-6914-44ab-b740-7abb37678040"
        do {
            try await client.submit(AcoustIDSubmission(fingerprint: "AQAB+test", durationInSeconds: 237, recordingID: recording), userToken: "user&token", consentGiven: true)
            XCTFail("Expected HTTP 502")
        } catch let error as FingerprintError { XCTAssertEqual(error, .httpStatus(502, "unavailable")) }
        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 1, "A possibly accepted submission must never be automatically repeated")
        let fields = try formFields(try XCTUnwrap(requests.first))
        XCTAssertEqual(fields["client"], "client+key")
        XCTAssertEqual(fields["user"], "user&token")
        XCTAssertEqual(fields["duration.0"], "237")
        XCTAssertEqual(fields["fingerprint.0"], "AQAB+test")
        XCTAssertEqual(fields["mbid.0"], recording)
        XCTAssertNil(fields["duration"])
    }

    func testInvalidInputAndMetadataAreRejectedWithoutNetwork() async throws {
        let transport = ScenarioTransport(responses: [])
        let client = AcoustIDClient(apiKey: "key", userAgent: "Tests/1.0", transport: transport, minimumRequestInterval: .zero)
        for duration in [Double.nan, .infinity, -1, 0, 1e100] {
            do { _ = try await client.lookup(AudioFingerprint(fingerprint: "AQAB", durationInSeconds: duration)); XCTFail("Expected invalid duration") }
            catch let error as FingerprintError { guard case .invalidInput = error else { return XCTFail("Wrong error") } }
        }
        do { _ = try await client.lookup(AudioFingerprint(fingerprint: "AQAB", durationInSeconds: 180), meta: ["unknown"]); XCTFail("Expected invalid meta") }
        catch let error as FingerprintError { guard case .invalidInput = error else { return XCTFail("Wrong error") } }
        let requests = await transport.requests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testPermanentHTTPAndAPIStatusErrorsAreNotRetried() async throws {
        for response in [
            AcoustIDHTTPResponse(statusCode: 400, data: Data(#"{"error":{"message":"invalid client"}}"#.utf8)),
            AcoustIDHTTPResponse(statusCode: 200, data: Data(#"{"status":"error","error":{"code":4,"message":"invalid client"}}"#.utf8))
        ] {
            let transport = ScenarioTransport(responses: [response])
            let client = AcoustIDClient(apiKey: "key", userAgent: "Tests/1.0", transport: transport, minimumRequestInterval: .zero)
            do { _ = try await client.lookup(AudioFingerprint(fingerprint: "AQAB", durationInSeconds: 180)); XCTFail("Expected service error") }
            catch let error as FingerprintError { XCTAssertTrue(error.localizedDescription.contains("invalid client")) }
            let requests = await transport.requests()
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testTransientLookupCanRetryButCancellationCannot() async throws {
        let transport = ScenarioTransport(responses: [
            AcoustIDHTTPResponse(statusCode: 503, headers: ["Retry-After": "0.001"], data: Data()),
            AcoustIDHTTPResponse(statusCode: 200, data: Data(#"{"status":"ok","results":[]}"#.utf8))
        ])
        let client = AcoustIDClient(apiKey: "key", userAgent: "Tests/1.0", transport: transport, minimumRequestInterval: .zero, rateLimiter: APIRequestRateLimiter())
        _ = try await client.lookup(AudioFingerprint(fingerprint: "AQAB", durationInSeconds: 180))
        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 2)

        let cancelled = ScenarioTransport(responses: [], failure: URLError(.cancelled))
        let other = AcoustIDClient(apiKey: "key", userAgent: "Tests/1.0", transport: cancelled, minimumRequestInterval: .zero)
        do { _ = try await other.lookup(AudioFingerprint(fingerprint: "AQAB", durationInSeconds: 180)); XCTFail("Expected cancellation") }
        catch is CancellationError { }
        let cancelledRequests = await cancelled.requests()
        XCTAssertEqual(cancelledRequests.count, 1)
    }

    private func formFields(_ request: URLRequest) throws -> [String: String] {
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        let items = try XCTUnwrap(URLComponents(string: "https://example.test/?\(body)")?.queryItems)
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    private actor ScenarioTransport: AcoustIDTransport {
        let responses: [AcoustIDHTTPResponse]
        let failure: URLError?
        var recordedRequests: [URLRequest] = []
        init(responses: [AcoustIDHTTPResponse], failure: URLError? = nil) { self.responses = responses; self.failure = failure }
        func data(for request: URLRequest) async throws -> AcoustIDHTTPResponse {
            recordedRequests.append(request)
            if let failure { throw failure }
            return responses[min(recordedRequests.count - 1, responses.count - 1)]
        }
        func requests() -> [URLRequest] { recordedRequests }
    }

    func testSubmissionRequiresConsentAndAuthentication() async throws {
        let client = AcoustIDClient(apiKey: "key", userAgent: "MacPicardTests/1.0", minimumRequestInterval: .zero)
        let submission = AcoustIDSubmission(fingerprint: "AQAB", durationInSeconds: 180, recordingID: "recording-1")

        do {
            try await client.submit(submission, userToken: nil, consentGiven: false)
            XCTFail("Expected consent error")
        } catch let error as FingerprintError {
            XCTAssertEqual(error, .consentRequired)
        }

        do {
            try await client.submit(submission, userToken: nil, consentGiven: true)
            XCTFail("Expected authentication error")
        } catch let error as FingerprintError {
            XCTAssertEqual(error, .authenticationRequired)
        }
    }

    private actor StubTransport: AcoustIDTransport {
        let responseData: Data
        var recordedRequest: URLRequest?

        init(response: Data) { responseData = response }

        func data(for request: URLRequest) async throws -> AcoustIDHTTPResponse {
            recordedRequest = request
            return AcoustIDHTTPResponse(statusCode: 200, data: responseData)
        }

        func request() -> URLRequest { recordedRequest! }
    }
}
