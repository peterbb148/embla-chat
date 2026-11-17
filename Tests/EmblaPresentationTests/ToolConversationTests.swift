import CryptoKit
import Foundation
import Testing

@testable import EmblaCore
@testable import EmblaPresentation

/// Deterministic control-flow fixture, never used by the app or claimed as model evidence.
private final class ToolBackendFixture: InferenceBackend, @unchecked Sendable {
    let contextSize = 8_192
    private let lock = NSLock()
    private var position = 0
    private var inputs: [[ConversationMessage]] = []
    private var holdFirst: Bool
    let replies: [String]
    var calls: Int { lock.withLock { position } }
    var contexts: [[ConversationMessage]] { lock.withLock { inputs } }

    init(replies: [String], holdFirst: Bool = false) {
        self.replies = replies
        self.holdFirst = holdFirst
    }
    func release() { lock.withLock { holdFirst = false } }
    func encode(_ messages: [ConversationMessage]) -> [Int] {
        lock.withLock { inputs.append(messages) }
        return [1, 2]
    }
    func reset() {}
    func generate(
        prompt: [Int], options: GenerationOptions,
        emit: @escaping @Sendable (GenerationDelta) -> Bool
    ) -> GenerationMetrics {
        let text = lock.withLock {
            let text = replies[min(position, replies.count - 1)]
            position += 1
            return text
        }
        let metrics = GenerationMetrics(
            finishReason: "stop", promptTokens: 2, completionTokens: 2,
            promptMilliseconds: 1, decodeMilliseconds: 1)
        while lock.withLock({ holdFirst && position == 1 }) {
            guard emit(.reasoning("Synthetic blocked generation")) else { return metrics }
            Thread.sleep(forTimeInterval: 0.005)
        }
        _ = emit(.answer(text))
        return metrics
    }
}

private let readSkillRequest = """
    <tool_call>
    <function=skill__read_skill_file>
    <parameter=path>
    references/fact.txt
    </parameter>
    </function>
    </tool_call>
    """

@MainActor private struct ToolLoopFixture {
    let root: URL
    let backend: ToolBackendFixture
    let model: LocalInferenceModel
    let workspace: ToolWorkspace
    let store: ConversationStore

    init(replies: [String], holdFirst: Bool = false) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let data = Data("Synthetic tool-loop model".utf8)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let manifest = ModelManifest(
            repository: "test/model", revision: "fixture",
            files: [.init(path: "config.json", sizeBytes: Int64(data.count), sha256: hash)])
        let directory = root.appendingPathComponent("Model/fixture")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("config.json"))
        let skill = root.appendingPathComponent("Skills/example-skill")
        try FileManager.default.createDirectory(
            at: skill.appendingPathComponent("references"), withIntermediateDirectories: true)
        try Data(
            "---\nname: example-skill\ndescription: Synthetic control-flow test.\n---\nRead references/fact.txt to answer.\n"
                .utf8
        )
        .write(to: skill.appendingPathComponent("SKILL.md"))
        try Data("BLUE PENGUIN".utf8).write(to: skill.appendingPathComponent("references/fact.txt"))
        workspace = ToolWorkspace(
            store: SkillStore(localRoot: root.appendingPathComponent("Skills")),
            configuration: root.appendingPathComponent("servers.json"))
        backend = ToolBackendFixture(replies: replies, holdFirst: holdFirst)
        let backend = backend
        store = ConversationStore(root: root.appendingPathComponent("Chats"))
        model = LocalInferenceModel(
            repository: ModelRepository(
                root: root.appendingPathComponent("Model"), manifest: manifest),
            manifest: manifest, session: InferenceSession { _, _ in backend }, chatStore: store,
            tools: workspace)
        model.check(); await model.waitUntilIdle()
        workspace.reloadSkills(using: model.cloud); await workspace.waitUntilIdle()
        try workspace.selectSkill("example-skill", using: model.cloud)
    }

    func clean() { try? FileManager.default.removeItem(at: root) }
}

