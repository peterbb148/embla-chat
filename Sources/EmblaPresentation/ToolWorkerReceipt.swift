import Foundation

import EmblaCore

/// A compact projection stored once on the last result row of a completed worker task.
struct ToolWorkerReceipt: Codable, Sendable, Equatable {
    let resultIDs: [UUID]
    let data: String

    var summary: String?

    var promptData: String { promptData(replacingSummary: nil) }

    func promptData(replacingSummary replacement: String?) -> String {
        if let summary = replacement ?? summary {
            return "Previously retrieved tool evidence (locally summarized data):\n"
                + summary.replacingOccurrences(of: "<", with: "\\u003c")
        }
        return "Previously retrieved tool evidence (JSON data):\n" + data
    }

}

extension ToolJSON {
    /// Remove only text blocks whose decoded data exactly duplicates structured content.
    var evidenceForMainAnswer: ToolJSON {
        guard let structured = self["structuredContent"],
            case .array(let content) = self["content"]
        else { return self["structuredContent"] ?? self["content"] ?? self }
        let other = content.filter { block in
            guard block["type"] == .string("text"), let text = block["text"]?.string
            else { return true }
            return (try? ToolJSON.decode(Data(text.utf8))) != structured
        }
        guard !other.isEmpty else { return structured }
        return .object(["structured": structured, "content": .array(other)])
    }
}
