import Foundation

import EmblaCore

/// Interprets the tool router output before any text is shown or added to history.
public enum ToolWorkerHandoff: Equatable {
    case delegate
    case answer(String)

    public static func parse(_ output: String, finishReason: String?) throws -> Self {
        guard finishReason == "stop" else { throw ToolProtocolError.invalidResponse }
        let segments = output.components(separatedBy: "</think>")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if segments == ["DELEGATE"] || segments == ["DELEGATE", "DELEGATE"] {
            return .delegate
        }

        // A reserved line can be an ambiguous control signal. Ordinary sentences may
        // quote the word as literal text after their purpose is clear.
        let ambiguous = output.split(whereSeparator: \.isNewline).contains { line in
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let unwrapped = text.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
            return unwrapped == "DELEGATE" || text.hasPrefix("DELEGATE:")
                || text.hasPrefix("DELEGATE. ")
        }
        guard segments.count == 1, !output.contains("<think"), !ambiguous,
            case .answer(let text) = try ModelToolResponse.parse(output, finishReason: finishReason)
        else { throw ToolProtocolError.invalidResponse }
        return .answer(text)
    }

    /// Returns displayable reply text without exposing an unfinished routing signal.
    public static func displayableAnswer(_ output: String) -> String? {
        let reserved = [
            "DELEGATE", "<think>", "</think>", "<tool_call>", "</tool_call>",
            "<function=", "</function>", "<parameter=", "</parameter>",
        ]
        var prefix = output
        if let tail = output.split(whereSeparator: \.isWhitespace).last {
            let signal = tail.drop(while: { $0.isPunctuation && $0 != "<" })
            if !signal.isEmpty && reserved.contains(where: { $0.hasPrefix(signal) }) {
                prefix = String(output[..<tail.startIndex])
            }
        }
        guard case .answer(let answer) = try? parse(prefix, finishReason: "stop")
        else { return nil }
        return answer
    }

}

public extension ToolWorkerHandoff {
    /// The main conversation sees capability descriptions, while schemas stay in the worker.
    static func instructions(
        tools: [ModelToolSpecification], hasPriorLookup: Bool = false
    ) throws -> String {
        let capabilities = try ToolJSON.array(
            tools.map {
                .object(["name": .string($0.name), "description": .string($0.description)])
            }
        ).text()
        // Limit the representation before tokenization. The worker can still browse
        // every enabled method, and actual context checks use the tokenizer.
        let capabilityContext: String
        let capabilityLimit = 4_096
        if capabilities.utf8.count <= capabilityLimit {
            capabilityContext = "Its enabled capabilities are " + capabilities + "."
        } else {
            let names = try ToolJSON.array(tools.map { .string($0.name) }).text()
            capabilityContext =
                names.utf8.count <= capabilityLimit
                ? "Its enabled method names are " + names + ". The worker can browse their details."
                : "The full enabled catalogue is available in the worker. If the user asks "
                    + "for a live lookup, external evidence, or an app action, always output "
                    + "DELEGATE. The worker will check whether a matching tool exists."
        }
        let instructions = """
            You are Embla. A tool worker can look up facts for you.
            \(capabilityContext)
            If answering the latest user question requires current or external facts covered
            by those capabilities, output exactly DELEGATE and stop. Also delegate requests
            to perform an action that an enabled capability supports.

            Carry the previous question's intent into short follow-ups. A different
            location, subject or time requires a new lookup even when prior evidence
            appears in the conversation. For example, after checking live weather
            somewhere, "And in the next town?" requires DELEGATE if live weather is
            supported. A question about the prior reading itself can use the old result.

            Use prior evidence only for its original subject and location. If no enabled
            capability can provide the requested fact, explain that and do not guess.
            Answer ordinary questions directly. Never emit tool-call markup.
            """
        guard hasPriorLookup else { return instructions }
        return instructions + """

            A prior tool result is historical. A follow-up about a different location or a
            fresh reading needs a new lookup. For example, after the time in Madrid, "What
            about Lisbon?" requests a live time lookup. Output DELEGATE immediately for such
            a request, even if the timezone identifier or another exact argument is unknown.
            The worker resolves those arguments. For missing details about the prior result
            itself, use the saved-evidence capability when listed.
            """
    }
}
