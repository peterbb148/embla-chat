import Foundation
import Testing

import EmblaCore
import EmblaRuntime
@testable import EmblaPresentation

@Test(
    .enabled(if: ProcessInfo.processInfo.environment["EMBLA_REAL_WORKER"] == "1"),
    .timeLimit(.minutes(10))) @MainActor
func workerRoutesNaturalSearchAndTimeFollowUpsInProduction() async throws {
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
        }, tools: workspace)
    model.check(); await model.waitUntilIdle()
    for server in [time, search] {
        try await workspace.saveServer(server)
        workspace.discover(server.id)
        await workspace.waitUntilIdle()
        try #require(workspace.error == nil)

        model.toolConfigurationChanged()
        await model.waitForContextUsage()
        if case .ready(let usage) = model.contextUsage {
            print("PRODUCTION WORKER fresh context: \(usage.inputTokens)/\(usage.capacity)")
            #expect(usage.inputTokens < 600)
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
                "PRODUCTION WORKER \(question): \(model.answer); error: \(model.error ?? "-"); calls: \(results.compactMap(\.toolName))"
            )
            #expect(model.error == nil && model.answer.contains(expectedFact))
            #expect(results.count == count + 1 && results.last?.toolName == expectedMethod)
            #expect(results.last?.workerReceipt != nil)
        }
        model.newChat(); await model.waitUntilIdle()
    }

    model.prompt = "Find a current web source about blue penguins and give me its link."
    model.run(); await model.waitUntilIdle()
    let original = model.messages.first { $0.toolName == "tavily_search" }
    print(
        "PRODUCTION WORKER search: \(model.answer); error: \(model.error ?? "-"); call: \(original?.toolName ?? "-")"
    )
    #expect(model.error == nil && model.answer.contains("https://example.com/blue-penguin"))
    #expect(original?.workerReceipt != nil)
    let saved = try #require(try await store.load())
    #expect(saved.snapshot.messages == model.messages)
}
