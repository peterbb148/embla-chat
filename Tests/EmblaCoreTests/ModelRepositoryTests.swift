import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import EmblaCore

private actor TestDownloader: AssetDownloading {
    enum Mode { case normal, corrupt, httpSecond, pauseOnce }
    let data: Data
    let mode: Mode
    private(set) var calls = 0

    init(data: Data, mode: Mode = .normal) { self.data = data; self.mode = mode }

    func download(
        from url: URL, progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> DownloadedAsset {
        calls += 1
        if mode == .pauseOnce && calls == 1 { try await Task.sleep(for: .seconds(60)) }
        let output = mode == .corrupt ? Data(repeating: 0, count: data.count) : data
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try output.write(to: file)
        progress(Int64(output.count))
        return DownloadedAsset(url: file, statusCode: mode == .httpSecond && calls == 2 ? 503 : 200)
    }

    func waitForStart() async {
        while calls == 0 { await Task.yield() }
    }
}

private struct Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let data = Data("test model file".utf8)
    var manifest: ModelManifest {
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return ModelManifest(
            repository: "test/model", revision: "pinned-test-revision",
            files: [
                "config.json", "tokenizer.json", "model.safetensors", "engram_table.safetensors",
            ].map {
                ModelManifest.Asset(path: $0, sizeBytes: Int64(data.count), sha256: sha)
            }
        )
    }
    func repository(_ downloader: TestDownloader) -> ModelRepository {
        ModelRepository(
            root: root, manifest: manifest, downloader: downloader, capacity: { _ in Int64.max })
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}

@Test func completeInstallationVerifiesAgainAfterRelaunchAndCanBeDeleted() async throws {
    let f = Fixture(); defer { f.clean() }
    let downloader = TestDownloader(data: f.data)
    let repository = f.repository(downloader)
    let before = try await repository.installedDirectory()
    #expect(before == nil)
    let directory = try await repository.install { _ in }
    #expect(directory.lastPathComponent == f.manifest.revision)
    let restored = try await f.repository(downloader).installedDirectory()
    #expect(restored == directory)
    let stored = try await repository.storedBytes()
    #expect(stored == f.manifest.totalBytes)
    let excluded = try f.root.resourceValues(forKeys: [.isExcludedFromBackupKey])
    #expect(excluded.isExcludedFromBackup == true)
    try await repository.delete()
    let removed = try await repository.installedDirectory()
    let remaining = try await repository.storedBytes()
    #expect(removed == nil)
    #expect(remaining == 0)
}

@Test func sameSizeCorruptionNeverBecomesReady() async throws {
    let f = Fixture(); defer { f.clean() }
    let repository = f.repository(TestDownloader(data: f.data, mode: .corrupt))
    await #expect(throws: ModelStorageError.invalidAsset("config.json")) {
        try await repository.install { _ in }
    }
    let ready = try await repository.installedDirectory()
    #expect(ready == nil)
}

/// Verifies the final partial chunk as well as a complete hashing buffer.
@Test func verificationSpansMultipleChunks() async throws {
    let f = Fixture(); defer { f.clean() }
    var data = Data(repeating: 17, count: 8 * 1_024 * 1_024)
    data.append(Data("final partial chunk".utf8))
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let manifest = ModelManifest(
        repository: "test/model", revision: "chunked-test",
        files: [
            ModelManifest.Asset(
                path: "model.safetensors", sizeBytes: Int64(data.count), sha256: digest)
        ])
    let repository = ModelRepository(
        root: f.root, manifest: manifest, downloader: TestDownloader(data: data),
        capacity: { _ in Int64.max })
    let installed = try await repository.install { _ in }
    #expect(try await repository.installedDirectory() == installed)
}

