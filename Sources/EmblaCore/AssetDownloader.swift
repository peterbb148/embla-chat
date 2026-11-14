import Foundation
import Synchronization

public struct DownloadedAsset: Sendable {
    public let url: URL
    public let statusCode: Int

    public init(url: URL, statusCode: Int) {
        self.url = url
        self.statusCode = statusCode
    }
}

/// Transport boundary used for deterministic tests without downloading the model.
public protocol AssetDownloading: Sendable {
    func download(
        from url: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> DownloadedAsset
}

public struct HTTPAssetDownloader: AssetDownloading {
    public init() {}

    public func download(
        from url: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> DownloadedAsset {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3_600
        let delegate = DownloadProgress(report: progress)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.start(session.downloadTask(with: url), continuation: continuation)
            }
        } onCancel: {
            delegate.cancel()
        }
    }
}

/// Session download delegate; immutable state is safe on URLSession's callback queue.
private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, Sendable {
    private struct State {
        var task: URLSessionDownloadTask?
        var continuation: CheckedContinuation<DownloadedAsset, any Error>?
        var cancelled = false
    }

    let report: @Sendable (Int64) -> Void
    private let state = Mutex(State())

    init(report: @escaping @Sendable (Int64) -> Void) { self.report = report }

    /// Starts a delegate-based task; async download convenience methods omit byte callbacks.
    func start(
        _ task: URLSessionDownloadTask,
        continuation: CheckedContinuation<DownloadedAsset, any Error>
    ) {
        let cancelled = state.withLock { state in
            guard !state.cancelled else { return true }
            state.task = task
            state.continuation = continuation
            return false
        }
        if cancelled {
            continuation.resume(throwing: CancellationError())
        } else {
            task.resume()
        }
    }

    /// Cancels the network task, including cancellation before it has been registered.
    func cancel() {
        let task = state.withLock { state in
            state.cancelled = true
            return state.task
        }
        task?.cancel()
    }

    private func finish(_ result: Result<DownloadedAsset, any Error>) {
        let continuation = state.withLock { state in
            let continuation = state.continuation
            state.continuation = nil
            state.task = nil
            return continuation
        }
        continuation?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        report(totalBytesWritten)
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // URLSession removes its temporary file when this callback returns.
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(DownloadedAsset(
                url: destination,
                statusCode: (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0)))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
    ) {
        if let error { finish(.failure(error)) }
    }
}
