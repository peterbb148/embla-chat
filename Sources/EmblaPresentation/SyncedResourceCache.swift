import CryptoKit
import Foundation

/// Device-private snapshots of successfully read cloud data, isolated by the durable folder grant.
struct SyncedResourceCache: Sendable {
    let root: URL

    func read(_ name: String, bookmark: Data) throws -> Data {
        let file = location(name, bookmark: bookmark)
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw SyncedResourceFailure.notCached
        }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 33_554_432 else { throw SyncedResourceFailure.invalid }
        let data = try Data(contentsOf: file)
        guard data.count <= 33_554_432 else { throw SyncedResourceFailure.invalid }
        return data
    }

    func write(_ data: Data, name: String, bookmark: Data) throws {
        guard data.count <= 33_554_432 else { throw SyncedResourceFailure.invalid }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var directory = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        let file = location(name, bookmark: bookmark)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }

    /// Only generated snapshots are removed; the user's cloud files are never touched.
    func remove(_ name: String, bookmark: Data) throws {
        let file = location(name, bookmark: bookmark)
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }

    private func location(_ name: String, bookmark: Data) -> URL {
        func digest(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return root.appendingPathComponent(digest(bookmark), isDirectory: true)
            .appendingPathComponent(digest(Data(name.utf8)))
    }
}

enum SyncedResourceFailure: Error, LocalizedError {
    case notCached, invalid

    var errorDescription: String? {
        switch self {
        case .notCached:
            "This content has not been saved on this device. Reconnect and reload it first."
        case .invalid: "The saved offline copy is invalid. Reconnect and reload it."
        }
    }
}
