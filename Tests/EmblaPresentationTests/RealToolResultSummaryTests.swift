import Foundation
import Testing

import EmblaCore
import EmblaRuntime
@testable import EmblaPresentation

/// Real tokenizer/Metal summaries and answer; synthetic saved result, no public server or phone.
@Test(
    .enabled(if: ProcessInfo.processInfo.environment["EMBLA_REAL_TOOL_RESULT_SUMMARY"] == "1"),
    .timeLimit(.minutes(10))) @MainActor
func realModelRecoversAnOversizedSavedToolResultWithSourcesWithoutANetworkCall() async throws {
    let root = URL(fileURLWithPath: try #require(
        ProcessInfo.processInfo.environment["EMBLA_REAL_MODEL_ROOT"]))
    let manifest = try ModelManifest.bundled()
    let repository = ModelRepository(root: root, manifest: manifest)
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let source = String(
        repeating: "Source https://example.com/fact reports that the codename is BLUE PENGUIN.\n",
        count: 900)
    var result = ChatMessage(role: .assistant, text: source)
    result.toolName = "synthetic_lookup"
    let store = ConversationStore(root: temporary)
    try await store.save(ConversationArchive(
        sequence: 1,
        snapshot: ConversationSnapshot(
            conversationID: UUID(), messages: [
                ChatMessage(role: .user, text: "What did the retrieved source report?"), result,
            ], compaction: .init())))
    let tokenizer = EmblaPromptTokenizer()
    let before = try await tokenizer.count(
        messages: [ConversationMessage(role: .user, content: source)],
        in: root.appendingPathComponent(manifest.revision))
    try #require(before > 8_192)
    let tools = ToolWorkspace(store: nil, network: NetworkAccess(initialState: .unsatisfied))
    let model = LocalInferenceModel(
        repository: repository, manifest: manifest, session: EmblaRuntime.makeSession(),
        chatStore: store,
        countTokens: { directory, messages in
            try await tokenizer.count(messages: messages, in: directory)
        }, tools: tools)
    model.check(); await model.waitUntilIdle()
    model.prompt = "Use only the completed tool result saved above. State the exact codename and source URL."
    model.run(); await model.waitUntilIdle()
    try #require(model.error == nil)
    let saved = try #require(try await store.load())
    let reduced = try #require(saved.snapshot.messages.first(where: { $0.id == result.id }))
    #expect(reduced.text == source)
    #expect(reduced.toolResultSummary?.contains("BLUE PENGUIN") == true)
    #expect(reduced.toolResultSummary?.contains("https://example.com/fact") == true)
    #expect(model.answer.contains("BLUE PENGUIN"))
    #expect(model.answer.contains("https://example.com/fact"))
    let after = try await tokenizer.count(
        messages: [ConversationMessage(role: .user, content: reduced.inferenceContent)],
        in: root.appendingPathComponent(manifest.revision))
    #expect(after < before && after < 8_192)
    print("Real local-model tool-result reduction: \(before) → \(after) source tokens; raw text preserved.")
    model.enteredBackground(); await model.waitUntilIdle()
}
