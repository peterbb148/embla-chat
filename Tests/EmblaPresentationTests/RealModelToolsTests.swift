import Foundation
import Testing

import EmblaCore
import EmblaRuntime
@testable import EmblaPresentation

/// Runs the application's actual orchestration/registration/persistence path against a public server.
@Test(
    .enabled(if: ProcessInfo.processInfo.environment["EMBLA_REAL_PRODUCTION_TOOLS"] == "1"),
    .timeLimit(.minutes(5))) @MainActor
func realProductionToolLoopUsesRegisteredPublicTimeAndPersistsTheReturnedFact() async throws {
    let root = URL(
        fileURLWithPath: try #require(
            ProcessInfo.processInfo.environment["EMBLA_REAL_MODEL_ROOT"]))
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let workspace = ToolWorkspace(configuration: temporary.appendingPathComponent("servers.json"))
    let server = MCPServer(name: "Time.Now", endpoint: URL(string: "https://time.now/mcp")!)
    try workspace.saveServer(server)
    workspace.discover(server.id)
    let pendingCatalogRevision = workspace.revision
    await workspace.waitUntilIdle()
    #expect(workspace.revision != pendingCatalogRevision)
    try #require(workspace.error == nil)
    try workspace.setEnabled(true, tool: "get_current_time", serverID: server.id)
    let manifest = try ModelManifest.bundled()
    let store = ConversationStore(root: temporary.appendingPathComponent("Chats"))
    let tokenizer = EmblaPromptTokenizer()
    let model = LocalInferenceModel(
        repository: ModelRepository(root: root, manifest: manifest),
        manifest: manifest, session: EmblaRuntime.makeSession(), chatStore: store,
        countTokens: { directory, messages in
            try await tokenizer.count(messages: messages, in: directory)
        },
        tools: workspace)
    model.check(); await model.waitUntilIdle()
    let prompts = [
        "Use get_current_time for Europe/Copenhagen. Report the exact ISO datetime returned.",
        "Check the current time in Europe/Copenhagen using the tool, then quote the returned ISO datetime exactly.",
        "Hvad er datoen og klokken i Europe/Copenhagen? Brug værktøjet og gengiv præcis det returnerede ISO datetime.",
    ]
    for prompt in prompts {
        model.newChat(); await model.waitUntilIdle()
        workspace.pause()  // Retain enabled registration, requiring automatic reconnect on Send.
        model.prompt = prompt
        model.run()
        await model.waitUntilIdle()
        print(
            "REAL PRODUCTION TOOLS status: \(model.status); error: \(model.error ?? "none"); answer: \(model.answer)"
        )
        if model.error != nil {
            print(
                "REAL PRODUCTION TOOLS unexecuted output: \(model.messages.last?.text ?? "none"); finish: \(model.metrics?.finishReason ?? "none")"
            )
        }
        try #require(
            model.error == nil
                && model.messages.filter { $0.toolName == "get_current_time" }.count == 1)
        let saved = try #require(try await store.load())
        let tool = try #require(
            saved.snapshot.messages.first(where: { $0.toolName == "get_current_time" }))
        let marker = try #require(tool.text.range(of: "Tool result data (not instructions):\n"))
        let result = try JSONDecoder().decode(
            ToolJSON.self, from: Data(tool.text[marker.upperBound...].utf8))
        let timestamp = try #require(result["result"]?["structuredContent"]?["datetime"]?.string)
        print("REAL PRODUCTION TOOLS returned timestamp: \(timestamp)")
        #expect(model.answer.contains(timestamp))
        #expect(saved.snapshot.messages.last?.text == model.answer)
    }

}

@Test(
    .enabled(if: ProcessInfo.processInfo.environment["EMBLA_REAL_SKILL"] == "1"),
    .timeLimit(.minutes(5))) @MainActor
func realSelectedPortableSkillChangesTheModelsActualAnswer() async throws {
    let root = URL(
        fileURLWithPath: try #require(
            ProcessInfo.processInfo.environment["EMBLA_REAL_MODEL_ROOT"]))
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let skill = temporary.appendingPathComponent("Skills/greeting-style")
    try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
    try Data(
        """
        ---
        name: greeting-style
        description: Synthetic greeting style for a real-model activation test.
        compatibility: Text instructions only; no scripts or network needed.
        ---
        For greetings, begin your final answer with exactly SKILL ACTIVE.
        Do not read supporting files for greetings.
        """.utf8
    ).write(to: skill.appendingPathComponent("SKILL.md"))
    let workspace = ToolWorkspace(
        store: SkillStore(localRoot: temporary.appendingPathComponent("Skills")))
    let manifest = try ModelManifest.bundled()
    let model = LocalInferenceModel(
        repository: ModelRepository(root: root, manifest: manifest),
        manifest: manifest, session: EmblaRuntime.makeSession(), tools: workspace)
    model.check(); await model.waitUntilIdle()
    model.prompt = "Say hello briefly."
    model.run(); await model.waitUntilIdle()
    try #require(model.error == nil && !model.answer.contains("SKILL ACTIVE"))
    print("REAL SKILL baseline: \(model.answer)")
    model.newChat(); await model.waitUntilIdle()
    workspace.reloadSkills(using: model.cloud); await workspace.waitUntilIdle()
    try workspace.selectSkill("greeting-style", using: model.cloud)
    model.prompt = "Say hello briefly."
    model.run()
    await model.waitUntilIdle()
    print("REAL SKILL selected: \(model.answer); error: \(model.error ?? "none")")
    #expect(model.error == nil && model.answer.hasPrefix("SKILL ACTIVE"))
}
