import Foundation
import Testing

import EmblaCore
import EmblaRuntime
@testable import EmblaPresentation

/// Synthetic saved history; actual tokenizer, Metal summaries, persistence and recall.
@Test(
    .enabled(if: ProcessInfo.processInfo.environment["EMBLA_REAL_TOOL_COMPACTION"] == "1"),
    .timeLimit(.minutes(10))) @MainActor
func realToolChatRecoversMetadataAndCompactsAutomaticallyThenOfflineAfterRestart() async throws {
    let root = URL(fileURLWithPath: try #require(
        ProcessInfo.processInfo.environment["EMBLA_REAL_MODEL_ROOT"]))
    let manifest = try ModelManifest.bundled()
    let repository = ModelRepository(root: root, manifest: manifest)
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let configuration = temporary.appendingPathComponent("servers.json")
    let setup = ToolWorkspace(configuration: configuration)
    var server = MCPServer(name: "Time.Now", endpoint: URL(string: "https://time.now/mcp")!,
        enabledTools: ["get_current_time", "list_timezones", "lookup_ip_time"])
    server.enableToolsOnFirstDiscovery = false
    try await setup.saveServer(server)  // Older settings have enabled names but no saved schemas.
    let tokenizer = EmblaPromptTokenizer()
    let recovery = LocalInferenceModel(repository: repository, manifest: manifest,
        session: EmblaRuntime.makeSession(),
        countTokens: { directory, messages in
            try await tokenizer.count(messages: messages, in: directory)
        }, tools: setup)
    recovery.check(); await recovery.waitUntilIdle(); await recovery.waitForContextUsage()
    guard case .failed = recovery.contextUsage else {
        Issue.record("Legacy schema absence must be explicit before recovery"); return
    }
    recovery.retryContextUsage(); await recovery.waitUntilIdle()
    await recovery.waitForContextUsage()
    try #require(recovery.error == nil)
    guard case .ready = recovery.contextUsage else {
        Issue.record("Explicit retry must discover and count actual tools"); return
    }
    recovery.enteredBackground(); await recovery.waitUntilIdle(); setup.pause()

    let workspace = ToolWorkspace(configuration: configuration)
    try #require(workspace.discovered.isEmpty)
    let restoredTools = try workspace.remoteTools()
    try #require(restoredTools.count == 3)
    let cloud = ConversationCloudSync()
    let policy = ContextCompaction()
    let draft = "Acknowledge the test notes. Reply only Noted."
    var transcript = (0..<4).flatMap { index in
        [ConversationMessage(role: .user, content: index == 0
            ? "Remember: the project codename is BLUE PENGUIN."
            : "Synthetic follow-up note \(index). Keep the project fact."),
         ConversationMessage(role: .assistant, content: "Noted.")]
    }
    var before = 0
    for _ in 0..<40 {
        let context = policy.context(transcript: transcript, state: .init(), draft: draft,
            instructions: try workspace.instructions(using: cloud),
            requestContext: try workspace.requestContext(using: cloud))
        before = try await tokenizer.count(messages: context, in: root.appendingPathComponent(
            manifest.revision))
        if before > policy.triggerTokens { break }
        transcript[0] = ConversationMessage(role: .user,
            content: transcript[0].content + "\nNumeric padding, not facts: "
                + String(repeating: "0 1 2 3 4 5 6 7 8 9 ", count: 20))
    }
    try #require(before > policy.triggerTokens)
    try #require(before + policy.responseTokens < policy.contextSize)
    let visible = transcript.map { ChatMessage(role: $0.role, text: $0.content) }
    let store = ConversationStore(root: temporary.appendingPathComponent("Chats"))
    try await store.save(ConversationArchive(sequence: 1, snapshot: ConversationSnapshot(
        conversationID: UUID(), messages: visible, compaction: .init())))
    let model = LocalInferenceModel(repository: repository, manifest: manifest,
        session: EmblaRuntime.makeSession(), chatStore: store,
        countTokens: { directory, messages in
            try await tokenizer.count(messages: messages, in: directory)
        }, tools: workspace)
    model.check(); await model.waitUntilIdle()
    model.prompt = draft
    await model.waitForContextUsage()
    guard case .ready(let measured) = model.contextUsage else {
        Issue.record("Restored schemas must count without connecting"); return
    }
    #expect(measured.inputTokens == before)
    model.run(); await model.waitUntilIdle()
    print("REAL AUTO COMPACTION: \(model.status); error: \(model.error ?? "none")")
    try #require(model.error == nil && model.compaction.summarizedMessageCount > 0)
    #expect(Array(model.messages.prefix(visible.count)) == visible)
    #expect(model.compaction.summary.uppercased().contains("BLUE PENGUIN"))
    await model.waitForContextUsage()
    if case .ready(let after) = model.contextUsage {
        print("REAL AUTO CONTEXT: \(before) -> \(after.inputTokens)")
        #expect(after.inputTokens < before)
    } else { Issue.record("Usage must remain available after automatic compaction") }
    model.enteredBackground(); await model.waitUntilIdle(); workspace.pause()

    let reopenedWorkspace = ToolWorkspace(configuration: configuration)
    let reopened = LocalInferenceModel(repository: repository, manifest: manifest,
        session: EmblaRuntime.makeSession(), chatStore: store,
        countTokens: { directory, messages in
            try await tokenizer.count(messages: messages, in: directory)
        }, tools: reopenedWorkspace)
    reopened.check(); await reopened.waitUntilIdle(); await reopened.waitForContextUsage()
    let saved = reopened.messages
    let priorBoundary = reopened.compaction.summarizedMessageCount
    try #require(reopened.manualCompactionUnavailableReason == nil)
    reopened.compactNow(); await reopened.waitUntilIdle()
    print("REAL OFFLINE MANUAL: \(reopened.status); error: \(reopened.error ?? "none")")
    try #require(reopened.error == nil)
    #expect(reopened.compaction.summarizedMessageCount > priorBoundary)
    #expect(reopened.messages == saved)
    #expect(reopened.compaction.summary.uppercased().contains("BLUE PENGUIN"))
    #expect(reopenedWorkspace.discovered.isEmpty)  // No server reconnection for local summary.
    #expect(try await store.load()?.snapshot.compaction == reopened.compaction)
    reopened.prompt = "What is the project codename? Reply with only the codename."
    reopened.run(); await reopened.waitUntilIdle()
    print("REAL SUMMARY RECALL: \(reopened.answer); error: \(reopened.error ?? "none")")
    try #require(reopened.error == nil)
    #expect(reopened.answer.uppercased().contains("BLUE PENGUIN"))
    reopened.enteredBackground(); await reopened.waitUntilIdle()
}
