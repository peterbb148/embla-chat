import Foundation

/// Human-editable prompts and portable skill references; immediate sending is explicit opt-in.
public struct QuickAction: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case prompt, skill }
    public let id: String
    public let label: String
    public let order: Int
    public let enabled: Bool
    public let type: Kind
    public let prompt: String?
    public let skill: String?
    public let autoSend: Bool

    public init(
        id: String, label: String, order: Int, enabled: Bool = true,
        type: Kind = .prompt, prompt: String? = nil, skill: String? = nil, autoSend: Bool = false
    ) {
        self.id = id
        self.label = label
        self.order = order
        self.enabled = enabled
        self.type = type
        self.prompt = prompt
        self.skill = skill
        self.autoSend = autoSend
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, order, enabled, type, prompt, skill, autoSend
    }

    /// Older files keep draft-only behavior; a supplied flag must be a Boolean.
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decode(String.self, forKey: .id)
        label = try fields.decode(String.self, forKey: .label)
        order = try fields.decode(Int.self, forKey: .order)
        enabled = try fields.decode(Bool.self, forKey: .enabled)
        type = try fields.decode(Kind.self, forKey: .type)
        prompt = try fields.decodeIfPresent(String.self, forKey: .prompt)
        skill = try fields.decodeIfPresent(String.self, forKey: .skill)
        autoSend =
            fields.contains(.autoSend) ? try fields.decode(Bool.self, forKey: .autoSend) : false
    }
}

/// Replacement consent belongs to one exact action, chat, transcript and unchanged draft.
public struct QuickActionReplacement: Sendable, Equatable {
    public let action: QuickAction
    public let conversationID: UUID
    public let messageIDs: [UUID]
    public let draft: String
}

public enum QuickActionApplication: Sendable, Equatable {
    case applied
    case needsConfirmation(QuickActionReplacement)
}

public struct QuickActionConfiguration: Codable, Sendable, Equatable {
    public var formatVersion = 1
    public var actions: [QuickAction]

    public init(actions: [QuickAction]) { self.actions = actions }

    public var visibleActions: [QuickAction] {
        actions.enumerated().filter { $0.element.enabled }.sorted {
            $0.element.order == $1.element.order
                ? $0.offset < $1.offset : $0.element.order < $1.element.order
        }.map(\.element)
    }

    public func validate() throws {
        guard formatVersion == 1 else { throw QuickActionError.unsupportedVersion }
        var seen = Set<String>()
        for action in actions {
            guard !action.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw QuickActionError.invalidAction("An action has an empty id.")
            }
            guard seen.insert(action.id).inserted else {
                throw QuickActionError.duplicateID(action.id)
            }
            guard !action.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw QuickActionError.invalidAction("Action '\(action.id)' needs a label.")
            }
            if action.autoSend {
                guard let prompt = action.prompt,
                    !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    throw QuickActionError.invalidAction(
                        "Immediate-send action '\(action.id)' needs a nonempty configured prompt.")
                }
            }
            let content = action.type == .prompt ? action.prompt : action.skill
            guard let content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw QuickActionError.invalidAction(
                    "Action '\(action.id)' needs a nonempty '\(action.type.rawValue)' field.")
            }
        }
    }

    public static func decode(_ data: Data) throws -> QuickActionConfiguration {
        do {
            let configuration = try JSONDecoder().decode(Self.self, from: data)
            try configuration.validate()
            return configuration
        } catch let error as DecodingError {
            let context: DecodingError.Context
            let reason: String
            switch error {
            case .keyNotFound(let key, let detail):
                context = detail
                reason = "Missing field '\(key.stringValue)'."
            case .typeMismatch(_, let detail), .valueNotFound(_, let detail),
                .dataCorrupted(let detail):
                context = detail
                reason = detail.debugDescription
            @unknown default: throw error
            }
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            throw QuickActionError.invalidAction(
                "actions.json \(path.isEmpty ? "" : "at " + path + ": ")\(reason)")
        }
    }

    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Installed once on-device, not substituted when a selected configuration fails.
    public static let starter = QuickActionConfiguration(actions: [
        QuickAction(
            id: "draft-email", label: "Draft an email", order: 10,
            prompt: "Help me draft an email. Ask who it is for and what I want to say."),
        QuickAction(
            id: "translate", label: "Translate text", order: 20,
            prompt: "Help me translate some text. Ask for the text and target language."),
        QuickAction(
            id: "summarize", label: "Summarize text", order: 30,
            prompt: "Help me summarize some text. Ask me to paste it."),
    ])
}

public enum QuickActionError: Error, LocalizedError, Sendable {
    case notReady(String)
    case unsupportedVersion
    case duplicateID(String)
    case invalidAction(String)
    case missingConfiguration, existingConfiguration, changed, skillsUnavailable, sourceUnavailable

    public var errorDescription: String? {
        switch self {
        case .notReady(let message): return message
        case .unsupportedVersion: return "actions.json needs formatVersion 1."
        case .duplicateID(let id):
            return "actions.json contains duplicate id '\(id)'. Use unique ids."
        case .invalidAction(let detail): return detail
        case .missingConfiguration:
            return "Actions/actions.json is missing. Add a configuration or create starter actions."
        case .existingConfiguration:
            return
                "actions.json already exists. Edit it in Files; starter actions were not written."
        case .changed: return "The action configuration changed. Select the action again."
        case .skillsUnavailable:
            return "Select this action as a skill rather than requesting a prompt-only action."
        case .sourceUnavailable:
            return "Confirm the iCloud preference and folder in Settings first."
        }
    }
}
