import CryptoKit
import Foundation

/// Owns model files. Only fully verified directories are exposed to inference.
public actor ModelRepository {
    private let root: URL
    private let manifest: ModelManifest
    private let downloader: any AssetDownloading
    private let capacity: @Sendable (URL) throws -> Int64
    private var installing = false
    private var destination: URL { root.appendingPathComponent(manifest.revision) }
    private var staging: URL { root.appendingPathComponent("staging") }

    public init(
        root: URL, manifest: ModelManifest,
        downloader: any AssetDownloading = HTTPAssetDownloader(),
        capacity: @escaping @Sendable (URL) throws -> Int64 = ModelRepository.freeCapacity
    ) {
        self.root = root
        self.manifest = manifest
        self.downloader = downloader
        self.capacity = capacity
    }

    public static func defaultRoot() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("EmblaModels", isDirectory: true)
    }

    public static func freeCapacity(at url: URL) throws -> Int64 {
        guard
            let value = try url.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            ).volumeAvailableCapacityForImportantUsage
        else {
            throw ModelStorageError.capacityUnavailable
        }
        return value
    }

    /// Validates saved bytes on every readiness check, including after relaunch.
    public func installedDirectory() throws -> URL? {
        guard !installing else { throw ModelStorageError.busy }
        guard FileManager.default.fileExists(atPath: destination.path) else { return nil }
        try verify(directory: destination)
        return destination
    }

    /// Downloads to staging and atomically publishes only after every asset verifies.
    public func install(progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        guard !installing else { throw ModelStorageError.busy }
        installing = true
        defer { installing = false }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var excludedRoot = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excludedRoot.setResourceValues(values)
        if fm.fileExists(atPath: destination.path) {
            try verify(directory: destination)
            return destination
        }
        // Explicit retry starts over; it never accepts unverified partial downloads.
        if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }
        let available = try capacity(root)
        guard available >= manifest.totalBytes else {
            throw ModelStorageError.insufficientStorage(
                required: manifest.totalBytes, available: available
            )
        }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        var completed: Int64 = 0
        for asset in manifest.files {
            try Task.checkCancellation()
            let base = completed
            let result = try await downloader.download(from: manifest.url(for: asset)) { bytes in
                progress(base + min(max(0, bytes), asset.sizeBytes))
            }
            defer { try? fm.removeItem(at: result.url) }
            try Task.checkCancellation()
            guard result.statusCode == 200 else {
                throw ModelStorageError.httpStatus(result.statusCode)
            }
            try verify(file: result.url, asset: asset)
            try fm.moveItem(at: result.url, to: staging.appendingPathComponent(asset.path))
            completed += asset.sizeBytes
            progress(completed)
        }
        try Task.checkCancellation()
        try fm.moveItem(at: staging, to: destination)
        return destination
    }

    /// Model deletion never touches conversation storage.
    public func delete() throws {
        guard !installing else { throw ModelStorageError.busy }
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    /// Includes partial staging bytes so interrupted downloads remain visible in storage usage.
    public func storedBytes() throws -> Int64 {
        func count(_ url: URL) throws -> Int64 {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values.isDirectory == true {
                return try FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]
                ).reduce(0) { try $0 + count($1) }
            }
            guard let size = values.fileSize else { throw CocoaError(.fileReadUnknown) }
            return Int64(size)
        }
        guard FileManager.default.fileExists(atPath: root.path) else { return 0 }
        return try count(root)
    }

    private func verify(directory: URL) throws {
        for asset in manifest.files {
            try verify(file: directory.appendingPathComponent(asset.path), asset: asset)
        }
    }

    private func verify(file: URL, asset: ModelManifest.Asset) throws {
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: file.path),
            try file.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init)
                == asset.sizeBytes
        else {
            throw ModelStorageError.invalidAsset(asset.path)
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 8 * 1_024 * 1_024), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == asset.sha256 else { throw ModelStorageError.invalidAsset(asset.path) }
    }
}
