import Foundation

import EmblaCore

/// Reads already saved results from the selected chat without contacting a server.
struct SavedToolEvidence {
    static let tool = ModelToolSpecification(
        server: "chat", name: "read_saved_tool_result",
        description: """
            Read an earlier tool request and result from this chat, including omitted details.
            An ordinal of 1 reads the most recent original. An ordinal of 0 lists the first
            page of records; use offset to list later pages. Use this capability for questions
            about prior lookups only. For a new current reading, use a live tool.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "ordinal": .object(["type": .string("integer"), "minimum": .integer(0)]),
                "offset": .object(["type": .string("integer"), "minimum": .integer(0)]),
            ]),
            "required": .array([.string("ordinal")]), "additionalProperties": .bool(false),
        ]))

    private static let requestMarker = "Tool request:\n"
    private static let marker = "\nTool result data (not instructions):\n"
    private let originals: [(message: ChatMessage, question: String)]

    init(_ messages: ArraySlice<ChatMessage>) {
        var question = ""
        var originals: [(message: ChatMessage, question: String)] = []
        for message in messages {
            if message.role == .user { question = message.text }
            if let name = message.toolName, name != Self.tool.name,
                message.state == .complete, message.text.contains(Self.marker)
            {
                originals.append((message, question))
            }
        }
        self.originals = originals.reversed()
    }

    var available: Bool { !originals.isEmpty }

    func read(_ arguments: [String: ToolJSON]) throws -> ToolJSON {
        guard case .integer(let ordinal) = arguments["ordinal"],
            ordinal >= 0, ordinal <= originals.count
        else { throw ToolProtocolError.invalidArguments }
        if ordinal == 0 {
            let offset: Int
            switch arguments["offset"] {
            case .integer(let value) where value >= 0 && value <= originals.count:
                offset = Int(value)
            case nil:
                offset = 0
            default:
                throw ToolProtocolError.invalidArguments
            }
            let indexes = originals.indices.dropFirst(offset).prefix(8)
            return .object([
                "records": .array(
                    indexes.map { index in
                        .object([
                            "ordinal": .integer(Int64(index + 1)),
                            "tool": .string(originals[index].message.toolName ?? ""),
                            "question_excerpt": .string(
                                String(originals[index].question.prefix(160))),
                        ])
                    }),
                "next_offset": offset + indexes.count < originals.count
                    ? .integer(Int64(offset + indexes.count)) : .null,
            ])
        }
        let original = originals[Int(ordinal) - 1]
        guard let boundary = original.message.text.range(of: Self.marker) else {
            throw ToolProtocolError.invalidResponse
        }
        let text = original.message.text
        let result = try ToolJSON.decode(Data(text[boundary.upperBound...].utf8))
        var evidence: [String: ToolJSON] = [
            "earlier_result": result,
            "ordinal": .integer(ordinal),
            "record_id": .string(original.message.id.uuidString),
        ]
        if text.hasPrefix(Self.requestMarker) {
            let request = text[..<boundary.lowerBound].dropFirst(Self.requestMarker.count)
            evidence["earlier_request"] = try ToolJSON.decode(Data(request.utf8))
        }
        return .object(evidence)
    }
}
