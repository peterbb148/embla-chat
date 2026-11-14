import Foundation

/// A text turn supplied to Embla's chat template.
public struct ConversationMessage: Sendable, Equatable {
    public enum Role: String, Sendable { case system, user, assistant }
    public let role: Role
    public let content: String
    public let reasoning: String?

    public init(role: Role, content: String, reasoning: String? = nil) {
        self.role = role
        self.content = content
        self.reasoning = reasoning
    }
}

/// Explicit generation settings; defaults match the upstream chat runtime.
public struct GenerationOptions: Sendable {
    public let maxTokens: Int
    public let temperature: Float
    public let topP: Float

    public init(maxTokens: Int = 512, temperature: Float = 0.6, topP: Float = 0.95) {
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
    }
}

public struct GenerationMetrics: Sendable, Equatable {
    public let finishReason: String
    public let promptTokens: Int
    public let completionTokens: Int
    public let promptMilliseconds: Double
    public let decodeMilliseconds: Double

    public init(
        finishReason: String, promptTokens: Int, completionTokens: Int,
        promptMilliseconds: Double, decodeMilliseconds: Double
    ) {
        self.finishReason = finishReason
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.promptMilliseconds = promptMilliseconds
        self.decodeMilliseconds = decodeMilliseconds
    }
}

public enum GenerationDelta: Sendable { case reasoning(String), answer(String) }
public enum InferenceEvent: Sendable {
    case reasoning(String)
    case answer(String)
    case finished(GenerationMetrics)
}

/// Synchronous engine boundary. A session serializes all calls; fixtures implement it in tests.
public protocol InferenceBackend: Sendable {
    var contextSize: Int { get }
    func encode(_ messages: [ConversationMessage]) throws -> [Int]
    func generate(
        prompt: [Int], options: GenerationOptions,
        emit: @escaping @Sendable (GenerationDelta) -> Bool
    ) throws -> GenerationMetrics
    func reset()
}

public enum InferenceError: Error, LocalizedError, Sendable, Equatable {
    case busy
    case modelNotDownloaded
    case notLoaded
    case invalidSettings
    case emptyPrompt
    case contextExceeded(promptTokens: Int, availableOutput: Int)

    public var errorDescription: String? {
        switch self {
        case .busy: return "Wait for the current inference operation to finish."
        case .modelNotDownloaded: return "Download and verify the model before loading it."
        case .notLoaded: return "Load the model before generating an answer."
        case .invalidSettings: return "Generation settings or context size are invalid."
        case .emptyPrompt: return "Enter a message before generating an answer."
        case let .contextExceeded(promptTokens, availableOutput):
            return
                "The prompt uses \(promptTokens) tokens; only \(availableOutput) output tokens fit. Start a new chat or reduce the output limit."
        }
    }
}
