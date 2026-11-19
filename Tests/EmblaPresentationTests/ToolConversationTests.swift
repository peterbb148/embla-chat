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
    private var holdFinal = false
    private var holdAfterOutput = false
    private var didEmitAnswer = false
    private var answerFinish = "stop"
    let replies: [String]
    private let countCharacters: Bool
    private var holdSummary: Bool
    private var summaryCount = 0
    private var summaryText: String
    private var summaryFinish: String
    private var generated: [(messages: [ConversationMessage], limit: Int)] = []
    var summaryCalls: Int { lock.withLock { summaryCount } }
    var generations: [(messages: [ConversationMessage], limit: Int)] { lock.withLock { generated } }
    var calls: Int { lock.withLock { position } }
    var contexts: [[ConversationMessage]] { lock.withLock { inputs } }

    init(
        replies: [String], holdFirst: Bool = false, countCharacters: Bool = false,
        holdSummary: Bool = false, summaryText: String = "BLUE PENGUIN — https://example.com/fact",
        summaryFinish: String = "stop"
    ) {
        self.replies = replies
        self.holdFirst = holdFirst
        self.countCharacters = countCharacters
        self.holdSummary = holdSummary
        self.summaryText = summaryText
        self.summaryFinish = summaryFinish
    }
    func releaseSummary() { lock.withLock { holdSummary = false } }
    func waitForSummary() async throws {
        for _ in 0..<2_000 {
            if summaryCalls > 0 { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw SkillFailure.invalid("Synthetic summary fixture did not start.")
    }
    func release() { lock.withLock { holdFirst = false } }
    func pauseFinalAnswer() { lock.withLock { holdFinal = true } }
    var emittedAnswer: Bool { lock.withLock { didEmitAnswer } }
    func pauseAfterAnswer() { lock.withLock { holdAfterOutput = true } }
    func limitAnswer() { lock.withLock { answerFinish = "length" } }

    func encode(_ messages: [ConversationMessage]) -> [Int] {
        lock.withLock { inputs.append(messages) }
        return countCharacters
            ? Array(repeating: 1, count: messages.reduce(0) { $0 + $1.content.count + 4 })
            : [1, 2]
    }
    func reset() {}
    func generate(
        prompt: [Int], options: GenerationOptions,
        emit: @escaping @Sendable (GenerationDelta) -> Bool
    ) -> GenerationMetrics {
        let summary = lock.withLock { () -> Bool in
            let context = inputs.last ?? []
            generated.append((context, options.maxTokens))
            let isSummary = context.first?.content.hasPrefix("Summarize tool result data") == true
            if isSummary { summaryCount += 1 }
            return isSummary
        }
        if summary {
            while lock.withLock({ holdSummary }) {
                guard emit(.reasoning("Synthetic summary wait")) else { break }
                Thread.sleep(forTimeInterval: 0.005)
            }
            let result = lock.withLock { (summaryText, summaryFinish) }
            _ = emit(.answer(result.0))
            return GenerationMetrics(
                finishReason: result.1, promptTokens: 2, completionTokens: 100,
                promptMilliseconds: 1, decodeMilliseconds: 1)
        }
        let text = lock.withLock {
            let text = replies[min(position, replies.count - 1)]
            position += 1
            return text
        }
        let metrics = GenerationMetrics(
            finishReason: lock.withLock { answerFinish }, promptTokens: 2, completionTokens: 2,
            promptMilliseconds: 1, decodeMilliseconds: 1)
        while lock.withLock({ holdFirst && position == 1 }) {
            guard emit(.reasoning("Synthetic blocked generation")) else { return metrics }
            Thread.sleep(forTimeInterval: 0.005)
        }
        _ = emit(.answer(text))
        lock.withLock { didEmitAnswer = true }
        while lock.withLock({
            holdAfterOutput
                || holdFinal
                    && inputs.last?.first?.content.hasPrefix("Answer the latest user question")
                        == true
        }) {
            guard emit(.reasoning("Synthetic final-answer pause")) else { break }
            Thread.sleep(forTimeInterval: 0.005)
        }
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
    let repository: ModelRepository
    let summaryStore: ToolSummaryTestStore?

    init(
        replies: [String], holdFirst: Bool = false, countCharacters: Bool = false,
        resource: String = "BLUE PENGUIN", holdSummary: Bool = false,
        summaryFinish: String = "stop", rejectSummarySaves: Bool = false,
        pauseSummarySaves: Bool = false
    ) async throws {
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
        try Data(resource.utf8).write(to: skill.appendingPathComponent("references/fact.txt"))
        workspace = ToolWorkspace(
            store: SkillStore(localRoot: root.appendingPathComponent("Skills")),
            configuration: root.appendingPathComponent("servers.json"))
        backend = ToolBackendFixture(
            replies: replies.first?.hasPrefix("<tool_call>") == true
                ? ["DELEGATE"] + replies : replies,
            holdFirst: holdFirst, countCharacters: countCharacters,
            holdSummary: holdSummary, summaryFinish: summaryFinish)
        let backend = backend
        store = ConversationStore(root: root.appendingPathComponent("Chats"))
        repository = ModelRepository(root: root.appendingPathComponent("Model"), manifest: manifest)
        summaryStore =
            rejectSummarySaves || pauseSummarySaves
            ? ToolSummaryTestStore(wrapped: store, reject: rejectSummarySaves) : nil
        let target: any ConversationStoring
        if let summaryStore { target = summaryStore } else { target = store }
        model = LocalInferenceModel(
            repository: repository,
            manifest: manifest, session: InferenceSession { _, _ in backend }, chatStore: target,
            tools: workspace)
        model.check(); await model.waitUntilIdle()
        workspace.reloadSkills(using: model.cloud); await workspace.waitUntilIdle()
        try await workspace.selectSkill("example-skill", using: model.cloud)
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
    #expect(fixture.model.answer == "BLUE PENGUIN" && fixture.backend.calls == 4)
    #expect(fixture.model.averageDecodeTokensPerSecond == 1_000)
    #expect(fixture.model.messages.filter { $0.generationMetrics != nil }.count == 1)
    #expect(fixture.backend.contexts.last?.last?.content.contains("BLUE PENGUIN") == true)
    let stored = try #require(try await fixture.store.load())
    #expect(
        stored.snapshot.messages.contains {
            $0.toolName == "read_skill_file" && $0.text.contains("BLUE PENGUIN")
        })
    let tool = try #require(stored.snapshot.messages.first { $0.toolName == "read_skill_file" })
    let receipt = try #require(tool.workerReceipt)
    #expect(receipt.resultIDs == [tool.id])
    #expect(receipt.promptData.contains("BLUE PENGUIN"))
    #expect(receipt.promptData.contains(#""server":"skill""#))
    #expect(receipt.promptData.contains("references/fact.txt"))
    #expect(receipt.promptData(replacingSummary: "Local evidence").contains("read_skill_file"))
    #expect(!receipt.promptData.contains("Selected skill folder"))
    #expect(stored.snapshot.messages.last?.text == "BLUE PENGUIN")
    #expect(
        fixture.backend.contexts.first?.first?.content.contains("<tools>") == false
            && fixture.backend.contexts.contains { $0.first?.content.contains("<tools>") == true })
    #expect(stored.snapshot.messages.first?.text == "Read the selected skill's fact.")
    #expect(stored.snapshot.messages.allSatisfy { !$0.text.contains("enabled_functions") })
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true]) @MainActor
func finalWorkerAnswerKeepsLiteralDelegateTextAndSurvivesStop(_ stop: Bool) async throws {
    let expected = "The retrieved text says DELEGATE."
    let fixture = try await ToolLoopFixture(replies: [readSkillRequest, expected])
    defer { fixture.clean() }
    if stop { fixture.backend.pauseFinalAnswer() }
    fixture.model.prompt = "Quote the retrieved fact."
    fixture.model.run()
    if stop {
        for _ in 0..<1_000 {
            if fixture.model.answer == expected { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        fixture.model.stop()
    }
    await fixture.model.waitUntilIdle()
    let saved = try #require(try await fixture.store.load())
    #expect(saved.snapshot.messages.last?.text == expected)
    #expect(saved.snapshot.messages.last?.state == (stop ? .interrupted : .complete))
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true]) @MainActor
func stoppedRoutingKeepsOrdinaryTextButHidesControlSignals(_ signal: Bool) async throws {
    let output = signal ? "DELE" : "An ordinary partial answer."
    let fixture = try await ToolLoopFixture(replies: [output])
    defer { fixture.clean() }
    fixture.backend.pauseAfterAnswer()
    fixture.model.prompt = "An ordinary request."
    fixture.model.run()
    for _ in 0..<1_000 {
        if signal ? fixture.backend.emittedAnswer : fixture.model.answer == output { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(fixture.backend.emittedAnswer)
    #expect(fixture.model.answer == (signal ? "" : output))
    fixture.model.stop()
    await fixture.model.waitUntilIdle()
    let saved = try #require(try await fixture.store.load())
    #expect(saved.snapshot.messages.last?.text == (signal ? "" : output))
    #expect(saved.snapshot.messages.last?.state == .interrupted)
}

@Test(arguments: ["Ordinary text within the output limit.", "DELEGATE"]) @MainActor
func limitedDirectAnswerIsSavedButLimitedHandoffCannotExecute(_ text: String) async throws {
    let fixture = try await ToolLoopFixture(replies: [text])
    defer { fixture.clean() }
    fixture.backend.limitAnswer()
    fixture.model.prompt = "Answer my request."
    fixture.model.run()
    await fixture.model.waitUntilIdle()
    let saved = try #require(try await fixture.store.load())
    #expect(saved.snapshot.messages.allSatisfy { $0.toolName == nil })
    if text == "DELEGATE" {
        #expect(fixture.model.error != nil && saved.snapshot.messages.last?.text == "")
    } else {
        #expect(fixture.model.error == nil && saved.snapshot.messages.last?.text == text)
        #expect(saved.snapshot.messages.last?.state == .limited)
    }
}

@Test @MainActor func unknownOrUnregisteredCallsFailWithoutExecution() async throws {
    let request = readSkillRequest.replacingOccurrences(
        of: "skill__read_skill_file", with: "unregistered__delete_files")
    let fixture = try await ToolLoopFixture(replies: [request])
    defer { fixture.clean() }
    fixture.model.prompt = "Synthetic unknown-tool test"
    fixture.model.run(); await fixture.model.waitUntilIdle()
    #expect(fixture.backend.calls == 2 && fixture.model.error != nil)
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
    #expect(fixture.model.error != nil && fixture.backend.calls == 2)
    #expect(fixture.model.messages.last?.text.contains("Tool failed:") == true)
    #expect(fixture.model.messages.last?.text.contains("Tool result data") == false)
}

@Test @MainActor func repeatedToolRequestsStopAtTheExplicitLoopLimit() async throws {
    let fixture = try await ToolLoopFixture(replies: [readSkillRequest])
    defer { fixture.clean() }
    fixture.model.prompt = "Synthetic bounded-loop test"
    fixture.model.run(); await fixture.model.waitUntilIdle()
    #expect(fixture.backend.calls == 6 && fixture.model.error != nil)
    #expect(fixture.model.messages.filter { $0.toolName != nil }.count == 4)
}

private enum SummarySaveFixtureError: Error { case rejected }
private actor ToolSummaryTestStore: ConversationStoring {
    let wrapped: ConversationStore
    let reject: Bool
    private(set) var summaryWrites = 0
    private var waiting = false
    private var paused = true
    private var continuation: CheckedContinuation<Void, Never>?
    init(wrapped: ConversationStore, reject: Bool) { self.wrapped = wrapped; self.reject = reject }
    func load() async throws -> ConversationArchive? { try await wrapped.load() }
    func save(_ archive: ConversationArchive) async throws {
        if archive.snapshot.messages.contains(where: { $0.toolResultSummary != nil }) {
            summaryWrites += 1
            if reject { throw SummarySaveFixtureError.rejected }
            if paused {
                waiting = true
                await withCheckedContinuation { continuation = $0 }
            }
        }
        try await wrapped.save(archive)
    }
    func waitForSummarySave() async throws {
        for _ in 0..<2_000 {
            if waiting { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw SkillFailure.invalid("Synthetic summary save did not start.")
    }
    func release() {
        paused = false
        continuation?.resume()
        continuation = nil
    }
}

private let largeToolEvidence =
    String(
        repeating: "Synthetic source material with exact identifiers and source URLs. ", count: 250)
    + " BLUE PENGUIN https://example.com/fact"

@Test(.timeLimit(.minutes(1))) @MainActor
func oversizedToolResultUsesBoundedLocalChunksAndPersistsRawOutputAndSummary() async throws {
    let fixture = try await ToolLoopFixture(
        replies: [readSkillRequest, "BLUE PENGUIN https://example.com/fact"],
        countCharacters: true, resource: largeToolEvidence)
    defer { fixture.clean() }
    fixture.model.prompt = "Read the selected skill's fact and cite its source."
    fixture.model.run(); await fixture.model.waitUntilIdle()
    #expect(fixture.model.error == nil)
    #expect(fixture.model.answer.contains("BLUE PENGUIN"))
    #expect(fixture.backend.calls == 4 && fixture.backend.summaryCalls > 1)
    let tool = try #require(fixture.model.messages.first(where: { $0.toolName != nil }))
    #expect(tool.text.contains(largeToolEvidence))
    #expect(tool.toolResultSummary?.contains("https://example.com/fact") == true)
    #expect(tool.inferenceContent.contains("summarized locally"))
    let saved = try #require(try await fixture.store.load())
    #expect(saved.snapshot.messages == fixture.model.messages)
    #expect(fixture.model.averageDecodeTokensPerSecond == 1_000)
    #expect(fixture.model.messages.filter { $0.generationMetrics != nil }.count == 1)
    for generation in fixture.backend.generations {
        let tokens = generation.messages.reduce(0) { $0 + $1.content.count + 4 }
        #expect(tokens + generation.limit < 8_192)
    }
    #expect(fixture.backend.generations.last?.messages.last?.content.contains("summary") == true)
    #expect(
        fixture.backend.generations.last?.messages.last?.content.contains(largeToolEvidence)
            == false)
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true]) @MainActor
func stoppedOrIncompleteToolSummaryRestartsFromSavedResultWithoutReadingTheToolAgain(_ stop: Bool)
    async throws
{
    let fixture = try await ToolLoopFixture(
        replies: [readSkillRequest], countCharacters: true, resource: largeToolEvidence,
        holdSummary: stop, summaryFinish: stop ? "stop" : "length")
    defer { fixture.clean() }
    fixture.model.prompt = "Read the fact."
    fixture.model.run()
    if stop {
        try await fixture.backend.waitForSummary()
        fixture.model.stop()
        fixture.backend.releaseSummary()
    }
    await fixture.model.waitUntilIdle()
    let original = try #require(try await fixture.store.load())
    let raw = try #require(original.snapshot.messages.first(where: { $0.toolName != nil }))
    #expect(raw.text.contains(largeToolEvidence) && raw.toolResultSummary == nil)
    try FileManager.default.removeItem(
        at: fixture.root.appendingPathComponent("Skills/example-skill/references/fact.txt"))
    let recall = """
        <tool_call>
        <function=chat__read_saved_tool_result>
        <parameter=ordinal>
        1
        </parameter>
        </function>
        </tool_call>
        """
    let backend = ToolBackendFixture(
        replies: ["DELEGATE", recall, "BLUE PENGUIN"], countCharacters: true)
    let reopened = LocalInferenceModel(
        repository: fixture.repository, manifest: try #require(fixture.model.manifest),
        session: InferenceSession { _, _ in backend }, chatStore: fixture.store,
        tools: fixture.workspace)
    reopened.check(); await reopened.waitUntilIdle()
    reopened.prompt = "Continue using the already returned result."
    reopened.run(); await reopened.waitUntilIdle()
    #expect(reopened.error == nil && reopened.answer == "BLUE PENGUIN")
    #expect(backend.calls == 4 && backend.summaryCalls > 1)
    #expect(reopened.messages.first(where: { $0.id == raw.id })?.text == raw.text)
    #expect(reopened.messages.filter { $0.toolName == "read_skill_file" }.count == 1)
    #expect(
        reopened.messages.last(where: { $0.toolName == "read_saved_tool_result" })?.workerReceipt
            != nil)

}

@Test(.timeLimit(.minutes(1))) @MainActor
func failedToolSummarySaveDoesNotPublishAnUncommittedProjection() async throws {
    let fixture = try await ToolLoopFixture(
        replies: [readSkillRequest], countCharacters: true, resource: largeToolEvidence,
        rejectSummarySaves: true)
    defer { fixture.clean() }
    fixture.model.prompt = "Read the fact."
    fixture.model.run(); await fixture.model.waitUntilIdle()
    #expect(fixture.model.error != nil)
    let writer = try #require(fixture.summaryStore)
    #expect(await writer.summaryWrites > 0)
    #expect(fixture.model.messages.allSatisfy { $0.toolResultSummary == nil })
    let saved = try #require(try await fixture.store.load())
    #expect(saved.snapshot.messages.allSatisfy { $0.toolResultSummary == nil })
    #expect(saved.snapshot.messages.contains { $0.text.contains(largeToolEvidence) })
}

@Test(.timeLimit(.minutes(1))) @MainActor
func backgroundDuringSummaryCommitCannotStartALateContinuation() async throws {
    let fixture = try await ToolLoopFixture(
        replies: [readSkillRequest, "This continuation must never run"],
        countCharacters: true, resource: largeToolEvidence, pauseSummarySaves: true)
    defer { fixture.clean() }
    fixture.model.prompt = "Read the fact."
    fixture.model.run()
    let writer = try #require(fixture.summaryStore)
    try await writer.waitForSummarySave()
    #expect(fixture.backend.calls == 2 && !fixture.model.canNavigateChats)
    fixture.model.enteredBackground()
    await writer.release()
    await fixture.model.waitUntilIdle()
    #expect(fixture.backend.calls == 2)
    #expect(!fixture.model.loaded && !fixture.model.busy)
    #expect(fixture.model.messages.contains { $0.toolResultSummary != nil })
}

@Test(.timeLimit(.minutes(1))) @MainActor
func newChatDuringToolSummaryDrainsWorkerWithoutPublishingIntoTheNewChat() async throws {
    let fixture = try await ToolLoopFixture(
        replies: [readSkillRequest, "This continuation must never run"],
        countCharacters: true, resource: largeToolEvidence, holdSummary: true)
    defer { fixture.clean() }
    fixture.model.prompt = "Read the fact."
    fixture.model.run()
    try await fixture.backend.waitForSummary()
    let originalID = fixture.model.conversationID
    #expect(fixture.model.canNavigateChats)
    fixture.model.newChat()
    fixture.backend.releaseSummary()
    await fixture.model.waitUntilIdle()
    #expect(fixture.backend.calls == 2)
    #expect(fixture.model.messages.isEmpty && fixture.model.conversationID != originalID)
    let saved = try #require(fixture.model.history.first(where: { $0.id == originalID }))
    #expect(saved.snapshot.messages.allSatisfy { $0.toolResultSummary == nil })
    #expect(saved.snapshot.messages.contains { $0.text.contains(largeToolEvidence) })
}

private func fixtureContextTokens(_ messages: [ConversationMessage]) -> Int {
    messages.reduce(0) { $0 + $1.content.count + 4 }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func aSecondLargeResultCanReduceEarlierRawResultsInTheSameToolTurn() async throws {
    let fixture = try await ToolLoopFixture(
        replies: [readSkillRequest, readSkillRequest, "BLUE PENGUIN"], countCharacters: true)
    defer { fixture.clean() }
    let question = "Read the selected file twice, then report the fact."
    try await fixture.workspace.prepare(using: fixture.model.cloud)
    let base = ContextCompaction().context(
        transcript: [ConversationMessage(role: .user, content: question)], state: .init(),
        instructions: try fixture.workspace.instructions(using: fixture.model.cloud),
        requestContext: try fixture.workspace.requestContext(using: fixture.model.cloud))
    func firstContext(_ resource: String) throws -> [ConversationMessage] {
        let data = try ToolJSON.object([
            "server": .string("skill"), "tool": .string("read_skill_file"),
            "result": .object(["text": .string(resource)]),
        ]).text()
        return base + [
            ConversationMessage(role: .assistant, content: readSkillRequest),
            ConversationMessage(
                role: .user, content: "<tool_response>\n" + data + "\n</tool_response>"),
        ]
    }
    let suffix = " BLUE PENGUIN https://example.com/fact"
    let length = 7_424 - 64 - (try fixtureContextTokens(firstContext("")))
    try #require(length > suffix.count + 128)
    let source = String(repeating: "x", count: length - suffix.count) + suffix
    #expect(try fixtureContextTokens(firstContext(source)) == 7_360)
    try Data(source.utf8).write(
        to: fixture.root.appendingPathComponent("Skills/example-skill/references/fact.txt"))
    fixture.model.prompt = question
    fixture.model.run(); await fixture.model.waitUntilIdle()
    #expect(fixture.model.error == nil && fixture.model.answer == "BLUE PENGUIN")
    #expect(fixture.backend.calls == 5)
    let results = fixture.model.messages.filter { $0.toolName != nil }
    #expect(results.count == 2 && results.allSatisfy { $0.toolResultSummary != nil })
    #expect(results.allSatisfy { $0.text.contains(source) })
    for generation in fixture.backend.generations {
        #expect(fixtureContextTokens(generation.messages) + generation.limit < 8_192)
    }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func savedResultsSmallerThanTheSummaryCeilingStillReduceToTheAvailableBudget() async throws {
    let fixture = try await ToolLoopFixture(replies: ["unused"], countCharacters: true)
    defer { fixture.clean() }
    try await fixture.workspace.prepare(using: fixture.model.cloud)
    var result = ChatMessage(role: .assistant, text: String(repeating: "r", count: 1_200))
    result.toolName = "synthetic_lookup"
    let user = ChatMessage(role: .user, text: "Earlier lookup")
    var empty = result
    empty.toolResultSummary = ""
    func context(_ question: String) throws -> [ConversationMessage] {
        ContextCompaction().context(
            transcript: [
                ConversationMessage(role: .user, content: user.text),
                ConversationMessage(role: .assistant, content: empty.inferenceContent),
                ConversationMessage(role: .user, content: question),
            ], state: .init(),
            instructions: try fixture.workspace.routingInstructions(using: fixture.model.cloud))
    }
    let prefix = "Use the saved result. "
    let padding = 6_400 - (try fixtureContextTokens(context(prefix)))
    try #require(padding > 0)
    let question = prefix + String(repeating: "q", count: padding)
    #expect(try fixtureContextTokens(context(question)) == 6_400)
    #expect(result.text.count + 4 < 1_536)
    let previous = try #require(try await fixture.store.load())
    try await fixture.store.save(
        ConversationArchive(
            sequence: previous.sequence + 1,
            snapshot: ConversationSnapshot(
                conversationID: UUID(), messages: [user, result], compaction: .init())))
    let backend = ToolBackendFixture(replies: ["BLUE PENGUIN"], countCharacters: true)
    let model = LocalInferenceModel(
        repository: fixture.repository, manifest: try #require(fixture.model.manifest),
        session: InferenceSession { _, _ in backend }, chatStore: fixture.store,
        tools: fixture.workspace)
    model.check(); await model.waitUntilIdle()
    model.prompt = question
    model.run(); await model.waitUntilIdle()
    #expect(model.error == nil && model.answer == "BLUE PENGUIN")
    #expect(backend.calls == 1 && backend.summaryCalls > 0)
    #expect(model.messages.first(where: { $0.id == result.id })?.text == result.text)
    #expect(model.messages.first(where: { $0.id == result.id })?.toolResultSummary != nil)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func savedToolResultCanFitTheReplyButStillNeedReductionForHistoryCompaction() async throws {
    let fixture = try await ToolLoopFixture(replies: ["unused"], countCharacters: true)
    defer { fixture.clean() }
    var result = ChatMessage(role: .assistant, text: String(repeating: "r", count: 6_800))
    result.toolName = "synthetic_lookup"
    var history = [ChatMessage(role: .user, text: "Earlier source"), result]
    for _ in 0..<3 {
        history += [
            ChatMessage(role: .user, text: "Follow-up"),
            ChatMessage(role: .assistant, text: "Noted"),
        ]
    }
    let question = "Continue using the saved facts."
    let transcript =
        history.map { ConversationMessage(role: $0.role, content: $0.text) }
        + [ConversationMessage(role: .user, content: question)]
    let plan = try ContextCompaction().plan(transcript: transcript, state: .init())
    #expect(fixtureContextTokens(transcript) < 7_424)
    #expect(fixtureContextTokens(plan.messages) + 1_536 >= 8_192)
    let previous = try #require(try await fixture.store.load())
    try await fixture.store.save(
        ConversationArchive(
            sequence: previous.sequence + 1,
            snapshot: ConversationSnapshot(
                conversationID: UUID(), messages: history, compaction: .init())))
    let backend = ToolBackendFixture(
        replies: ["Memory: BLUE PENGUIN", "BLUE PENGUIN"], countCharacters: true)
    let model = LocalInferenceModel(
        repository: fixture.repository, manifest: try #require(fixture.model.manifest),
        session: InferenceSession { _, _ in backend }, chatStore: fixture.store,
        tools: ToolWorkspace(store: nil))
    model.check(); await model.waitUntilIdle()
    model.prompt = question
    model.run(); await model.waitUntilIdle()
    #expect(model.error == nil && model.answer == "BLUE PENGUIN")
    #expect(backend.summaryCalls > 0 && model.compaction.summarizedMessageCount > 0)
    #expect(model.messages.first(where: { $0.id == result.id })?.text == result.text)
    #expect(model.messages.first(where: { $0.id == result.id })?.toolResultSummary != nil)
}

#if os(macOS)
    private final class SummaryNetworkFixture {
        let process = Process()
        let port: Int
        init() throws {
            let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Fixtures/mcp_server.py")
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", path.path]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            port = try #require(
                Int(
                    String(
                        decoding: pipe.fileHandleForReading.availableData, as: UTF8.self
                    ).trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        func stop() { if process.isRunning { process.terminate(); process.waitUntilExit() } }
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func largeRequestArgumentsAreReducedAfterASuccessfulCall() async throws {
        let remote = try SummaryNetworkFixture()
        defer { remote.stop() }
        let query = String(repeating: "large but valid query ", count: 80)
        let call = """
            <tool_call>
            <function=mcp_20000000__tavily_search>
            <parameter=query>
            \(query)
            </parameter>
            </function>
            </tool_call>
            """
        let fixture = try await ToolLoopFixture(
            replies: [call, "BLUE PENGUIN"], countCharacters: true)
        defer { fixture.clean() }
        let server = MCPServer(
            id: UUID(uuidString: "20000000-0000-4000-8000-000000000001")!,
            name: "Synthetic search",
            endpoint: URL(string: "http://127.0.0.1:\(remote.port)/routing-search")!)
        try await fixture.workspace.saveServer(server)
        fixture.workspace.discover(server.id)
        await fixture.workspace.waitUntilIdle()
        try #require(fixture.workspace.error == nil)
        fixture.model.prompt = "Find a source."
        fixture.model.run()
        await fixture.model.waitUntilIdle()

        #expect(fixture.model.error == nil && fixture.model.answer == "BLUE PENGUIN")
        let records = fixture.model.messages.filter { $0.toolName == "tavily_search" }
        #expect(records.count == 1)
        let record = try #require(records.first)
        let receipt = try #require(record.workerReceipt)
        #expect(record.text.contains(query))
        #expect(receipt.promptData.contains("tavily_search"))
        #expect(!receipt.promptData.contains(query))
        #expect(fixture.backend.summaryCalls > 0)
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func pagingBetweenTwoCallsPreservesHistoryResultsAndBudgets() async throws {
        let remote = try SummaryNetworkFixture()
        defer { remote.stop() }
        let clarification = "Which IP address should I look up?"
        func call(_ name: String, argument: String = "") -> String {
            "<tool_call>\n<function=\(name)>\n\(argument)</function>\n</tool_call>"
        }
        func parameter(_ name: String, _ value: String) -> String {
            "<parameter=\(name)>\n\(value)\n</parameter>\n"
        }
        let fixture = try await ToolLoopFixture(
            replies: [
                "I will remember the reference.", "DELEGATE",
                call("catalog__open", argument: parameter("ordinal", "2")),
                "Listing timezone names does not answer the request.",
                call("catalog__previous"),
                call("catalog__open", argument: parameter("ordinal", "1")),
                call(
                    "mcp_10000000__get_current_time",
                    argument: parameter("timezone", "Asia/Tokyo")),
                call("catalog__browse"), call("catalog__browse"),
                call("catalog__open", argument: parameter("ordinal", "20")),
                call("mcp_20000000__tavily_search", argument: parameter("query", "blue penguins")),
                "The facts are ready.", "Tokyo is 15:37. https://example.com/blue-penguin",
                "DELEGATE",
                call("catalog__open", argument: parameter("ordinal", "3")),
                call("catalog__clarify", argument: parameter("question", clarification)),
            ], countCharacters: true)
        defer { fixture.clean() }

        let fixtureServers = [
            ("10000000-0000-4000-8000-000000000001", "/routing-time"),
            ("20000000-0000-4000-8000-000000000001", "/routing-oversized"),
        ]
        for (identifier, path) in fixtureServers {
            let server = MCPServer(
                id: UUID(uuidString: identifier)!, name: path,
                endpoint: URL(string: "http://127.0.0.1:\(remote.port)\(path)")!)
            try await fixture.workspace.saveServer(server)
            fixture.workspace.discover(server.id)
            await fixture.workspace.waitUntilIdle()
            try #require(fixture.workspace.error == nil)
        }
        fixture.model.prompt = "Remember BOX-142."
        fixture.model.run()
        await fixture.model.waitUntilIdle()
        fixture.model.prompt = "Find Tokyo time and a current source about blue penguins."
        fixture.model.run()
        await fixture.model.waitUntilIdle()

        #expect(fixture.model.error == nil)
        let saved = try #require(try await fixture.store.load())
        let results = saved.snapshot.messages.filter { $0.toolName != nil }
        #expect(results.compactMap(\.toolName) == ["get_current_time", "tavily_search"])
        #expect(results.first?.text.contains("15:37") == true)
        #expect(results.last?.text.contains("https://example.com/blue-penguin") == true)
        #expect(results.last?.workerReceipt?.resultIDs == results.map(\.id))
        #expect(!saved.snapshot.messages.contains { $0.text.contains("catalog__") })
        #expect(!saved.snapshot.messages.contains { $0.text.contains("Listing timezone names") })
        let pagedAfterFirstCall = fixture.backend.generations.filter { generation in
            generation.messages.contains { $0.content.contains("Enabled catalogue page") }
                && generation.messages.contains { $0.content.contains("<tool_response>") }
        }
        #expect(pagedAfterFirstCall.count >= 4)
        for generation in pagedAfterFirstCall {
            #expect(generation.messages.contains { $0.content.contains("BOX-142") })
            #expect(generation.messages.contains { $0.content.contains("15:37") })
            #expect(fixtureContextTokens(generation.messages) + generation.limit <= 8_192)
        }
        fixture.model.prompt = "What is the current local time for this IP address?"
        fixture.model.run()
        await fixture.model.waitUntilIdle()
        #expect(fixture.model.error == nil)
        #expect(fixture.model.answer == clarification)
        let clarified = try #require(try await fixture.store.load())
        #expect(clarified.snapshot.messages.filter { $0.toolName != nil } == results)
        #expect(clarified.snapshot.messages.last?.text == clarification)
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func networkLossAndReconnectDuringAtomicSummarySaveRemainLatched() async throws {
        let remote = try SummaryNetworkFixture(); defer { remote.stop() }
        let fixture = try await ToolLoopFixture(
            replies: [readSkillRequest, "This continuation must never run"],
            countCharacters: true, resource: largeToolEvidence, pauseSummarySaves: true)
        defer { fixture.clean() }
        try await fixture.workspace.saveServer(
            MCPServer(
                name: "Synthetic network dependency",
                endpoint: URL(string: "http://127.0.0.1:\(remote.port)/json")!,
                enabledTools: ["echo"]))
        fixture.model.connectivityChanged()
        fixture.model.prompt = "Read the fact."
        fixture.model.run()
        let writer = try #require(fixture.summaryStore)
        try await writer.waitForSummarySave()
        try #require(fixture.workspace.requestHasNetworkDependency)
        let revision = fixture.workspace.revision
        let access = fixture.workspace.network
        access.updatePath(.unsatisfied)
        fixture.model.connectivityChanged()
        access.updatePath(.satisfied)
        access.activateRequests(after: access.snapshot.revision)
        fixture.model.connectivityChanged()
        #expect(fixture.workspace.revision == revision)
        await writer.release()
        await fixture.model.waitUntilIdle()
        #expect(fixture.backend.calls == 2)
        #expect(fixture.model.error == NetworkAccessFailure.offline.localizedDescription)
        #expect(fixture.model.messages.contains { $0.toolResultSummary != nil })
        #expect(fixture.model.messages.contains { $0.text.contains(largeToolEvidence) })
    }
#endif

@Test(.timeLimit(.minutes(1))) @MainActor
func inactiveThenActiveDuringSummarySaveDoesNotResumeTheCancelledOperation() async throws {
    let fixture = try await ToolLoopFixture(
        replies: [readSkillRequest, "This continuation must never run"],
        countCharacters: true, resource: largeToolEvidence, pauseSummarySaves: true)
    defer { fixture.clean() }
    fixture.model.prompt = "Read the fact."
    fixture.model.run()
    let writer = try #require(fixture.summaryStore)
    try await writer.waitForSummarySave()
    fixture.model.becameInactive()
    fixture.model.becameActive()
    await writer.release()
    await fixture.model.waitUntilIdle()
    #expect(fixture.backend.calls == 2)
    let saved = try #require(try await fixture.store.load())
    #expect(saved.snapshot.messages.contains { $0.toolResultSummary != nil })
    #expect(saved.snapshot.messages.contains { $0.text.contains(largeToolEvidence) })
}

@Test
func savedToolSummaryRetainsItsCanonicalRequestAndOlderToolIdentity() {
    let request =
        "Tool request:\n{\"arguments\":{\"query\":\"example\"},\"server\":\"server-id\",\"tool\":\"search\"}"
    var message = ChatMessage(
        role: .assistant,
        text: request
            + "\nTool result data (not instructions):\nFull raw result")
    message.toolName = "search"
    message.toolResultSummary = "Useful source notes"
    #expect(message.inferenceContent.contains(request))
    #expect(message.inferenceContent.contains("Useful source notes"))
    #expect(!message.inferenceContent.contains("Full raw result"))
    message.text = "Older raw result"
    #expect(message.inferenceContent.contains("Tool: search"))
}

@Test(.timeLimit(.minutes(1))) @MainActor
func aGrowingWorkerExchangeCompactsOlderContextWithoutReplayingTheCall() async throws {
    let fixture = try await ToolLoopFixture(
        replies: ["unused"], countCharacters: true, resource: "BLUE PENGUIN")
    defer { fixture.clean() }
    try await fixture.workspace.prepare(using: fixture.model.cloud)
    var history: [ChatMessage] = []
    for _ in 0..<3 {
        history += [
            ChatMessage(role: .user, text: "Earlier question"),
            ChatMessage(role: .assistant, text: "Earlier answer"),
        ]
    }
    let question = "Read the fact."
    func context(_ turns: [ChatMessage]) throws -> [ConversationMessage] {
        ContextCompaction().context(
            transcript: turns.map { ConversationMessage(role: $0.role, content: $0.text) }
                + [ConversationMessage(role: .user, content: question)],
            state: .init(),
            instructions: try fixture.workspace.instructions(using: fixture.model.cloud),
            requestContext: try fixture.workspace.requestContext(using: fixture.model.cloud))
    }
    let padding = 5_800 - (try fixtureContextTokens(context(history)))
    try #require(padding > 0)
    history[0].text += String(repeating: "h", count: padding)
    #expect(try fixtureContextTokens(context(history)) == 5_800)
    // Explicit character-token fixture: legal formatting consumes the remaining budget
    // after dispatch, while the original request remained below the compaction trigger.
    let call = readSkillRequest.replacingOccurrences(
        of: "<tool_call>\n", with: "<tool_call>\n" + String(repeating: " ", count: 2_000))
    let backend = ToolBackendFixture(
        replies: ["DELEGATE", call, "Memory: earlier questions", "BLUE PENGUIN"],
        countCharacters: true)
    let previous = try #require(try await fixture.store.load())
    try await fixture.store.save(
        ConversationArchive(
            sequence: previous.sequence + 1,
            snapshot: ConversationSnapshot(
                conversationID: UUID(), messages: history, compaction: .init())))
    let model = LocalInferenceModel(
        repository: fixture.repository, manifest: try #require(fixture.model.manifest),
        session: InferenceSession { _, _ in backend }, chatStore: fixture.store,
        tools: fixture.workspace)
    model.check(); await model.waitUntilIdle()
    model.prompt = question
    model.run(); await model.waitUntilIdle()
    #expect(model.error == nil && model.answer == "BLUE PENGUIN")
    #expect(backend.calls == 5 && model.compaction.summarizedMessageCount > 0)
    #expect(model.messages.filter { $0.toolName != nil }.count == 1)
    #expect(model.messages.contains { $0.toolName != nil && $0.text.contains("BLUE PENGUIN") })
    for generation in backend.generations {
        #expect(fixtureContextTokens(generation.messages) + generation.limit < 8_192)
    }
}
