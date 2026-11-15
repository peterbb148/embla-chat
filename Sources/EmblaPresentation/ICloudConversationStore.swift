import CryptoKit
import Foundation

/// A consistent read of the current document and any unresolved iCloud versions.
public struct CloudConversationRead: Sendable, Equatable {
    public var current: ConversationSnapshot?
    public var conflicts: [ConversationSnapshot]
    public var uploaded: Bool

    public init(
        current: ConversationSnapshot? = nil, conflicts: [ConversationSnapshot] = [],
        uploaded: Bool = false
    ) {
        self.current = current
        self.conflicts = conflicts
        self.uploaded = uploaded
    }

    var fingerprints: Set<String> {
        get throws {
            try Set(([current].compactMap { $0 } + conflicts).map { try $0.fingerprint() })
        }
    }
}

/// The production implementation uses only the folder explicitly granted through Files.
public protocol CloudConversationStorage: Sendable {
    func read() async throws -> CloudConversationRead
    func write(
        _ snapshot: ConversationSnapshot, replacing: CloudConversationRead,
        resolvingConflicts: Bool
    ) async throws
}

extension ConversationSnapshot {
    /// Canonical content identity detects edits even if an external editor retains the revision ID.
    func encodedDocument() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    func fingerprint() throws -> String {
        SHA256.hash(data: try encodedDocument()).map { String(format: "%02x", $0) }.joined()
    }
}

/// Coordinates access on a serial actor; a successful write is not treated as upload confirmation.
public actor ICloudConversationStore: CloudConversationStorage {
    private let bookmark: Data

    public init(bookmark: Data) { self.bookmark = bookmark }

    public nonisolated static func bookmark(for folder: URL) throws -> Data {
        guard folder.startAccessingSecurityScopedResource() else {
            throw CloudConversationError.permission
        }
        defer { folder.stopAccessingSecurityScopedResource() }
        try validateFolder(folder)
        #if os(macOS)
            let options: URL.BookmarkCreationOptions = [.withSecurityScope]
        #else
            let options: URL.BookmarkCreationOptions = [.minimalBookmark]
        #endif
        return try folder.bookmarkData(
            options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    public func read() throws -> CloudConversationRead {
        try withAccess { file in try CoordinatedConversationFile.read(at: file) }
    }

    public func write(
        _ snapshot: ConversationSnapshot, replacing: CloudConversationRead,
        resolvingConflicts: Bool = false
    ) throws {
        try withAccess { file in
            try CoordinatedConversationFile.write(
                snapshot, at: file, replacing: replacing, resolvingConflicts: resolvingConflicts)
        }
    }

    private nonisolated static func validateFolder(_ folder: URL) throws {
        let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isUbiquitousItemKey])
        guard folder.lastPathComponent == "EmblaChat", values.isDirectory == true,
            values.isUbiquitousItem == true
        else { throw CloudConversationError.notICloudFolder }
    }

    private func withAccess<T>(_ action: (URL) throws -> T) throws -> T {
        try Task.checkCancellation()
        var stale = false
        #if os(macOS)
            let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
            let options: URL.BookmarkResolutionOptions = []
        #endif
        let folder = try URL(
            resolvingBookmarkData: bookmark, options: options, relativeTo: nil,
            bookmarkDataIsStale: &stale)
        guard !stale, folder.startAccessingSecurityScopedResource() else {
            throw CloudConversationError.permission
        }
        defer { folder.stopAccessingSecurityScopedResource() }
        try Self.validateFolder(folder)
        return try action(folder.appendingPathComponent("ActiveChat.json"))
    }
}

/// Shared file mechanics are tested on temporary files; those tests do not claim iCloud access.
enum CoordinatedConversationFile {
    static func read(at file: URL) throws -> CloudConversationRead {
        var result: Result<CloudConversationRead, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(
            readingItemAt: file, options: [], error: &coordinationError
        ) { coordinated in
            result = Result { try contents(at: coordinated) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CloudConversationError.coordination }
        return try result.get()
    }

    static func write(
        _ snapshot: ConversationSnapshot, at file: URL, replacing expected: CloudConversationRead,
        resolvingConflicts: Bool = false
    ) throws {
        let bytes = try snapshot.encodedDocument()
        var result: Result<Void, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(
            writingItemAt: file, options: .forReplacing, error: &coordinationError
        ) { coordinated in
            result = Result {
                try Task.checkCancellation()
                var versions: [NSFileVersion] = []
                let current = try contents(at: coordinated, versions: &versions)
                guard try current.fingerprints == expected.fingerprints else {
                    throw CloudConversationError.changed
                }
                guard resolvingConflicts || current.conflicts.isEmpty else {
                    throw CloudConversationError.conflict
                }
                try bytes.write(to: coordinated, options: .atomic)
                if resolvingConflicts {
                    for version in versions {
                        version.isResolved = true
                    }
                }
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CloudConversationError.coordination }
        try result.get()
    }

    private static func contents(at file: URL) throws -> CloudConversationRead {
        var versions: [NSFileVersion] = []
        return try contents(at: file, versions: &versions)
    }

    private static func contents(
        at file: URL, versions: inout [NSFileVersion]
    ) throws -> CloudConversationRead {
        try Task.checkCancellation()
        let bytes: Data
        do { bytes = try Data(contentsOf: file) } catch {
            let failure = error as NSError
            if failure.domain == NSCocoaErrorDomain && failure.code == NSFileReadNoSuchFileError {
                return CloudConversationRead()
            }
            throw error
        }
        let decoder = JSONDecoder()
        let snapshot = try decoder.decode(ConversationSnapshot.self, from: bytes)
        try snapshot.validate()
        versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: file) ?? []
        let conflicts = try versions.map { version in
            let snapshot = try decoder.decode(
                ConversationSnapshot.self, from: Data(contentsOf: version.url))
            try snapshot.validate()
            return snapshot
        }
        var fresh = file
        fresh.removeAllCachedResourceValues()
        let values = try fresh.resourceValues(
            forKeys: [.ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey])
        return CloudConversationRead(
            current: snapshot, conflicts: conflicts,
            uploaded: values.ubiquitousItemIsUploaded == true
                && values.ubiquitousItemIsUploading != true)
    }
}

public enum CloudConversationError: Error, LocalizedError, Sendable {
    case permission, notICloudFolder, coordination, changed, conflict, removed, configuration

    public var errorDescription: String? {
        switch self {
        case .configuration: return "Cloud synchronization is not connected to chat persistence."
        case .permission: return "Folder access expired or was revoked. Choose the iCloud folder again."
        case .notICloudFolder: return "Choose the EmblaChat folder in iCloud Drive."
        case .coordination: return "The document provider could not coordinate access to the chat."
        case .changed: return "The iCloud chat changed during synchronization. Refresh to review it."
        case .conflict: return "There are conflicting iCloud versions. Choose which chat to keep."
        case .removed: return "The previously synchronized iCloud chat is missing. Choose the folder again to create it."
        }
    }
}
