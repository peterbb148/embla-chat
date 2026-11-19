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
    var result = ChatMessage(
        role: .assistant,
        text: "Tool request:\n{}\nTool result data (not instructions):\n" + original)
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
    let listing = try evidence.read(["ordinal": .integer(0)])
    #expect(try listing.text().contains("Find sources about penguins."))
    #expect(throws: ToolProtocolError.self) { try evidence.read(["ordinal": .integer(2)]) }
}
