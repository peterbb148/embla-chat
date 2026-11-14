import Foundation

import EmblaChat
import EmblaCore
import EmblaMetal

/// Production entry point. Always loads Embla through the pinned Metal runtime.
public enum EmblaRuntime {
    public static func makeSession() -> InferenceSession {
        InferenceSession { directory, contextSize in
            try MetalBackend(directory: directory, contextSize: contextSize)
        }
    }
}

/// The session owns this immutable wrapper and serializes access to its mutable upstream model.
private struct MetalBackend: InferenceBackend {
    private let model: ChatModel
    var contextSize: Int { model.engine.maxContext }

    init(directory: URL, contextSize: Int) throws {
        do {
            model = try ChatModel(directory: directory, context: contextSize)
        } catch {
            throw RuntimeFailure(message: "Embla could not load: \(error)")
        }
    }

    func encode(_ messages: [ConversationMessage]) throws -> [Int] {
        let turns = messages.map {
            ChatMessage(role: $0.role.rawValue, content: $0.content, reasoning: $0.reasoning)
        }
        do {
            return try model.tokenizer.encode(ChatTemplate.render(turns))
        } catch {
            throw RuntimeFailure(message: "Embla rejected the conversation: \(error)")
        }
    }

    func generate(
        prompt: [Int], options: GenerationOptions,
        emit: @escaping @Sendable (GenerationDelta) -> Bool
    ) throws -> GenerationMetrics {
        let request = ChatModel.Request(
            prompt: prompt, maxTokens: options.maxTokens,
            sampling: Sampling(temperature: options.temperature, topP: options.topP), thinking: true
        )
        let outcome = model.run(request) { delta in
            switch delta {
            case let .reasoning(text): return emit(.reasoning(text))
            case let .content(text): return emit(.answer(text))
            }
        }
        return GenerationMetrics(
            finishReason: outcome.finishReason, promptTokens: outcome.promptTokens,
            completionTokens: outcome.completionTokens,
            promptMilliseconds: outcome.promptMs, decodeMilliseconds: outcome.decodeMs
        )
    }

    func reset() { model.engine.reset() }
}

/// Preserves upstream diagnostic descriptions in user-facing error presentation.
private struct RuntimeFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
