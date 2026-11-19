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
                + requestAttribution
                + summary.replacingOccurrences(of: "<", with: "\\u003c")
        }
        return "Previously retrieved tool evidence (JSON data):\n" + data
    }

    /// Full arguments are part of the reducible evidence. A local summary is produced
    /// from the saved original request and result, while the tool identity stays exact.
    static func evidence(request: ToolInvocation, result: ToolJSON, summary: String?) -> ToolJSON {
        var fields: [String: ToolJSON] = [
            "server": .string(request.server), "tool": .string(request.name),
        ]
        if let summary {
            fields["summary"] = .string(summary)
        } else {
            fields["arguments"] = .object(request.arguments)
            fields["data"] = result.evidenceForMainAnswer
        }
        return .object(fields)
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
