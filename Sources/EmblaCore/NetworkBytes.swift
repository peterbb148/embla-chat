import Foundation
import Synchronization

/// Bounded streaming transport. Task admission/resume is atomic with the shared network gate.
struct NetworkBytes: AsyncSequence, Sendable {
    typealias Element = UInt8
    let chunks: AsyncThrowingStream<Data, any Error>
    let task: NetworkByteRequest

    struct AsyncIterator: AsyncIteratorProtocol {
        var chunks: AsyncThrowingStream<Data, any Error>.Iterator
        let request: NetworkByteRequest
        var chunk = Data()
        var offset = 0

        mutating func next() async throws -> UInt8? {
            try Task.checkCancellation()
            while offset == chunk.count {
                try request.check()
                let next = try await chunks.next()
                try request.check()
                guard let next else { return nil }
                chunk = next
                offset = 0
            }
            let byte = chunk[chunk.startIndex + offset]
            offset += 1
            return byte
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(chunks: chunks.makeAsyncIterator(), request: task)
    }
}

final class NetworkByteRequest: NSObject, URLSessionDataDelegate, Sendable {
    private struct State {
        var task: URLSessionDataTask?
        var session: URLSession?
        var lease: NetworkRequestLease?
        var header: CheckedContinuation<(NetworkBytes, URLResponse), any Error>?
        var cancelled = false
        var headerDelivered = false
        var finished = false
        var count = 0
    }

    private let state = Mutex(State())
    private let access: NetworkAccess
    private let limit: Int
    private let overflow: any Error & Sendable
    private let chunks: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation

    init(access: NetworkAccess, limit: Int, overflow: any Error & Sendable) {
        self.access = access
        self.limit = limit
        self.overflow = overflow
        let pair = AsyncThrowingStream<Data, any Error>.makeStream()
        chunks = pair.stream
        continuation = pair.continuation
        super.init()
    }

    func response(
        for request: URLRequest, configuration: URLSessionConfiguration
    ) async throws -> (NetworkBytes, URLResponse) {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try access.check()
            return try await withCheckedThrowingContinuation { header in
                let session = URLSession(
                    configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.dataTask(with: request)
                state.withLock {
                    $0.header = header
                    $0.task = task
                    $0.session = session
                }
                do {
                    try access.start(task) { lease in
                        try state.withLock {
                            guard !$0.cancelled else { throw CancellationError() }
                            $0.lease = lease
                        }
                    }
                } catch {
                    finish(error)
                    session.invalidateAndCancel()
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    /// Called by the parser's defer, including early completion of a request-scoped SSE reply.
    func cancel() {
        let current = state.withLock { value in
            value.cancelled = true
            return (value.task, value.lease, value.session)
        }
        current.0?.cancel()
        current.2?.invalidateAndCancel()
        if let lease = current.1 { access.finish(lease) }
    }

    func check() throws {
        if let lease = state.withLock({ $0.lease }) { try lease.check() }
        try Task.checkCancellation()
    }

    private func finish(_ error: (any Error)? = nil) {
        let pending = state.withLock {
            value -> (
                CheckedContinuation<(NetworkBytes, URLResponse), any Error>?, NetworkRequestLease?,
                Bool
            )? in
            guard !value.finished else { return nil }
            value.finished = true
            let header = value.header
            value.header = nil
            return (header, value.lease, value.headerDelivered)
        }
        guard let (header, lease, delivered) = pending else { return }
        var failure = error
        do { try lease?.check() } catch { failure = error }
        if let header {
            header.resume(throwing: failure ?? URLError(.badServerResponse))
        }
        if let failure { continuation.finish(throwing: failure) } else { continuation.finish() }
        // Once headers were delivered, the parser retains admission until its defer closes it.
        if !delivered, let lease { access.finish(lease) }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        do { try check() } catch {
            finish(error)
            completionHandler(.cancel)
            return
        }
        let header = state.withLock { value in
            let pending = value.header
            value.header = nil
            value.headerDelivered = pending != nil
            return pending
        }
        header?.resume(returning: (NetworkBytes(chunks: chunks, task: self), response))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try check()
            let fits = state.withLock { value in
                guard !value.finished, data.count <= limit - value.count else { return false }
                value.count += data.count
                return true
            }
            guard fits else { throw overflow }
            continuation.yield(data)
        } catch {
            finish(error)
            dataTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
    ) {
        finish(error)
        session.finishTasksAndInvalidate()
    }

    /// Preserve the clients' no-redirect rule, including credential-bearing requests.
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) { completionHandler(nil) }
}
