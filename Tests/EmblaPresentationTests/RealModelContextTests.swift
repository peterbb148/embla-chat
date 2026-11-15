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
        "Remember this fact: the project codename is BLUE PENGUIN. " + padding + "Reply only Noted.",
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
    let question = "What is the project codename? Reply with only the codename."
    let baselineContext = ContextCompaction().context(
        transcript: visible.map { ConversationMessage(role: $0.role, content: $0.text,
            reasoning: $0.reasoning.isEmpty ? nil : $0.reasoning) },
        state: CompactionState(), draft: question)
    let baseline = try await session.generate(messages: baselineContext)
    var baselineAnswer = ""
    for try await event in baseline.events {
        if case .answer(let text) = event { baselineAnswer += text }
    }
    await baseline.waitUntilFinished()
    print("Uncompacted baseline recall: \(baselineAnswer)")
    #expect(baselineAnswer.uppercased().contains("BLUE PENGUIN"))
    #expect(!visible.suffix(4).contains { $0.text.uppercased().contains("BLUE PENGUIN") })
    model.compactNow(); await model.waitUntilIdle()
    try #require(model.error == nil)
    #expect(model.messages == visible)
    print("Generated summary: \(model.compaction.summary)")
    #expect(model.compaction.summary.uppercased().contains("BLUE PENGUIN"))
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
    model.prompt = question
    model.run(); await model.waitUntilIdle()
    try #require(model.error == nil)
    print("Compacted recall reply: \(model.messages.last?.text ?? "")")
    #expect(model.messages.last?.text.uppercased().contains("BLUE PENGUIN") == true)
    model.enteredBackground(); await model.waitUntilIdle()
}

/// Real inference after navigation and restart; host evidence is not iPhone performance evidence.
@Test(
    .enabled(if: ProcessInfo.processInfo.environment["EMBLA_REAL_MODEL_ROOT"] != nil),
    .timeLimit(.minutes(5))
) @MainActor
func realHostHistoryRestoresTwoIndependentConversationContexts() async throws {
    let root = URL(fileURLWithPath: try #require(
        ProcessInfo.processInfo.environment["EMBLA_REAL_MODEL_ROOT"]))
    let manifest = try ModelManifest.bundled()
    let repository = ModelRepository(root: root, manifest: manifest)
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let session = EmblaRuntime.makeSession()
    let model = LocalInferenceModel(repository: repository, manifest: manifest,
        session: session, chatStore: ConversationStore(root: temporary))
    model.check(); await model.waitUntilIdle()
    try #require(model.error == nil && model.readyDirectory != nil)
    model.prompt = "Remember: the project codename is BLUE PENGUIN. Reply only Noted."
    model.run(); await model.waitUntilIdle()
    try #require(model.error == nil && model.messages.last?.state == .complete)
    let firstID = model.conversationID
    model.newChat(); await model.waitUntilIdle()
    let secondID = model.conversationID
    model.prompt = "Remember: the project codename is RED FOX. Reply only Noted."
    model.run(); await model.waitUntilIdle()
    try #require(model.error == nil && model.messages.last?.state == .complete)
    model.selectChat(firstID); await model.waitUntilIdle()
    model.prompt = "What is the project codename? Reply with only the codename."
    model.run(); await model.waitUntilIdle()
    try #require(model.error == nil && model.messages.last?.state == .complete)
    let firstAnswer = model.messages.last?.text.uppercased() ?? ""
    print("Real first-chat recall after switching: \(firstAnswer)")
    #expect(firstAnswer.contains("BLUE PENGUIN") && !firstAnswer.contains("RED FOX"))
    model.enteredBackground(); await model.waitUntilIdle()
    let reopened = LocalInferenceModel(repository: repository, manifest: manifest,
        session: EmblaRuntime.makeSession(), chatStore: ConversationStore(root: temporary))
    reopened.check(); await reopened.waitUntilIdle()
    #expect(reopened.conversationID == firstID && reopened.history.count == 1)
    reopened.selectChat(secondID); await reopened.waitUntilIdle()
    reopened.prompt = "What is the project codename? Reply with only the codename."
    reopened.run(); await reopened.waitUntilIdle()
    try #require(reopened.error == nil && reopened.messages.last?.state == .complete)
    let secondAnswer = reopened.messages.last?.text.uppercased() ?? ""
    print("Real second-chat recall after restart: \(secondAnswer)")
    #expect(secondAnswer.contains("RED FOX") && !secondAnswer.contains("BLUE PENGUIN"))
    reopened.enteredBackground(); await reopened.waitUntilIdle()
}
