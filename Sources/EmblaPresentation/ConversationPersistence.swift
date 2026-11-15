import Foundation

import EmblaCore

/// Portable chat document; folder permissions and unsent drafts are kept out of cloud content.
public struct ConversationSnapshot: Codable, Sendable, Equatable {
    public var formatVersion = 1
    public var conversationID: UUID
    public var revision = UUID()
    public var messages: [ChatMessage]
    public var compaction: CompactionState

    public init(
        conversationID: UUID, messages: [ChatMessage], compaction: CompactionState
    ) {
        self.conversationID = conversationID
        self.messages = messages
        self.compaction = compaction
    }

    /// Rejects incompatible/corrupt documents without silently resetting the conversation.
    public func validate() throws {
        guard formatVersion == 1 else { throw ConversationStorageError.unsupportedVersion }
        let boundary = compaction.summarizedMessageCount
        guard boundary >= 0, boundary <= messages.count,
            compaction.summary.isEmpty == (boundary == 0),
            Set(messages.map(\.id)).count == messages.count,
            messages.allSatisfy({ $0.role != .system }),
            boundary == messages.count || messages[boundary].role == .user
        else { throw ConversationStorageError.invalidDocument }
    }
}

/// Device-local envelope. The global cloud setting is off until explicitly enabled.
public struct ConversationArchive: Codable, Sendable, Equatable {
    public var sequence: UInt64
    public var snapshot: ConversationSnapshot
    public var draft = ""
    public var cloudEnabled = false
    public var cloudFolderBookmark: Data?
    public var cloudBaseFingerprint: String?

    public init(sequence: UInt64, snapshot: ConversationSnapshot, draft: String = "") {
        self.sequence = sequence
        self.snapshot = snapshot
        self.draft = draft
    }

    /// A restored streaming turn is interrupted; loading never restarts generation.
    public func recoveringInterruptedResponses() -> ConversationArchive {
        guard snapshot.messages.contains(where: { $0.state == .streaming }) else { return self }
        var recovered = self
        for index in recovered.snapshot.messages.indices {
            if recovered.snapshot.messages[index].state == .streaming {
                recovered.snapshot.messages[index].state = .interrupted
            }
        }
        recovered.snapshot.revision = UUID()
        recovered.sequence += 1
        return recovered
    }
}

/// An async storage boundary allows deterministic tests of writes that overlap lifecycle changes.
protocol ConversationStoring: Sendable {
    func load() async throws -> ConversationArchive?
    func save(_ archive: ConversationArchive) async throws
}

/// Serial, atomic local storage. Revision order prevents delayed writes resurrecting old chats.
public actor ConversationStore: ConversationStoring {
    public let root: URL
    private var lastSequence: UInt64?
    private var file: URL { root.appendingPathComponent("active-chat.json") }

    public init(root: URL) { self.root = root }

    public static func defaultRoot() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("EmblaChat/Conversation", isDirectory: true)
    }

    /// Missing storage is a first launch; malformed or inaccessible storage remains an error.
    public func load() throws -> ConversationArchive? {
        let bytes: Data
        do { bytes = try Data(contentsOf: file) } catch {
            let failure = error as NSError
            if failure.domain == NSCocoaErrorDomain && failure.code == NSFileReadNoSuchFileError {
                return nil
            }
            throw error
        }
        let archive = try JSONDecoder().decode(ConversationArchive.self, from: bytes)
        try archive.snapshot.validate()
        lastSequence = archive.sequence
        return archive
    }

    /// Local-only data is excluded from automatic iCloud backup as well as app-managed sync.
    public func save(_ archive: ConversationArchive) throws {
        try archive.snapshot.validate()
        if let lastSequence, archive.sequence <= lastSequence {
            throw ConversationStorageError.staleWrite
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var directory = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(archive)
        #if os(iOS)
            let options: Data.WritingOptions = [
                .atomic, .completeFileProtectionUntilFirstUserAuthentication,
            ]
            try bytes.write(to: file, options: options)
        #else
            try bytes.write(to: file, options: .atomic)
        #endif
        lastSequence = archive.sequence
    }
}

public enum ConversationStorageError: Error, LocalizedError, Sendable {
    case unsupportedVersion, invalidDocument, staleWrite

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion: return "This chat document uses an unsupported format version."
        case .invalidDocument: return "The saved chat or summary boundary is invalid."
        case .staleWrite: return "An outdated chat save was rejected; newer saved data was kept."
        }
    }
}