@Test func corruptInstalledBytesAreRejectedOnRelaunch() async throws {
    let f = Fixture(); defer { f.clean() }
    let repository = f.repository(TestDownloader(data: f.data))
    let directory = try await repository.install { _ in }
    try Data(repeating: 0, count: f.data.count).write(
        to: directory.appendingPathComponent("config.json"))
    await #expect(throws: ModelStorageError.invalidAsset("config.json")) {
        try await repository.installedDirectory()
    }
}

@Test func failedDownloadCanBeRetriedWithoutPublishingPartialFiles() async throws {
    let f = Fixture(); defer { f.clean() }
    let repository = f.repository(TestDownloader(data: f.data, mode: .httpSecond))
    await #expect(throws: ModelStorageError.httpStatus(503)) {
        try await repository.install { _ in }
    }
    let failed = try await repository.installedDirectory()
    #expect(failed == nil)
    let partialBytes = try await repository.storedBytes()
    #expect(partialBytes == Int64(f.data.count))
    _ = try await repository.install { _ in }
    let ready = try await repository.installedDirectory()
    #expect(ready != nil)
}

@Test func cancellationPreventsPublicationAndSubsequentRetryWorks() async throws {
    let f = Fixture(); defer { f.clean() }
    let downloader = TestDownloader(data: f.data, mode: .pauseOnce)
    let repository = f.repository(downloader)
    let task = Task { try await repository.install { _ in } }
    await downloader.waitForStart()
    await #expect(throws: ModelStorageError.busy) { try await repository.delete() }
    task.cancel()
    do {
        _ = try await task.value; Issue.record("Cancelled download unexpectedly completed")
    } catch is CancellationError {}
    let cancelled = try await repository.installedDirectory()
    #expect(cancelled == nil)
    _ = try await repository.install { _ in }
    let ready = try await repository.installedDirectory()
    #expect(ready != nil)
}

@Test func insufficientStorageFailsBeforeNetworkAccess() async throws {
    let f = Fixture(); defer { f.clean() }
    let downloader = TestDownloader(data: f.data)
    let repository = ModelRepository(
        root: f.root, manifest: f.manifest, downloader: downloader, capacity: { _ in 0 }
    )
    await #expect(
        throws: ModelStorageError.insufficientStorage(required: f.manifest.totalBytes, available: 0)
    ) {
        try await repository.install { _ in }
    }
    let calls = await downloader.calls
    #expect(calls == 0)
}

/// Cancellation before registration must resume the waiter without starting network work.
@Test
func cancelledHTTPDownload() async throws {
    let transfer = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await HTTPAssetDownloader(network: .init(initialState: .satisfied)).download(
            from: URL(string: "https://unused.invalid/model")!, progress: { _ in })
    }
    await #expect(throws: CancellationError.self) { try await transfer.value }
}

/// Optional provider check uses only the pinned 5 KB config; no model weights are fetched.
@Test(.enabled(if: ProcessInfo.processInfo.environment["EMBLA_LIVE_DOWNLOAD_TESTS"] == "1"))
func livePinnedConfigDownload() async throws {
    let bundled = try ModelManifest.bundled()
    let config = try #require(bundled.files.first { $0.path == "config.json" })
    let received = Mutex<Int64>(0)
    let asset = try await HTTPAssetDownloader(network: .init(initialState: .satisfied)).download(
        from: bundled.url(for: config)
    ) { bytes in
        received.withLock { $0 = max($0, bytes) }
    }
    defer { try? FileManager.default.removeItem(at: asset.url) }
    #expect(asset.statusCode == 200)
    #expect(received.withLock { $0 } == config.sizeBytes)
    let manifest = ModelManifest(
        repository: bundled.repository, revision: bundled.revision, files: [config])
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = ModelRepository(
        root: root, manifest: manifest,
        downloader: HTTPAssetDownloader(network: .init(initialState: .satisfied)),
        capacity: { _ in Int64.max })
    let directory = try await repository.install { _ in }
    let ready = try await repository.installedDirectory()
    #expect(ready == directory)
}
