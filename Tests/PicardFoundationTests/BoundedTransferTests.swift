import CryptoKit
import Foundation
import XCTest
@testable import PicardFoundation

final class BoundedTransferTests: XCTestCase {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChunkTransferProtocol.self]
        return URLSession(configuration: configuration)
    }
    private func url(_ name: String = "data") -> URL {
        URL(string: "https://github.com/fixture/\(UUID().uuidString)/\(name)")!
    }
    func testChunkedMemoryAndFileTransfersProduceTheSameBytesAndHash() async throws {
        let url = url(), bytes = Data(repeating: 7, count: 1024 * 1024 + 13)
        ChunkTransferProtocol.fixtures.set(url, data: bytes)
        defer { ChunkTransferProtocol.fixtures.remove(url) }
        let session = session(); defer { session.invalidateAndCancel() }
        let result = try await BoundedHTTPTransfer.receive(URLRequest(url: url), session: session, maximumBytes: 2 * 1024 * 1024)
        XCTAssertEqual(result.data, bytes)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("download.zip")
        let written = try await BoundedHTTPTransfer.receive(URLRequest(url: url), session: session, maximumBytes: 2 * 1024 * 1024, file: file)
        XCTAssertTrue(written.data.isEmpty, "File mode must not retain the archive")
        XCTAssertEqual(written.byteCount, Int64(bytes.count)); XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertEqual(written.checksum, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        do { _ = try await BoundedHTTPTransfer.receive(URLRequest(url: url), session: session, maximumBytes: 2 * 1024 * 1024, file: file); XCTFail("Never overwrite an existing file") } catch {}
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
    func testBothAdvertisedAndActualLimitsRejectOversizedResponses() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        for advertised in [nil, 256 * 1024] as [Int?] {
            let url = url()
            ChunkTransferProtocol.fixtures.set(url, data: Data(repeating: 8, count: 256 * 1024), length: advertised)
            defer { ChunkTransferProtocol.fixtures.remove(url) }
            do {
                _ = try await BoundedHTTPTransfer.receive(URLRequest(url: url), session: session, maximumBytes: 128 * 1024)
                XCTFail("Expected bounded rejection")
            } catch let error as BoundedHTTPFailure {
                guard case .oversized = error else { return XCTFail("\(error)") }
            }
        }
    }
    func testCancellingTransferCancelsURLSessionRequest() async throws {
        let url = url(); ChunkTransferProtocol.fixtures.set(url, data: Data(), waiting: true)
        defer { ChunkTransferProtocol.fixtures.remove(url) }
        let session = session(); defer { session.invalidateAndCancel() }
        let task = Task { try await BoundedHTTPTransfer.receive(URLRequest(url: url), session: session, maximumBytes: 1024) }
        for _ in 0..<100 {
            if ChunkTransferProtocol.fixtures.started(url) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must propagate") } catch is CancellationError {}
    }
    func testUpdaterStreamsVerifiedArchiveAndRejectsWrongChecksums() async throws {
        let archiveURL = url("MacPicard.zip"), checksumURL = archiveURL.deletingLastPathComponent().appendingPathComponent("SHA256SUMS")
        let bytes = Data(repeating: 42, count: 2 * 1024 * 1024 + 1)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        ChunkTransferProtocol.fixtures.set(archiveURL, data: bytes)
        ChunkTransferProtocol.fixtures.set(checksumURL, data: Data("\(hash)  MacPicard.zip\n".utf8))
        defer { ChunkTransferProtocol.fixtures.remove(archiveURL); ChunkTransferProtocol.fixtures.remove(checksumURL) }
        let session = session(); defer { session.invalidateAndCancel() }
        let service = AppUpdateService(session: session)
        let release = AppUpdateRelease(id: "test", version: try AppVersion("2.0.0"), name: "Test", notes: "", releaseURL: archiveURL,
            publishedAt: nil, archiveURL: archiveURL, checksumURL: checksumURL, isPrerelease: false)
        let file = try await service.downloadAndVerify(release)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        ChunkTransferProtocol.fixtures.set(checksumURL, data: Data("\(String(repeating: "0", count: 64))  MacPicard.zip\n".utf8))
        do { _ = try await service.downloadAndVerify(release); XCTFail("Wrong checksums must not return a staged archive") }
        catch let error as AppUpdateError { guard case .checksumMismatch = error else { return XCTFail("\(error)") } }
    }
}

private final class TransferFixtures: @unchecked Sendable {
    struct Entry { let data: Data; let length: Int?; let waiting: Bool }
    private let lock = NSLock()
    private var entries: [URL: Entry] = [:]
    private var starts = Set<URL>()
    func set(_ url: URL, data: Data, length: Int? = nil, waiting: Bool = false) {
        lock.lock(); defer { lock.unlock() }; entries[url] = Entry(data: data, length: length, waiting: waiting)
    }
    func remove(_ url: URL) { lock.lock(); defer { lock.unlock() }; entries.removeValue(forKey: url); starts.remove(url) }
    func started(_ url: URL) -> Bool { lock.lock(); defer { lock.unlock() }; return starts.contains(url) }
    func entry(_ url: URL) -> Entry? { lock.lock(); defer { lock.unlock() }; starts.insert(url); return entries[url] }
}
private final class ChunkTransferProtocol: URLProtocol, @unchecked Sendable {
    static let fixtures = TransferFixtures()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let entry = Self.fixtures.entry(url) else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        let headers = entry.length.map { ["Content-Length": String($0)] } ?? [:]
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if entry.waiting { return }
        for offset in stride(from: 0, to: entry.data.count, by: 64 * 1024) {
            client?.urlProtocol(self, didLoad: entry.data.subdata(in: offset..<min(entry.data.count, offset + 64 * 1024)))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
