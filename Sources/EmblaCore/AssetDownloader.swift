import Foundation

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
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let delegate = DownloadProgress(report: progress)
        let (file, response) = try await session.download(from: url, delegate: delegate)
        return DownloadedAsset(
            url: file, statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0
        )
    }
}

/// Per-task delegate; immutable state can safely be called from URLSession's queue.
private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, Sendable {
    let report: @Sendable (Int64) -> Void

    init(report: @escaping @Sendable (Int64) -> Void) { self.report = report }

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
    ) {}
}
