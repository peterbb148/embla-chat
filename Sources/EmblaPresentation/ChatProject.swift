import Foundation

/// A user-retained note. Editing its text keeps the original source attribution.
public struct ProjectMemoryEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var text: String
    public let sourceConversationID: UUID
    public let sourceMessageID: UUID

    public init(
        id: UUID = UUID(), text: String, sourceConversationID: UUID, sourceMessageID: UUID
    ) {
        self.id = id
        self.text = text
        self.sourceConversationID = sourceConversationID
        self.sourceMessageID = sourceMessageID
    }
}

/// Memory is changed only by explicit user actions, never by background model extraction.
public struct ChatProject: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var memory: [ProjectMemoryEntry]

    public init(id: UUID = UUID(), name: String, memory: [ProjectMemoryEntry] = []) {
        self.id = id
        self.name = name
        self.memory = memory
    }

    /// Encode notes as data, separate from the rolling chat summary and chat instructions.
    func contextText() throws -> String {
        guard !memory.isEmpty else { return "" }
        struct Notes: Encodable {
            let project: String
            let notes: [String]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(
            decoding: try encoder.encode(Notes(project: name, notes: memory.map(\.text))),
            as: UTF8.self)
    }
}

public enum ProjectError: Error, LocalizedError, Sendable {
    case emptyName, emptyMemory, missingProject, missingSource, busy

    public var errorDescription: String? {
        switch self {
        case .emptyName: return "Enter a project name."
        case .emptyMemory: return "Enter the text you want to keep in project memory."
        case .missingProject: return "This project is no longer available."
        case .missingSource: return "The source message is no longer available in this project."
        case .busy: return "Wait for the current operation to finish before editing projects."
        }
    }
}
