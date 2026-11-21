import Foundation
import Testing

import EmblaCore
import EmblaRuntime
@testable import EmblaPresentation

@Test(
    .enabled(if: ProcessInfo.processInfo.environment["EMBLA_REAL_TOOL_CHAT"] == "1"),
    .timeLimit(.minutes(10))) @MainActor
func activeChatRoutesNaturalSearchAndTimeFollowUps() async throws {
    let env = ProcessInfo.processInfo.environment
    let modelRoot = URL(fileURLWithPath: try #require(env["EMBLA_REAL_MODEL_ROOT"]))
    let port = try #require(env["EMBLA_ROUTING_FIXTURE_PORT"])
    let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let workspace = ToolWorkspace(configuration: root.appendingPathComponent("servers.json"))
    let time = MCPServer(
        id: UUID(uuidString: "10000000-0000-4000-8000-000000000001")!,
        name: "Time fixture", endpoint: URL(string: "http://127.0.0.1:\(port)/routing-time")!)
    let search = MCPServer(
        id: UUID(uuidString: "20000000-0000-4000-8000-000000000001")!,
        name: "Search fixture", endpoint: URL(string: "http://127.0.0.1:\(port)/routing-search")!)
    let manifest = try ModelManifest.bundled()
    let store = ConversationStore(root: root.appendingPathComponent("Chats"))
    let tokenizer = EmblaPromptTokenizer()
    let model = LocalInferenceModel(
        repository: ModelRepository(root: modelRoot, manifest: manifest),
        manifest: manifest, session: EmblaRuntime.makeSession(), chatStore: store,
        countTokens: { directory, messages in
            try await tokenizer.count(messages: messages, in: directory)
        }, tools: workspace,
        compactionPolicy: ContextCompaction(contextSize: LocalInferenceModel.productionContextSize))
    model.check(); await model.waitUntilIdle()
    for server in [time, search] {
        try await workspace.saveServer(server)
        workspace.discover(server.id)
        await workspace.waitUntilIdle()
        try #require(workspace.error == nil)

        model.toolConfigurationChanged()
        await model.waitForContextUsage()
        if case .ready(let usage) = model.contextUsage {
            print("ACTIVE CHAT fresh context: \(usage.inputTokens)/\(usage.capacity)")
            #expect(usage.inputTokens < 4_096)
        } else {
            Issue.record("Fresh prompt token count was unavailable.")
        }

        for (question, expectedMethod, expectedFact) in [
            ("What time is it in Hong Kong?", "get_current_time", "14:37"),
            ("What about Tokyo?", "get_current_time", "15:37"),
        ] {
            let count = model.messages.filter { $0.toolName != nil }.count
            model.prompt = question
            model.run(); await model.waitUntilIdle()
            let results = model.messages.filter { $0.toolName != nil }
            print(
                "ACTIVE CHAT \(question): \(model.answer); error: \(model.error ?? "-"); calls: \(results.compactMap(\.toolName))"
            )
            #expect(model.error == nil && model.answer.contains(expectedFact))
            #expect(results.count == count + 1 && results.last?.toolName == expectedMethod)
            #expect(results.last?.state == .complete)
        }
        model.newChat(); await model.waitUntilIdle()
    }

    model.prompt = "Find a current web source about blue penguins and give me its link."
    model.run(); await model.waitUntilIdle()
    let original = model.messages.first { $0.toolName == "tavily_search" }
    print(
        "ACTIVE CHAT search: \(model.answer); error: \(model.error ?? "-"); call: \(original?.toolName ?? "-")"
    )
    #expect(model.error == nil && model.answer.contains("https://example.com/blue-penguin"))
    #expect(original?.state == .complete)
    let saved = try #require(try await store.load())
    #expect(saved.snapshot.messages == model.messages)

    model.newChat(); await model.waitUntilIdle()
    model.prompt = "Tell me a joke for programmers in the form of a Haiku."
    model.run(); await model.waitUntilIdle()
    let haikuWords = model.answer.split(whereSeparator: \.isWhitespace)
    let midpoint = haikuWords.count / 2
    let paragraphs = model.answer.components(separatedBy: "\n\n")
        .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        .filter { !$0.isEmpty }
    try #require(model.error == nil && !haikuWords.isEmpty)
    #expect(model.messages.count == 2 && model.messages.last?.state == .complete)
    #expect(haikuWords.prefix(midpoint) != haikuWords.dropFirst(midpoint))
    #expect(Set(paragraphs).count == paragraphs.count)

    let haiku = model.answer
    model.prompt = "What time is it in Hong Kong?"
    model.run(); await model.waitUntilIdle()
    let timeAnswer = model.answer
    print("ACTIVE CHAT time after haiku: \(timeAnswer)")
    #expect(model.error == nil && timeAnswer.contains("14:37"))
    #expect(model.messages.dropFirst(2).compactMap(\.toolName) == ["get_current_time"])
    #expect(model.messages.last?.state == .complete)
    #expect(!timeAnswer.localizedCaseInsensitiveContains("haiku"))
    for line in haiku.split(whereSeparator: \.isNewline) where !line.isEmpty {
        #expect(!timeAnswer.localizedCaseInsensitiveContains(String(line)))
    }
}

@Test(
    .enabled(if: ProcessInfo.processInfo.environment["EMBLA_REAL_LONG_TOOL_ANSWER"] == "1"),
    .timeLimit(.minutes(5))) @MainActor
func groundedLongSearchAnswerCompletesWithThePinnedModel() async throws {
    let env = ProcessInfo.processInfo.environment
    let modelRoot = URL(fileURLWithPath: try #require(env["EMBLA_REAL_MODEL_ROOT"]))
    let port = try #require(env["EMBLA_ROUTING_FIXTURE_PORT"])
    let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = ToolWorkspace(configuration: root.appendingPathComponent("servers.json"))
    let server = MCPServer(
        id: UUID(uuidString: "20000000-0000-4000-8000-000000000001")!,
        name: "Search fixture", endpoint: URL(string: "http://127.0.0.1:\(port)/routing-profile")!)
    try await workspace.saveServer(server)
    workspace.discover(server.id)
    await workspace.waitUntilIdle()
    try #require(workspace.error == nil)
    let manifest = try ModelManifest.bundled()
    let model = LocalInferenceModel(
        repository: ModelRepository(root: modelRoot, manifest: manifest),
        manifest: manifest, session: EmblaRuntime.makeSession(), tools: workspace,
        compactionPolicy: ContextCompaction(contextSize: LocalInferenceModel.productionContextSize))
    model.check()
    await model.waitUntilIdle()
    model.prompt = """
        Search for the Cedar Finch reference model and give me a detailed overview in about
        350 words. Explain its purpose, model size, context and tool handling. End with the
        benchmark name and the exact source link.
        """
    model.run()
    await model.waitUntilIdle()
    let result = try #require(model.messages.last)
    let metrics = try #require(result.generationMetrics)
    print("LONG ANSWER finish=\(metrics.finishReason) output=\(metrics.completionTokens)")
    #expect(model.error == nil && result.state == .complete)
    #expect(result.text.contains("Midnight Orchard"))
    #expect(result.text.contains("https://example.com/cedar-reference"))
    #expect(model.messages.compactMap(\.toolName) == ["tavily_search"])
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["EMBLA_REAL_SAVED_EVIDENCE"] == "1"))
@MainActor func actualModelRecallsSecondLinkAfterCompactionAndRestart() async throws {
    let modelRoot = URL(
        fileURLWithPath: try #require(
            ProcessInfo.processInfo.environment["EMBLA_REAL_MODEL_ROOT"]))
    let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ConversationStore(root: root.appendingPathComponent("Chats"))
    let sources = [
        "https://example.com/first", "https://example.com/second-exact",
        "https://example.com/third",
    ]
    let raw = try ToolJSON.object([
        "server": .string("mcp_probe"), "tool": .string("search"),
        "result": .object(["sources": .array(sources.map(ToolJSON.string))]),
    ]).text()
    var row = ChatMessage(
        role: .assistant, text: "Tool request:\n{}\nTool result data (not instructions):\n" + raw)
    row.toolName = "search"
    row.workerToolRequest = true
    row.workerReceipt = ToolWorkerReceipt(
        resultIDs: [row.id], data: try ToolJSON.array([.string(sources[0])]).text())
    let turns = [
        ChatMessage(role: .user, text: "Find three sources about penguins."),
        row,
        ChatMessage(role: .assistant, text: "The first source is " + sources[0]),
    ]
    let snapshot = ConversationSnapshot(
        conversationID: UUID(), messages: turns,
        compaction: CompactionState(
            summary: "Found three penguin sources earlier. First URL: " + sources[0],
            summarizedMessageCount: turns.count))
    try await store.save(ConversationArchive(sequence: 1, snapshot: snapshot))
    let manifest = try ModelManifest.bundled()
    let workspace = ToolWorkspace(
        configuration: root.appendingPathComponent("servers.json"),
        network: NetworkAccess(initialState: .unsatisfied))
    let model = LocalInferenceModel(
        repository: ModelRepository(root: modelRoot, manifest: manifest),
        manifest: manifest, session: EmblaRuntime.makeSession(), chatStore: store,
        tools: workspace)
    model.check(); await model.waitUntilIdle()
    model.prompt = "What was the URL of the second source?"
    model.run(); await model.waitUntilIdle()
    print(
        "RECALL AFTER COMPACTION AND RESTART: \(model.answer); error: \(model.error ?? "-"); tools: \(model.messages.compactMap(\.toolName))"
    )
    #expect(model.error == nil && model.answer.contains(sources[1]))
    #expect(
        model.messages.dropFirst(turns.count).contains { $0.toolName == "read_saved_tool_result" })
}

