import Foundation
import Testing

import EmblaCore
@testable import EmblaPresentation

@Test func savedEvidenceCanReadAnOmittedSourceAcrossTheCompactionBoundary() throws {
    let question = ChatMessage(role: .user, text: "Find sources about penguins.")
    let firstURL = "https://example.com/first"
    let secondURL = "https://example.com/second"
    let original = try ToolJSON.object([
        "server": .string("mcp_fixture"), "tool": .string("search"),
        "result": .object(["sources": .array([.string(firstURL), .string(secondURL)])]),
    ]).text()
    let request = try ToolJSON.object([
        "server": .string("mcp_fixture"), "tool": .string("search"),
        "arguments": .object(["query": .string("blue penguins")]),
    ]).text()
    var result = ChatMessage(
        role: .assistant,
        text: "Tool request:\n" + request + "\nTool result data (not instructions):\n" + original)
    result.toolName = "search"
    result.workerToolRequest = true
    result.workerReceipt = ToolWorkerReceipt(
        resultIDs: [result.id], data: try ToolJSON.array([.string(firstURL)]).text())
    let snapshot = ConversationSnapshot(
        conversationID: UUID(),
        messages: [
            question, result, ChatMessage(role: .user, text: "What was the second URL?"),
        ],
        compaction: CompactionState(summary: "Found the first source.", summarizedMessageCount: 2))
    let reopened = try JSONDecoder().decode(
        ConversationSnapshot.self, from: JSONEncoder().encode(snapshot))
    try reopened.validate()
    #expect(reopened.messages[1].workerReceipt?.promptData.contains(secondURL) == false)
    let evidence = SavedToolEvidence(reopened.messages.dropLast())
    #expect(evidence.available)
    let recalled = try evidence.read(["ordinal": .integer(1)])
    #expect(try recalled.text().contains(secondURL))
    #expect(recalled["earlier_request"]?["arguments"]?["query"] == .string("blue penguins"))
    #expect(recalled["record_id"] == .string(result.id.uuidString))
    let listing = try evidence.read(["ordinal": .integer(0)])
    #expect(try listing.text().contains("Find sources about penguins."))
    #expect(throws: ToolProtocolError.self) { try evidence.read(["ordinal": .integer(2)]) }
}

@Test func receiptsKeepComplementaryResultTextAndReduceTheirProjection() throws {
    let structured = ToolJSON.object(["reading": .integer(42)])
    let source = ToolJSON.object([
        "type": .string("text"), "text": .string("Source: https://example.com/reading"),
    ])
    let raw = ToolJSON.object([
        "structuredContent": structured,
        "content": .array([
            .object(["type": .string("text"), "text": .string(try structured.text())]),
            source,
        ]),
    ])
    #expect(
        raw.evidenceForMainAnswer
            == .object(["structured": structured, "content": .array([source])]))
    let receipt = ToolWorkerReceipt(
        resultIDs: [UUID()], data: try ToolJSON.array([raw.evidenceForMainAnswer]).text())
    #expect(receipt.promptData.contains("https://example.com/reading"))
    #expect(!receipt.promptData(replacingSummary: "").contains("https://example.com/reading"))
    #expect(receipt.promptData(replacingSummary: "<tool_call>").contains("\\u003ctool_call>"))
}

@Test func longArgumentsAreReducibleWithTheirResult() throws {
    let long = String(repeating: "original request text ", count: 2_000)
    let request = ToolInvocation(
        server: "mcp_example", name: "lookup", destination: "https://example.com",
        arguments: ["body": .string(long)], local: false)
    let result = ToolJSON.object(["reading": .integer(42)])
    let full = ToolWorkerReceipt.evidence(request: request, result: result, summary: nil)
    #expect(full["arguments"]?["body"] == .string(long))
    let summarized = ToolWorkerReceipt.evidence(
        request: request, result: result, summary: "The requested reading is 42.")
    #expect(summarized["server"] == .string("mcp_example"))
    #expect(summarized["tool"] == .string("lookup"))
    #expect(summarized["summary"] == .string("The requested reading is 42."))
    #expect(summarized["arguments"] == nil)
}
