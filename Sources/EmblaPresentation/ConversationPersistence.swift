import Foundation

import EmblaCore

/// Portable chat document; folder permissions and unsent drafts are kept out of cloud content.
public struct ConversationSnapshot: Codable, Sendable, Equatable {
    public var formatVersion = 1
    public var conversationID: UUID
    public var revision = UUID()
    public var projectID: UUID?
    public var messages: [ChatMessage]
    public var compaction: CompactionState

    public init(
        conversationID: UUID, messages: [ChatMessage], compaction: CompactionState,
        projectID: UUID? = nil
    ) {
        self.conversationID = conversationID
        self.messages = messages
        self.compaction = compaction
        self.projectID = projectID
    }

    /// Rejects incompatible/corrupt documents without silently resetting the conversation.
    public func validate() throws {
        guard formatVersion == 1 else { throw ConversationStorageError.unsupportedVersion }
        let boundary = compaction.summarizedMessageCount
        var pendingResults: [UUID] = []
        for message in messages {
            if message.role == .user { pendingResults.removeAll() }
            if message.toolName != nil && message.state == .complete {
                pendingResults.append(message.id)
            }
            if let receipt = message.workerReceipt {
                guard !receipt.resultIDs.isEmpty, receipt.resultIDs == pendingResults,
                    receipt.resultIDs.last == message.id,
                    let encoded = try? ToolJSON.decode(Data(receipt.data.utf8)),
                    (try? encoded.text()) == receipt.data,
                    case .array = encoded,
                    receipt.summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != true
                else { throw ConversationStorageError.invalidDocument }
                pendingResults.removeAll()
            }
        }
        guard boundary >= 0, boundary <= messages.count,
            compaction.summary.isEmpty == (boundary == 0),
            Set(messages.map(\.id)).count == messages.count,
            messages.allSatisfy({ message in
                guard message.role != .system else { return false }
                if let summary = message.toolResultSummary {
                    guard message.role == .assistant, let toolName = message.toolName,
                        !toolName.isEmpty, !message.text.isEmpty,
                        !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    else { return false }
                }
                guard let metrics = message.generationMetrics else { return true }
                return message.role == .assistant && metrics.promptTokens >= 0
                    && metrics.completionTokens >= 0
                    && metrics.promptMilliseconds.isFinite && metrics.promptMilliseconds >= 0
                    && metrics.decodeMilliseconds.isFinite && metrics.decodeMilliseconds >= 0
            }),
            boundary == messages.count || messages[boundary].role == .user
        else { throw ConversationStorageError.invalidDocument }
    }
}

/// One portable library. Selection, drafts, bookmarks and device preferences stay local.
public struct ConversationLibrary: Codable, Sendable, Equatable {
    public var formatVersion = 3
    public var chats: [ConversationSnapshot]
    public var projects: [ChatProject]

    public init(chats: [ConversationSnapshot], projects: [ChatProject] = []) {
        self.chats = chats.sorted { $0.conversationID.uuidString < $1.conversationID.uuidString }
        self.projects = projects.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// The prior single-chat cloud document is an explicit supported migration format.
    public init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: CodingKeys.self)
        let version = try keys.decode(Int.self, forKey: .formatVersion)
        if version == 1 {
            self.init(chats: [try ConversationSnapshot(from: decoder)])
        } else {
            guard version == 2 || version == 3 else {
                throw ConversationStorageError.unsupportedVersion
            }
            self.init(
                chats: try keys.decode([ConversationSnapshot].self, forKey: .chats),
                projects: version == 2
                    ? []
                    : try keys.decode(
                        [ChatProject].self, forKey: .projects))
        }
        try validate()
    }

    public func validate() throws {
        guard formatVersion == 3 else { throw ConversationStorageError.unsupportedVersion }
        guard !chats.isEmpty,
            Set(chats.map(\.conversationID)).count == chats.count
        else { throw ConversationStorageError.invalidDocument }
        let projectIDs = Set(projects.map(\.id))
        guard projectIDs.count == projects.count,
            chats.allSatisfy({ $0.projectID == nil || projectIDs.contains($0.projectID!) })
        else { throw ConversationStorageError.invalidDocument }
        for chat in chats { try chat.validate() }
        for project in projects {
            guard !project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                Set(project.memory.map(\.id)).count == project.memory.count
            else { throw ConversationStorageError.invalidDocument }
            for entry in project.memory {
                guard !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    chats.contains(where: { chat in
                        chat.conversationID == entry.sourceConversationID
                            && chat.messages.contains(where: { $0.id == entry.sourceMessageID })
                    })
                else { throw ConversationStorageError.invalidDocument }
            }
        }
    }
}

/// Local history entry; drafts are deliberately excluded from the portable library.
public struct SavedConversation: Codable, Sendable, Equatable, Identifiable {
    public var snapshot: ConversationSnapshot
    public var draft: String
    public var id: UUID { snapshot.conversationID }
    public var title: String {
        let first = snapshot.messages.first(where: { $0.role == .user })?.text ?? draft
        let line = first.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.trimmingCharacters(in: .whitespaces).isEmpty
            ? "New chat" : String(line.prefix(80))
    }

    public init(snapshot: ConversationSnapshot, draft: String = "") {
        self.snapshot = snapshot
        self.draft = draft
    }
}

/// Device-local envelope. The global cloud setting is off until explicitly enabled.
public struct ConversationArchive: Codable, Sendable, Equatable {
    public var sequence: UInt64
    public var snapshot: ConversationSnapshot
    public var draft = ""
    public var history: [SavedConversation]?
    public var projects: [ChatProject]?
    public var cloudConsentVersion: Int?
    public var cloudEnabled = false
    public var cloudFolderBookmark: Data?
    public var cloudBaseFingerprint: String?

    public init(sequence: UInt64, snapshot: ConversationSnapshot, draft: String = "") {
        self.sequence = sequence
        self.snapshot = snapshot
        self.draft = draft
    }

    public var library: ConversationLibrary {
        ConversationLibrary(
            chats: [snapshot] + (history ?? []).map(\.snapshot), projects: projects ?? [])
    }

    public func validate() throws { try library.validate() }

    /// Interrupted output in any saved chat never resumes generation on restoration.
    public func recoveringInterruptedResponses() -> ConversationArchive {
        var recovered = self
        func interrupt(_ snapshot: inout ConversationSnapshot) {
            guard snapshot.messages.contains(where: { $0.state == .streaming }) else { return }
            for index in snapshot.messages.indices
            where snapshot.messages[index].state == .streaming {
                snapshot.messages[index].state = .interrupted
            }
            snapshot.revision = UUID()
        }
        interrupt(&recovered.snapshot)
        if var entries = recovered.history {
            for index in entries.indices { interrupt(&entries[index].snapshot) }
            recovered.history = entries
        }
        if recovered != self { recovered.sequence += 1 }
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
        try archive.validate()
        lastSequence = archive.sequence
        return archive
    }

    /// Local-only data is excluded from automatic iCloud backup as well as app-managed sync.
    public func save(_ archive: ConversationArchive) throws {
        try archive.validate()
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