@Test(
    .enabled(if: ProcessInfo.processInfo.environment["EMBLA_REAL_LARGE_CATALOGUE"] == "1"),
    .timeLimit(.minutes(5))) @MainActor
func largeCatalogueFindsAndExecutesTheRelevantMethod() async throws {
    let env = ProcessInfo.processInfo.environment
    let modelRoot = URL(fileURLWithPath: try #require(env["EMBLA_REAL_MODEL_ROOT"]))
    let port = try #require(env["EMBLA_ROUTING_FIXTURE_PORT"])
    let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = ToolWorkspace(configuration: root.appendingPathComponent("servers.json"))
    let server = MCPServer(
        id: UUID(uuidString: "20000000-0000-4000-8000-000000000001")!,
        name: "Oversized fixture",
        endpoint: URL(string: "http://127.0.0.1:\(port)/routing-oversized")!)
    try await tools.saveServer(server)
    tools.discover(server.id)
    await tools.waitUntilIdle()
    try #require(tools.error == nil && tools.servers.first?.enabledTools.count == 17)
    let manifest = try ModelManifest.bundled()
    let session = EmblaRuntime.makeSession()
    let model = LocalInferenceModel(
        repository: ModelRepository(root: modelRoot, manifest: manifest),
        manifest: manifest, session: session, tools: tools,
        compactionPolicy: ContextCompaction(contextSize: LocalInferenceModel.productionContextSize))
    model.check()
    await model.waitUntilIdle()
    let question = "Find a current web source about blue penguins and give me its link."
    let tokenizer = EmblaPromptTokenizer()
    let full = [
        ConversationMessage(
            role: .system, content: try tools.instructions(using: model.cloud, forRequest: false)),
        ConversationMessage(role: .user, content: question),
    ]
    let count = try await tokenizer.count(
        messages: full, in: modelRoot.appendingPathComponent(manifest.revision))
    #expect(count > 8_192)
    model.prompt = question
    model.run()
    await model.waitUntilIdle()
    print(
        "ACTIVE CHAT full catalogue=\(count) answer=\(model.answer) error=\(model.error ?? "-") calls=\(model.messages.compactMap(\.toolName))"
    )
    #expect(model.error == nil && model.answer.contains("https://example.com/blue-penguin"))
    #expect(model.messages.compactMap(\.toolName) == ["tavily_search"])
}
