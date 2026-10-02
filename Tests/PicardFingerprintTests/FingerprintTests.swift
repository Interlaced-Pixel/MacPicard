import Foundation
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
        XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "duration" })?.value, "184")
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
