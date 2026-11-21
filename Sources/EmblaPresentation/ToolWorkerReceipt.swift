import Foundation

import EmblaCore

/// A persisted projection from chats saved before tools moved into the active chat.
struct ToolWorkerReceipt: Codable, Sendable, Equatable {
    let resultIDs: [UUID]
    let data: String

    var summary: String?

    var promptData: String { promptData(replacingSummary: nil) }

    func promptData(replacingSummary replacement: String?) -> String {
        if let summary = replacement ?? summary {
            return "Previously retrieved tool evidence (locally summarized data):\n"
                + requestAttribution
                + summary.replacingOccurrences(of: "<", with: "\\u003c")
        }
        return "Previously retrieved tool evidence (JSON data):\n" + data
    }

    private var requestAttribution: String {
        guard case .array(let results) = try? ToolJSON.decode(Data(data.utf8)) else { return "" }
        let requests = results.compactMap { value -> ToolJSON? in
            guard let fields = value.object, fields["server"] != nil else { return nil }
            return .object(fields.filter { ["server", "tool"].contains($0.key) })
        }
        guard !requests.isEmpty, let text = try? ToolJSON.array(requests).text() else { return "" }
        return "Original call attribution (JSON data): \(text)\n"
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
