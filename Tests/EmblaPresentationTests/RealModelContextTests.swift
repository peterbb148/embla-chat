import Foundation
import Testing

import EmblaCore
import EmblaRuntime
@testable import EmblaPresentation

/// Opt-in real-host validation; no fake backend or simulator/device performance claims.
@Test(
    .enabled(if: ProcessInfo.processInfo.environment["EMBLA_REAL_MODEL_ROOT"] != nil),
    .timeLimit(.minutes(5))
) @MainActor
func realHostModelManuallyCompactsBelowThresholdAndRecallsTheRetainedFact() async throws {
    let root = URL(fileURLWithPath: try #require(
        ProcessInfo.processInfo.environment["EMBLA_REAL_MODEL_ROOT"]))
    let manifest = try ModelManifest.bundled()
    let repository = ModelRepository(root: root, manifest: manifest)
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let store = ConversationStore(root: temporary)
    let tokenizer = EmblaPromptTokenizer()
    let session = EmblaRuntime.makeSession()
    let model = LocalInferenceModel(repository: repository, manifest: manifest,
        session: session, chatStore: store,
        countTokens: { directory, messages in
            try await tokenizer.count(messages: messages, in: directory)
        })
    model.check(); await model.waitUntilIdle()
    try #require(model.error == nil)
    try #require(model.readyDirectory != nil)
    let padding = String(repeating:
        "This is synthetic background text for a local compaction test. ", count: 24)
    let prompts = [
        "Remember this fact: the project codename is EMBER-42. " + padding + "Reply only Noted.",
        "This is an explicit real-model test conversation. Reply only Noted.",
        "We are testing manual compaction below its automatic threshold. Reply only Noted.",
        "Keep earlier facts available for a later question. Reply only Noted.",
    ]
    for prompt in prompts {
        model.prompt = prompt
        model.run(); await model.waitUntilIdle()
        try #require(model.error == nil)
        try #require(model.messages.last?.state == .complete)
    }
    await model.waitForContextUsage()
    guard case .ready(let before) = model.contextUsage else {
        Issue.record("Real tokenizer usage unavailable"); return
    }
    #expect(before.inputTokens < 5888)
    let visible = model.messages
    #expect(!visible.suffix(4).contains { $0.text.uppercased().contains("EMBER-42") })
    model.compactNow(); await model.waitUntilIdle()
    try #require(model.error == nil)
    #expect(model.messages == visible)
    #expect(model.compaction.summary.uppercased().contains("EMBER-42"))
    #expect(model.compaction.summarizedMessageCount > 0)
    #expect(try await store.load()?.snapshot.compaction == model.compaction)
    await model.waitForContextUsage()
    if case .ready(let after) = model.contextUsage {
        #expect(after.inputTokens < before.inputTokens)
        let projected = ContextCompaction().context(
            transcript: visible.map { ConversationMessage(role: $0.role, content: $0.text,
                reasoning: $0.reasoning.isEmpty ? nil : $0.reasoning) },
            state: model.compaction, draft: "")
        #expect(try await session.tokenCount(messages: projected) == after.inputTokens)
        print("Real host compaction: input \(before.inputTokens) -> \(after.inputTokens) tokens.")
    } else { Issue.record("Post-compaction count unavailable") }
    model.prompt = "What is the project codename? Reply with only the codename."
    model.run(); await model.waitUntilIdle()
    try #require(model.error == nil)
    #expect(model.messages.last?.text.uppercased().contains("EMBER-42") == true)
    model.enteredBackground(); await model.waitUntilIdle()
}
