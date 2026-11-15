import Foundation

/// Human-editable action configuration. Skill references are reserved, never simulated.
public struct QuickAction: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case prompt, skill }
    public let id: String
    public let label: String
    public let order: Int
    public let enabled: Bool
    public let type: Kind
    public let prompt: String?
    public let skill: String?

    public init(
        id: String, label: String, order: Int, enabled: Bool = true,
        type: Kind = .prompt, prompt: String? = nil, skill: String? = nil
    ) {
        self.id = id
        self.label = label
        self.order = order
        self.enabled = enabled
        self.type = type
        self.prompt = prompt
        self.skill = skill
    }
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
    case unsupportedVersion
    case duplicateID(String)
    case invalidAction(String)
    case missingConfiguration, existingConfiguration, changed, skillsUnavailable, sourceUnavailable

    public var errorDescription: String? {
        switch self {
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
            return "Skill actions require skills support, which is not available yet."
        case .sourceUnavailable:
            return "Confirm the iCloud preference and folder in Settings first."
        }
    }
}
