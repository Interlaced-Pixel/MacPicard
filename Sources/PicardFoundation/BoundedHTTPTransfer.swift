import CryptoKit
import Darwin
import Foundation

public struct BoundedHTTPResult: Sendable {
    public let response: HTTPURLResponse
    public let data: Data
    public let checksum: String?
    public let byteCount: Int64
}

public enum BoundedHTTPFailure: Error, LocalizedError, Sendable {
    case oversized(Int)
    case invalidResponse
    case status(Int)
    public var errorDescription: String? {
        switch self {
        case let .oversized(limit): "The response exceeds the \(limit)-byte limit."
        case .invalidResponse: "The server returned a non-HTTP response."
        case let .status(code): "The server returned HTTP \(code)."
        }
    }
}

/// URLSession delivers Data chunks on its delegate queue, not individual bytes
/// on the calling actor. File mode hashes/writes each chunk without retaining
/// the archive. Both modes enforce advertised AND actual response limits.
public enum BoundedHTTPTransfer {
    public static func receive(_ request: URLRequest, session: URLSession = .shared,
        maximumBytes: Int, file: URL? = nil, requireSuccess: Bool = false,
        redirect: @escaping @Sendable (URLRequest) -> URLRequest? = { request in
            guard let url = request.url, APIRequestPolicy.isSecure(url) else { return nil }; return request
        }, progress: @escaping @Sendable (Int64, Int64?) -> Void = { _, _ in }) async throws -> BoundedHTTPResult {
        try Task.checkCancellation()
        let receiver = try Receiver(configuration: session.configuration, maximumBytes: maximumBytes,
            file: file, requireSuccess: requireSuccess, redirect: redirect, progress: progress)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { receiver.start(request, continuation: $0) }
        } onCancel: { receiver.cancel() }
    }

    private final class Receiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private let configuration: URLSessionConfiguration
        private let maximumBytes: Int
        private let fileHandle: FileHandle?
        private let requireSuccess: Bool
        private let redirect: @Sendable (URLRequest) -> URLRequest?
        private let progress: @Sendable (Int64, Int64?) -> Void
        private var session: URLSession?
        private var task: URLSessionDataTask?
        private var continuation: CheckedContinuation<BoundedHTTPResult, Error>?
        private var response: HTTPURLResponse?
        private var data = Data()
        private var digest = SHA256()
        private var received: Int64 = 0
        private var reported: Int64 = 0
        private var expected: Int64?
        private var failure: (any Error)?
        private var cancelled = false

        init(configuration: URLSessionConfiguration, maximumBytes: Int, file: URL?, requireSuccess: Bool,
             redirect: @escaping @Sendable (URLRequest) -> URLRequest?, progress: @escaping @Sendable (Int64, Int64?) -> Void) throws {
            self.configuration = configuration; self.maximumBytes = maximumBytes
            self.requireSuccess = requireSuccess; self.redirect = redirect; self.progress = progress
            if let file {
                let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
                guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
                fileHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            } else { fileHandle = nil }
            super.init()
        }
        func start(_ request: URLRequest, continuation: CheckedContinuation<BoundedHTTPResult, Error>) {
            lock.lock(); defer { lock.unlock() }
            if cancelled { try? fileHandle?.close(); continuation.resume(throwing: CancellationError()); return }
            self.continuation = continuation
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session
            task = session.dataTask(with: request); task?.resume()
        }
        func cancel() {
            lock.lock(); cancelled = true; let task = task; lock.unlock()
            task?.cancel()
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            lock.lock(); defer { lock.unlock() }
            guard let http = response as? HTTPURLResponse else { failure = BoundedHTTPFailure.invalidResponse; completionHandler(.cancel); return }
            guard response.expectedContentLength <= Int64(maximumBytes) else { failure = BoundedHTTPFailure.oversized(maximumBytes); completionHandler(.cancel); return }
            if requireSuccess, !(200..<300).contains(http.statusCode) { failure = BoundedHTTPFailure.status(http.statusCode); completionHandler(.cancel); return }
            self.response = http
            expected = response.expectedContentLength >= 0 ? response.expectedContentLength : nil
            if fileHandle == nil, let expected { data.reserveCapacity(Int(expected)) }
            completionHandler(.allow)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            guard failure == nil else { return }
            guard Int64(chunk.count) <= Int64(maximumBytes) - received else {
                failure = BoundedHTTPFailure.oversized(maximumBytes); dataTask.cancel(); return
            }
            do {
                if let fileHandle { try fileHandle.write(contentsOf: chunk); digest.update(data: chunk) }
                else { data.append(chunk) }
                received += Int64(chunk.count)
                if received - reported >= 256 * 1024 { reported = received; progress(received, expected) }
            } catch { failure = error; dataTask.cancel() }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            lock.lock()
            let continuation = continuation; self.continuation = nil
            var result: Result<BoundedHTTPResult, Error>
            if cancelled { result = .failure(CancellationError()) }
            else if let error = failure ?? error { result = .failure(error) }
            else if let response {
                do {
                    try fileHandle?.synchronize()
                    let checksum = fileHandle == nil ? nil : digest.finalize().map { String(format: "%02x", $0) }.joined()
                    result = .success(BoundedHTTPResult(response: response, data: data, checksum: checksum, byteCount: received))
                    progress(received, expected ?? received)
                } catch { result = .failure(error) }
            } else { result = .failure(BoundedHTTPFailure.invalidResponse) }
            try? fileHandle?.close()
            self.task = nil; self.session = nil
            lock.unlock()
            session.finishTasksAndInvalidate()
            continuation?.resume(with: result)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(redirect(request))
        }
    }
}