@Test(arguments: [false, true]) @MainActor
func stopOrChangedRegistrationDuringModelWorkPreventsToolDispatch(_ stop: Bool) async throws {
    let fixture = try await ToolLoopFixture(replies: [readSkillRequest], holdFirst: true)
    defer { fixture.clean() }
    fixture.model.prompt = "Synthetic pending-request test"
    fixture.model.run()
    for _ in 0..<1_000 {
        if fixture.backend.calls > 0 { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    try #require(fixture.backend.calls == 1)
    if stop { fixture.model.stop() } else { fixture.workspace.clearSkill() }
    fixture.backend.release()
    await fixture.model.waitUntilIdle()
    #expect(fixture.backend.calls == 1 && !fixture.model.busy)
    #expect(fixture.model.messages.last?.text.contains("Tool result data") == false)
    #expect(fixture.model.messages.last?.state == (stop ? .interrupted : .failed))
}

@Test @MainActor func selectedSkillResourceRunsAutomaticallyAndSavesResultsBeforeContinuation()
    async throws
{
    let fixture = try await ToolLoopFixture(replies: [readSkillRequest, "BLUE PENGUIN"])
    defer { fixture.clean() }
    fixture.model.prompt = "Read the selected skill's fact."
    fixture.model.run(); await fixture.model.waitUntilIdle()
    #expect(fixture.model.error == nil)
    #expect(fixture.model.answer == "BLUE PENGUIN" && fixture.backend.calls == 2)
    #expect(fixture.backend.contexts.last?.last?.content.contains("BLUE PENGUIN") == true)
    let stored = try #require(try await fixture.store.load())
    #expect(
        stored.snapshot.messages.contains {
            $0.toolName == "read_skill_file" && $0.text.contains("BLUE PENGUIN")
        })
    #expect(stored.snapshot.messages.last?.text == "BLUE PENGUIN")
    #expect(fixture.backend.contexts.first?.last?.content.contains("enabled_functions") == true)
    #expect(stored.snapshot.messages.first?.text == "Read the selected skill's fact.")
    #expect(stored.snapshot.messages.allSatisfy { !$0.text.contains("enabled_functions") })
}

@Test @MainActor func unknownOrUnregisteredCallsFailWithoutExecution() async throws {
    let request = readSkillRequest.replacingOccurrences(
        of: "skill__read_skill_file", with: "unregistered__delete_files")
    let fixture = try await ToolLoopFixture(replies: [request])
    defer { fixture.clean() }
    fixture.model.prompt = "Synthetic unknown-tool test"
    fixture.model.run(); await fixture.model.waitUntilIdle()
    #expect(fixture.backend.calls == 1 && fixture.model.error != nil)
    #expect(fixture.model.messages.last?.text.contains("Tool result data") == false)
    #expect(fixture.model.messages.last?.state == .failed)
}

@Test @MainActor func missingSkillResourceKeepsTheActualReadErrorAndDoesNotContinue() async throws {
    let fixture = try await ToolLoopFixture(replies: [readSkillRequest])
    defer { fixture.clean() }
    try FileManager.default.removeItem(
        at: fixture.root.appendingPathComponent("Skills/example-skill/references/fact.txt"))
    fixture.model.prompt = "Synthetic missing-resource test"
    fixture.model.run(); await fixture.model.waitUntilIdle()
    #expect(fixture.model.error != nil && fixture.backend.calls == 1)
    #expect(fixture.model.messages.last?.text.contains("Tool failed:") == true)
    #expect(fixture.model.messages.last?.text.contains("Tool result data") == false)
}

@Test @MainActor func repeatedToolRequestsStopAtTheExplicitLoopLimit() async throws {
    let fixture = try await ToolLoopFixture(replies: [readSkillRequest])
    defer { fixture.clean() }
    fixture.model.prompt = "Synthetic bounded-loop test"
    fixture.model.run(); await fixture.model.waitUntilIdle()
    #expect(fixture.backend.calls == 5 && fixture.model.error != nil)
    #expect(fixture.model.messages.filter { $0.toolName != nil }.count == 4)
}
