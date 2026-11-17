import CryptoKit
import Foundation
import Testing
@testable import EmblaCore
@testable import EmblaPresentation

private enum ModelTestError: Error { case backendFailure, timeout }

/// Explicit fixture backend; the app's public constructor always uses Embla Metal.
private final class PresentationBackend: InferenceBackend, @unchecked Sendable {
    let contextSize = 8_192
    private let lock = NSLock()
    private var count = 0
    private var inputs: [[ConversationMessage]] = []
    private let countCharacters: Bool
    private let pauseSummary: Bool
    private let summaryText: String
    private let emptySummary: Bool
    private let emptySummaryCall: Int?
    private var summaries = 0
    private var summaryStarted = false
    private let pauseFirst: Bool
    private let firstFinishReason: String
    private let failOnStop: Bool
    private let stopGate: DispatchSemaphore?
    private var reachedStop = false
    var calls: Int { lock.withLock { count } }
    var encodedMessages: [[ConversationMessage]] { lock.withLock { inputs } }

    init(
        failOnStop: Bool = false, stopGate: DispatchSemaphore? = nil, pauseFirst: Bool = true,
        firstFinishReason: String = "stop", countCharacters: Bool = false,
        pauseSummary: Bool = false, emptySummary: Bool = false, emptySummaryCall: Int? = nil,
        summaryText: String = "The user's retained requirement is blue penguin."
    ) {
        self.countCharacters = countCharacters
        self.pauseSummary = pauseSummary
        self.summaryText = summaryText
        self.emptySummary = emptySummary
        self.emptySummaryCall = emptySummaryCall
        self.failOnStop = failOnStop
        self.stopGate = stopGate
        self.pauseFirst = pauseFirst
        self.firstFinishReason = firstFinishReason
    }
    func encode(_ messages: [ConversationMessage]) throws -> [Int] {
        lock.withLock { inputs.append(messages) }
        return countCharacters
            ? Array(repeating: 1, count: messages.reduce(0) { $0 + $1.content.count + 4 })
            : [1, 2]
    }
    func reset() {}
    func generate(
        prompt: [Int], options: GenerationOptions,
        emit: @escaping @Sendable (GenerationDelta) -> Bool
    ) throws -> GenerationMetrics {
        let index = lock.withLock {
            count += 1; return count
        }
        if options.maxTokens == 1_536 {
            let summaryCall = lock.withLock {
                summaryStarted = true
                summaries += 1
                return summaries
            }
            if pauseSummary {
                while emit(.reasoning("summarizing")) { Thread.sleep(forTimeInterval: 0.01) }
            } else if !emptySummary && summaryCall != emptySummaryCall {
                _ = emit(.answer(summaryText))
            }
        } else if index == 1 && pauseFirst {
            while emit(.reasoning("fixture reasoning")) { Thread.sleep(forTimeInterval: 0.01) }
            lock.withLock { reachedStop = true }
            stopGate?.wait()
            if failOnStop { throw ModelTestError.backendFailure }
        } else {
            _ = emit(.reasoning("fixture reasoning"))
            _ = emit(.answer("fixture answer"))
        }
        return GenerationMetrics(
            finishReason: index == 1 ? firstFinishReason : "stop",
            promptTokens: 2, completionTokens: 2,
            promptMilliseconds: 1, decodeMilliseconds: 1
        )
    }
    func waitForSummary() async throws {
        for _ in 0..<2_000 {
            if lock.withLock({ summaryStarted }) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw ModelTestError.timeout
    }
    func waitForStop() async throws {
        for _ in 0..<2_000 {
            if lock.withLock({ reachedStop }) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw ModelTestError.timeout
    }
    func waitForStart() async throws {
        for _ in 0..<2_000 {
            if calls > 0 { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw ModelTestError.timeout
    }
}

private struct PresentationFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let manifest: ModelManifest
    let repository: ModelRepository

    init() throws {
        let data = Data("presentation fixture".utf8)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        manifest = ModelManifest(
            repository: "test/model", revision: "test-revision",
            files: [
                ModelManifest.Asset(path: "config.json", sizeBytes: Int64(data.count), sha256: sha)
            ])
        let directory = root.appendingPathComponent(manifest.revision)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("config.json"))
        repository = ModelRepository(root: root, manifest: manifest)
    }
    func clean() { try? FileManager.default.removeItem(at: root) }

    @MainActor func model(
        session: InferenceSession, chatStore: ConversationStore? = nil,
        countTokens: (@Sendable (URL, [ConversationMessage]) async throws -> Int)? = nil,
        tools: ToolWorkspace? = nil
    ) async -> LocalInferenceModel {
        let model = LocalInferenceModel(
            repository: repository, manifest: manifest, session: session, chatStore: chatStore,
            countTokens: countTokens, tools: tools)
        model.check()
        await model.waitUntilIdle()
        return model
    }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func stopWaitsForTheWorkerAndAllowsAnotherPrompt() async throws {
    let fixture = try PresentationFixture(); defer { fixture.clean() }
    let backend = PresentationBackend()
    let session = InferenceSession { _, _ in backend }
    let model = await fixture.model(session: session)
    model.prompt = "First prompt"
    model.run()
    try await backend.waitForStart()
    #expect(model.busy)
    model.stop()
    await model.waitUntilIdle()
    #expect(!model.busy)
    #expect(model.error == nil)
    #expect(model.messages.count == 2)
    #expect(model.messages[1].state == .interrupted)
    model.prompt = "Second prompt"
    model.run()
    await model.waitUntilIdle()
    #expect(model.answer == "fixture answer")
    #expect(model.metrics?.completionTokens == 2)
    #expect(model.messages.count == 4)
    #expect(model.messages[3].state == .complete)
    #expect(backend.calls == 2)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func newChatClearsOnlyAfterStoppingAndNeverDeletesTheModel() async throws {
    let fixture = try PresentationFixture(); defer { fixture.clean() }
    let backend = PresentationBackend()
    let session = InferenceSession { _, _ in backend }
    let model = await fixture.model(session: session)
    model.prompt = "First prompt"
    model.run()
    try await backend.waitForStart()
    model.newChat()
    await model.waitUntilIdle()
    #expect(model.prompt.isEmpty && model.reasoning.isEmpty && model.answer.isEmpty)
    #expect(model.messages.isEmpty)
    #expect(model.readyDirectory != nil)
    let directory = try await fixture.repository.installedDirectory()
    #expect(directory != nil)
    #expect(!model.busy)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func backgroundStopsAndUnloadsBeforeModelDeletion() async throws {
    let fixture = try PresentationFixture(); defer { fixture.clean() }
    let backend = PresentationBackend()
    let session = InferenceSession { _, _ in backend }
    let model = await fixture.model(session: session)
    model.prompt = "First prompt"
    model.run()
    try await backend.waitForStart()
    model.enteredBackground()
    await model.waitUntilIdle()
    let state = await session.state
    #expect(state == .unloaded)
    #expect(!model.loaded && !model.busy)
    model.delete()
    await model.waitUntilIdle()
    let directory = try await fixture.repository.installedDirectory()
    #expect(directory == nil)
    #expect(model.messages.count == 2)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func cancellationNeverHidesAGenuineBackendFailureInTheUI() async throws {
    let fixture = try PresentationFixture(); defer { fixture.clean() }
    let backend = PresentationBackend(failOnStop: true)
    let session = InferenceSession { _, _ in backend }
    let model = await fixture.model(session: session)
    model.prompt = "First prompt"
    model.run()
    try await backend.waitForStart()
    model.stop()
    await model.waitUntilIdle()
    #expect(model.error != nil)
    #expect(model.messages.last?.state == .failed)
    #expect(!model.loaded && !model.busy)
    let diagnostic = model.error
    model.enteredBackground()
    await model.waitUntilIdle()
    #expect(model.error == diagnostic)
    let state = await session.state
    #expect(state == .unloaded)
    #expect(!model.busy)
}

@Test @MainActor
func followUpIncludesPriorTurnsAndNewChatResetsContext() async throws {
    let fixture = try PresentationFixture(); defer { fixture.clean() }
    let backend = PresentationBackend(pauseFirst: false)
    let model = await fixture.model(session: InferenceSession { _, _ in backend })
    model.prompt = "My name is Ada"
    model.run()
    await model.waitUntilIdle()
    #expect(model.prompt.isEmpty)
    model.prompt = "What is my name"
    model.run()
    await model.waitUntilIdle()
    let followUp = try #require(backend.encodedMessages.last)
    #expect(followUp.map(\.role) == [.user, .assistant, .user])
    #expect(followUp.map(\.content) == ["My name is Ada", "fixture answer", "What is my name"])
    #expect(followUp[1].reasoning == "fixture reasoning")
    #expect(model.messages.count == 4)
    model.newChat()
    await model.waitUntilIdle()
    model.prompt = "A new conversation"
    model.run()
    await model.waitUntilIdle()
    #expect(backend.encodedMessages.last == [
        ConversationMessage(role: .user, content: "A new conversation")
    ])
    #expect(model.messages.count == 2)
}

@Test @MainActor
func rejectedEmptyRequestDoesNotChangeThePreviousResponse() async throws {
    let fixture = try PresentationFixture(); defer { fixture.clean() }
    let backend = PresentationBackend(pauseFirst: false)
    let model = await fixture.model(session: InferenceSession { _, _ in backend })
    model.prompt = "A valid message"
    model.run()
    await model.waitUntilIdle()
    let response = try #require(model.messages.last)
    model.run()
    await model.waitUntilIdle()
    #expect(model.error == InferenceError.emptyPrompt.localizedDescription)
    #expect(model.messages.count == 2)
    #expect(model.messages.last?.id == response.id)
    #expect(model.messages.last?.state == .complete)
    #expect(backend.calls == 1)
}

@Test @MainActor
func limitedResponseKeepsActualPartialContentInFollowUpContext() async throws {
    let fixture = try PresentationFixture(); defer { fixture.clean() }
    let backend = PresentationBackend(pauseFirst: false, firstFinishReason: "length")
    let model = await fixture.model(session: InferenceSession { _, _ in backend })
    model.prompt = "A request that reaches its output budget"
    model.run()
    await model.waitUntilIdle()
    let partial = try #require(model.messages.last)
    #expect(partial.state == .limited)
    #expect(partial.text == "fixture answer" && partial.reasoning == "fixture reasoning")
    #expect(model.metrics?.finishReason == "length")
    #expect(model.error == nil)
    model.prompt = "Continue that answer"
    model.run()
    await model.waitUntilIdle()
    let context = try #require(backend.encodedMessages.last)
    #expect(context.map(\.role) == [.user, .assistant, .user])
    #expect(context[1].content == partial.text)
    #expect(context[1].reasoning == partial.reasoning)
    #expect(model.messages[1].id == partial.id && model.messages[1].state == .limited)
    #expect(model.messages.last?.state == .complete)
}

@Test @MainActor
func newChatWithoutModelStorageStillClearsAndUnlocksTheComposer() async throws {
    let fixture = try PresentationFixture(); defer { fixture.clean() }
    let backend = PresentationBackend(pauseFirst: false)
    let model = LocalInferenceModel(
        repository: nil, manifest: fixture.manifest,
        session: InferenceSession { _, _ in backend })
    let diagnostic = model.error
    let previousConversation = model.conversationID
    model.prompt = "Draft while setup is unavailable"
    model.newChat()
    await model.waitUntilIdle()
    #expect(!model.resetting && !model.busy)
    #expect(model.prompt.isEmpty && model.messages.isEmpty)
    #expect(model.conversationID != previousConversation)
    #expect(model.error == diagnostic)
    #expect(backend.calls == 0)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func stoppingRemainsBusyUntilTheWorkerActuallyDrains() async throws {
    let fixture = try PresentationFixture(); defer { fixture.clean() }
    let gate = DispatchSemaphore(value: 0)
    defer { gate.signal() }
    let backend = PresentationBackend(stopGate: gate)
    let session = InferenceSession { _, _ in backend }
    let model = await fixture.model(session: session)
    model.prompt = "First prompt"
    model.run()
    try await backend.waitForStart()
    model.stop()
    try await backend.waitForStop()
    #expect(model.busy)
    #expect(!model.canRun)
    #expect(model.status == "Stopping…")
    gate.signal()
    await model.waitUntilIdle()
    #expect(!model.busy)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func newChatKeepsComposerLockedUntilDeferredClearingFinishes() async throws {
    let fixture = try PresentationFixture(); defer { fixture.clean() }
    let gate = DispatchSemaphore(value: 0)
    defer { gate.signal() }
    let backend = PresentationBackend(stopGate: gate)
    let model = await fixture.model(session: InferenceSession { _, _ in backend })
    let previousConversation = model.conversationID
    model.prompt = "First message"
    model.run()
    try await backend.waitForStart()
    model.prompt = "Draft being deliberately cleared"
    model.newChat()
    try await backend.waitForStop()
    #expect(model.resetting && model.busy)
    #expect(model.conversationID == previousConversation)
    #expect(model.prompt == "Draft being deliberately cleared")
    gate.signal()
    await model.waitUntilIdle()
    #expect(!model.resetting && !model.busy)
    #expect(model.prompt.isEmpty && model.messages.isEmpty)
    #expect(model.conversationID != previousConversation)
    model.prompt = "A message composed after reset"
    model.run()
    await model.waitUntilIdle()
    #expect(model.messages.first?.text == "A message composed after reset")
    #expect(model.messages.last?.state == .complete)
}

/// Character counting is a deterministic fixture tokenizer, never a production approximation.
@Test(.timeLimit(.minutes(1))) @MainActor
func repeatedCompactionRetainsTranscriptAndRecentTurns() async throws {
    let fixture = try PresentationFixture(); defer { fixture.clean() }
    let backend = PresentationBackend(pauseFirst: false, countCharacters: true)
    let model = await fixture.model(session: InferenceSession { _, _ in backend })
    for turn in 0..<5 {
        model.prompt = "Turn \(turn): " + String(repeating: "x", count: 1_600)
        model.run()
        await model.waitUntilIdle()
        #expect(model.error == nil)
    }
    #expect(model.messages.count == 10)
    #expect(model.compaction.summarizedMessageCount == 4)
    #expect(!model.compaction.summary.isEmpty)
    #expect(backend.calls == 7) // Five replies and two real summary operations.
    let finalContext = try #require(backend.encodedMessages.last)
    #expect(finalContext.first?.role == .system)
    #expect(finalContext.count == 6) // Summary, two exchanges, current user.
    #expect(finalContext[1].content.hasPrefix("Turn 2:"))
    #expect(model.messages.first?.text.hasPrefix("Turn 0:") == true)
    model.newChat()
    await model.waitUntilIdle()
    #expect(model.compaction == CompactionState())
    #expect(model.messages.isEmpty)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func emptySummaryFailsWithoutDroppingContextOrTranscript() async throws {
    let fixture = try PresentationFixture(); defer { fixture.clean() }
    let backend = PresentationBackend(
        pauseFirst: false, countCharacters: true, emptySummary: true)
    let model = await fixture.model(session: InferenceSession { _, _ in backend })
    for turn in 0..<4 {
        model.prompt = "Turn \(turn): " + String(repeating: "x", count: 1_600)
        model.run()
        await model.waitUntilIdle()
    }
    #expect(model.error == CompactionError.incompleteSummary.localizedDescription)
    #expect(model.compaction == CompactionState())
    #expect(model.messages.count == 8)
    #expect(model.messages.last?.state == .failed)
    #expect(model.messages.first?.text.hasPrefix("Turn 0:") == true)
    #expect(backend.calls == 4) // Three replies and one rejected empty summary.
}

@Test(.timeLimit(.minutes(1))) @MainActor
func newChatDuringCompactionCancelsSummaryAndClearsAllContext() async throws {
    let fixture = try PresentationFixture(); defer { fixture.clean() }
    let backend = PresentationBackend(
        pauseFirst: false, countCharacters: true, pauseSummary: true)
    let model = await fixture.model(session: InferenceSession { _, _ in backend })
    for turn in 0..<3 {
        model.prompt = "Turn \(turn): " + String(repeating: "x", count: 1_600)
        model.run()
        await model.waitUntilIdle()
    }
    model.prompt = String(repeating: "x", count: 1_600)
    model.run()
    try await backend.waitForSummary()
    #expect(model.compacting && model.running)
    #expect(model.status == "Compacting earlier messages…")
    model.newChat()
    await model.waitUntilIdle()
    #expect(model.messages.isEmpty && model.compaction == CompactionState())
    #expect(!model.compacting && !model.busy)
    model.prompt = "Fresh conversation"
    model.run()
    await model.waitUntilIdle()
    #expect(backend.encodedMessages.last == [
        ConversationMessage(role: .user, content: "Fresh conversation")
    ])
}

@Test(.timeLimit(.minutes(1))) @MainActor
func failedRepeatedCompactionKeepsThePreviouslyCommittedSummary() async throws {
    let fixture = try PresentationFixture(); defer { fixture.clean() }
    let backend = PresentationBackend(
        pauseFirst: false, countCharacters: true, emptySummaryCall: 2)
    let model = await fixture.model(session: InferenceSession { _, _ in backend })
    for turn in 0..<4 {
        model.prompt = "Turn \(turn): " + String(repeating: "x", count: 1_600)
        model.run()
        await model.waitUntilIdle()
    }
    let previous = model.compaction
    #expect(previous.summarizedMessageCount == 2)
    model.prompt = "Turn 4: " + String(repeating: "x", count: 1_600)
    model.run()
    await model.waitUntilIdle()
    #expect(model.error == CompactionError.incompleteSummary.localizedDescription)
    #expect(model.compaction == previous)
    #expect(model.messages.count == 10)
    #expect(model.messages.last?.state == .failed)
    #expect(backend.calls == 6)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func summaryThatWouldOverflowTheResponseBudgetIsNotCommitted() async throws {
    let fixture = try PresentationFixture(); defer { fixture.clean() }
    let backend = PresentationBackend(
        pauseFirst: false, countCharacters: true, summaryText: String(repeating: "s", count: 1_500))
    let model = await fixture.model(session: InferenceSession { _, _ in backend })
    for _ in 0..<3 {
        model.prompt = "Small turn"
        model.run()
        await model.waitUntilIdle()
    }
    model.prompt = String(repeating: "x", count: 6_500)
    model.run()
    await model.waitUntilIdle()
    #expect(model.error == CompactionError.summaryDoesNotFit.localizedDescription)
    #expect(model.compaction == CompactionState())
    #expect(model.messages.count == 8 && model.messages.last?.state == .failed)
    #expect(backend.calls == 4)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func stopDuringCompactionPreservesHistoryWithoutCommittingAPartialSummary() async throws {
    let fixture = try PresentationFixture(); defer { fixture.clean() }
    let backend = PresentationBackend(
        pauseFirst: false, countCharacters: true, pauseSummary: true)
    let model = await fixture.model(session: InferenceSession { _, _ in backend })
    for _ in 0..<3 {
        model.prompt = String(repeating: "x", count: 1_600)
        model.run()
        await model.waitUntilIdle()
    }
    model.prompt = String(repeating: "y", count: 1_600)
    model.run()
    try await backend.waitForSummary()
    model.stop()
    await model.waitUntilIdle()
    #expect(model.compaction == CompactionState())
    #expect(model.messages.count == 8 && model.messages.last?.state == .interrupted)
    #expect(model.messages.first?.text == String(repeating: "x", count: 1_600))
    #expect(model.error == nil && model.loaded && !model.busy)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func retryAfterFailedSummaryExcludesTheEmptyFailedAssistantTurn() async throws {
    let fixture = try PresentationFixture(); defer { fixture.clean() }
    let backend = PresentationBackend(
        pauseFirst: false, countCharacters: true, emptySummaryCall: 1)
    let model = await fixture.model(session: InferenceSession { _, _ in backend })
    for _ in 0..<4 {
        model.prompt = String(repeating: "x", count: 1_600)
        model.run()
        await model.waitUntilIdle()
    }
    #expect(model.messages.last?.state == .failed)
    let failedID = model.messages.last?.id
    model.prompt = "Retry and continue"
    model.run()
    await model.waitUntilIdle()
    #expect(model.error == nil && model.messages.last?.state == .complete)
    #expect(model.messages[7].id == failedID && model.messages[7].state == .failed)
    #expect(backend.calls == 6)
    #expect(!backend.encodedMessages.contains { context in
        context.contains { $0.role == .assistant && $0.content.isEmpty && $0.reasoning == nil }
    })
}

@Test @MainActor
func controllerRestoresSavedTranscriptAndUnsentDraftWithoutStartingInference() async throws {
    let fixture = try PresentationFixture(); defer { fixture.clean() }
    let root = fixture.root.appendingPathComponent("Conversation")
    let backend = PresentationBackend(pauseFirst: false)
    let first = await fixture.model(
        session: InferenceSession { _, _ in backend }, chatStore: ConversationStore(root: root))
    first.prompt = "Remember this message"
    first.run()
    await first.waitUntilIdle()
    first.prompt = "A draft kept on this device"
    #expect(first.storageStatus == "Saving on this device…")
    try await first.flushChatStorage()
    #expect(first.storageStatus == "Saved on this device.")
    let calls = backend.calls
    let second = await fixture.model(
        session: InferenceSession { _, _ in backend }, chatStore: ConversationStore(root: root))
    #expect(second.chatRestored && second.storageError == nil)
    #expect(second.messages == first.messages)
    #expect(second.conversationID == first.conversationID)
    #expect(second.prompt == "A draft kept on this device")
    #expect(!second.loaded && backend.calls == calls)
}

@Test @MainActor
func controllerRestoresCompactedContextAndUsesItForTheNextReply() async throws {
    let fixture = try PresentationFixture(); defer { fixture.clean() }
    let root = fixture.root.appendingPathComponent("Conversation")
    let backend = PresentationBackend(pauseFirst: false, countCharacters: true)
    let first = await fixture.model(
        session: InferenceSession { _, _ in backend }, chatStore: ConversationStore(root: root))
    for _ in 0..<4 {
        first.prompt = String(repeating: "x", count: 1_600)
        first.run()
        await first.waitUntilIdle()
    }
    try await first.flushChatStorage()
    let second = await fixture.model(
        session: InferenceSession { _, _ in backend }, chatStore: ConversationStore(root: root))
    #expect(second.compaction == first.compaction)
    #expect(second.compaction.summarizedMessageCount == 2)
    #expect(second.messages == first.messages)
    second.prompt = "Continue using earlier requirements"
    second.run()
    await second.waitUntilIdle()
    #expect(second.error == nil && second.storageError == nil)
    #expect(backend.encodedMessages.last?.first?.role == .system)
    #expect(backend.encodedMessages.last?.first?.content.contains(first.compaction.summary) == true)
}

@Test @MainActor
func controllerRecoversPersistedPartialReplyWithoutRestartingGeneration() async throws {
    let fixture = try PresentationFixture(); defer { fixture.clean() }
    let root = fixture.root.appendingPathComponent("Conversation")
    let store = ConversationStore(root: root)
    let snapshot = ConversationSnapshot(
        conversationID: UUID(), messages: [
            ChatMessage(role: .user, text: "Original request"),
            ChatMessage(role: .assistant, text: "Partial output", state: .streaming),
        ], compaction: CompactionState())
    try await store.save(ConversationArchive(sequence: 1, snapshot: snapshot))
    let backend = PresentationBackend(pauseFirst: false)
    let model = await fixture.model(
        session: InferenceSession { _, _ in backend }, chatStore: ConversationStore(root: root))
    #expect(model.chatRestored && model.messages.last?.state == .interrupted)
    #expect(model.messages.last?.id == snapshot.messages.last?.id)
    #expect(model.messages.last?.text == "Partial output")
    #expect(backend.calls == 0 && !model.running)
    let saved = try await ConversationStore(root: root).load()
    #expect(saved?.snapshot.messages.last?.state == .interrupted)
}

@Test @MainActor
func corruptChatBlocksGenerationAndNewChatWithoutDestroyingSavedBytes() async throws {
    let fixture = try PresentationFixture(); defer { fixture.clean() }
    let root = fixture.root.appendingPathComponent("Conversation")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("active-chat.json")
    let corrupt = Data("corrupt saved conversation".utf8)
    try corrupt.write(to: file)
    let backend = PresentationBackend(pauseFirst: false)
    let model = await fixture.model(
        session: InferenceSession { _, _ in backend }, chatStore: ConversationStore(root: root))
    #expect(!model.chatRestored && model.storageError != nil)
    model.prompt = "Do not overwrite my saved data"
    #expect(!model.canRun)
    model.run()
    model.newChat()
    await model.waitUntilIdle()
    #expect(try Data(contentsOf: file) == corrupt)
    #expect(backend.calls == 0)
}

@Test @MainActor
func corruptChatDoesNotPreventDeletingTheModelToReclaimStorage() async throws {
    let fixture = try PresentationFixture(); defer { fixture.clean() }
    // Chat and model directories are separate in production; do not nest this archive in model storage.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("active-chat.json")
    let corrupt = Data("saved conversation requiring recovery".utf8)
    try corrupt.write(to: file)
    let backend = PresentationBackend(pauseFirst: false)
    let model = await fixture.model(
        session: InferenceSession { _, _ in backend }, chatStore: ConversationStore(root: root))
    #expect(!model.chatRestored && model.storageError != nil)
    #expect(try await fixture.repository.storedBytes() > 0)
    model.delete()
    await model.waitUntilIdle()
    #expect(try await fixture.repository.storedBytes() == 0)
    #expect(model.status == "Model deleted.")
    #expect(!model.chatRestored && model.storageError != nil)
    #expect(try Data(contentsOf: file) == corrupt)
    #expect(backend.calls == 0)
}

@Test @MainActor
func failedResetSaveKeepsTheVisibleChatUntilAnActualDurableResetSucceeds() async throws {
    let fixture = try PresentationFixture(); defer { fixture.clean() }
    let root = fixture.root.appendingPathComponent("Conversation")
    let backup = fixture.root.appendingPathComponent("ConversationBackup")
    let backend = PresentationBackend(pauseFirst: false)
    let model = await fixture.model(
        session: InferenceSession { _, _ in backend }, chatStore: ConversationStore(root: root))
    model.prompt = "Keep until reset is durable"
    model.run()
    await model.waitUntilIdle()
    try await model.flushChatStorage()
    let original = model.messages
    let originalID = model.conversationID
    let originalSnapshot = model.cloud.current?()?.snapshot
    try FileManager.default.moveItem(at: root, to: backup)
    try Data("blocked directory".utf8).write(to: root)
    model.newChat()
    await model.waitUntilIdle()
    #expect(model.messages == original && model.conversationID == originalID)
    #expect(model.cloud.current?()?.snapshot == originalSnapshot)
    #expect(model.storageError != nil)
    try FileManager.default.removeItem(at: root)
    try FileManager.default.moveItem(at: backup, to: root)
    model.newChat()
    await model.waitUntilIdle()
    #expect(model.messages.isEmpty && model.conversationID != originalID)
    #expect(model.storageError == nil)
    let reopened = await fixture.model(
        session: InferenceSession { _, _ in backend }, chatStore: ConversationStore(root: root))
    #expect(reopened.messages.isEmpty && reopened.conversationID == model.conversationID)
}

@Test @MainActor
func retryRecreatesChatStoreAfterItsInitialLocationBecomesAvailable() async throws {
    let fixture = try PresentationFixture(); defer { fixture.clean() }
    let root = fixture.root.appendingPathComponent("Conversation")
    let snapshot = ConversationSnapshot(
        conversationID: UUID(), messages: [], compaction: CompactionState())
    try await ConversationStore(root: root).save(
        ConversationArchive(sequence: 1, snapshot: snapshot, draft: "Retain this saved draft"))
    var unavailable = true
    let backend = PresentationBackend(pauseFirst: false)
    let model = LocalInferenceModel(
        repository: fixture.repository, manifest: fixture.manifest,
        session: InferenceSession { _, _ in backend },
        chatStoreFactory: {
            if unavailable { throw ModelTestError.backendFailure }
            return ConversationStore(root: root)
        })
    model.check()
    await model.waitUntilIdle()
    #expect(!model.chatRestored && model.storageError != nil)
    unavailable = false
    model.retryChatStorage()
    await model.waitUntilIdle()
    #expect(model.chatRestored && model.storageError == nil)
    #expect(model.prompt == "Retain this saved draft")
    #expect(model.conversationID == snapshot.conversationID && model.canRun)
}


/// Clearly labelled saved turns, used to test compaction policy rather than model quality.
private func manualCompactionArchive() -> ConversationArchive {
    let messages = (0..<4).flatMap { index in
        [ChatMessage(role: .user, text: "Fixture requirement \(index)"),
         ChatMessage(role: .assistant, text: "Fixture answer \(index)")]
    }
    return ConversationArchive(sequence: 1, snapshot: ConversationSnapshot(
        conversationID: UUID(), messages: messages, compaction: CompactionState()),
        draft: "Current draft")
}

@Test(.timeLimit(.minutes(1))) @MainActor
func manualCompactionWorksBelowThresholdAndPersistsWithoutAddingVisibleTurns() async throws {
    let fixture = try PresentationFixture(); defer { fixture.clean() }
    let store = ConversationStore(root: fixture.root.appendingPathComponent("chat"))
    let archive = manualCompactionArchive()
    try await store.save(archive)
    let backend = PresentationBackend(pauseFirst: false)
    let model = await fixture.model(session: InferenceSession { _, _ in backend }, chatStore: store)
    #expect(model.manualCompactionUnavailableReason == nil)
    model.compactNow()
    await model.waitUntilIdle()
    #expect(model.error == nil)
    #expect(backend.calls == 1)
    #expect(model.messages == archive.snapshot.messages)
    #expect(model.prompt == archive.draft)
    #expect(model.compaction.summarizedMessageCount == 4)
    #expect(!model.compaction.summary.isEmpty)
    let saved = try #require(await store.load())
    #expect(saved.snapshot.compaction == model.compaction)
    #expect(saved.snapshot.messages == archive.snapshot.messages)
    #expect(saved.draft == archive.draft)
    #expect(model.manualCompactionUnavailableReason != nil)
    model.compactNow()
    await model.waitUntilIdle()
    #expect(backend.calls == 1)
    model.run()
    await model.waitUntilIdle()
    #expect(backend.encodedMessages.contains {
        $0.first?.content.hasPrefix("Summary of earlier conversation") == true
    })
    model.compactNow()
    await model.waitUntilIdle()
    #expect(model.compaction.summarizedMessageCount == 6)
    #expect(model.messages.count == archive.snapshot.messages.count + 2)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func stoppingManualCompactionKeepsSavedHistorySummaryAndDraft() async throws {
    let fixture = try PresentationFixture(); defer { fixture.clean() }
    let store = ConversationStore(root: fixture.root.appendingPathComponent("chat"))
    let archive = manualCompactionArchive()
    try await store.save(archive)
    let backend = PresentationBackend(pauseSummary: true)
    let model = await fixture.model(session: InferenceSession { _, _ in backend }, chatStore: store)
    model.compactNow()
    try await backend.waitForSummary()
    #expect(model.compacting)
    model.stop()
    await model.waitUntilIdle()
    #expect(!model.compacting)
    #expect(model.compaction == archive.snapshot.compaction)
    #expect(model.messages == archive.snapshot.messages)
    #expect(model.prompt == archive.draft)
    #expect(try await store.load()?.snapshot == archive.snapshot)
}

@Test @MainActor
func failedManualSummaryPreservesCommittedContextWithoutAddingAFailedTurn() async throws {
    let fixture = try PresentationFixture(); defer { fixture.clean() }
    let store = ConversationStore(root: fixture.root.appendingPathComponent("chat"))
    let archive = manualCompactionArchive()
    try await store.save(archive)
    let backend = PresentationBackend(emptySummary: true)
    let model = await fixture.model(session: InferenceSession { _, _ in backend }, chatStore: store)
    model.compactNow()
    await model.waitUntilIdle()
    #expect(model.error != nil)
    #expect(model.compaction == archive.snapshot.compaction)
    #expect(model.messages == archive.snapshot.messages)
    #expect(try await store.load()?.snapshot == archive.snapshot)
}

private actor CapturedContextCount {
    var messages: [ConversationMessage] = []
    func count(_ messages: [ConversationMessage]) -> Int { self.messages = messages; return 42 }
}

@Test @MainActor
func usageCountsTheRetainedContextAndDraftWithoutLoadingTheEngine() async throws {
    let fixture = try PresentationFixture(); defer { fixture.clean() }
    let store = ConversationStore(root: fixture.root.appendingPathComponent("chat"))
    var archive = manualCompactionArchive()
    archive.snapshot.compaction = CompactionState(summary: "Retained fixture fact", summarizedMessageCount: 4)
    try await store.save(archive)
    let counter = CapturedContextCount()
    let backend = PresentationBackend()
    let model = await fixture.model(
        session: InferenceSession { _, _ in backend }, chatStore: store,
        countTokens: { _, messages in await counter.count(messages) })
    await model.waitForContextUsage()
    let counted = await counter.messages
    #expect(counted.first?.role == .system)
    #expect(counted.first?.content.contains("Retained fixture fact") == true)
    let retained = archive.snapshot.messages.dropFirst(4).map(\.text)
    #expect(counted.dropFirst().dropLast().map(\.content) == retained)
    #expect(counted.last == ConversationMessage(role: .user, content: archive.draft))
    #expect(!model.loaded)
    #expect(backend.calls == 0)
    if case .ready(let usage) = model.contextUsage {
        #expect(usage.inputTokens == 42)
        #expect(usage.capacity == 8192)
        #expect(usage.replyReserve == 512)
    } else { Issue.record("Expected exact fixture-counter result") }
    model.prompt = ""
    await model.waitForContextUsage()
    #expect(await counter.messages.last == ConversationMessage(role: .user, content: ""))
    model.newChat()
    await model.waitUntilIdle()
    await model.waitForContextUsage()
    #expect(await counter.messages == [ConversationMessage(role: .user, content: "")])
}

private actor ManualSummaryStore: ConversationStoring {
    let wrapped: ConversationStore
    let failSummary: Bool
    let holdSummary: Bool
    let holdSummarySave: Int
    private var summarySaves = 0
    var entered = false
    var history: [ConversationArchive] = []
    private var continuation: CheckedContinuation<Void, Never>?

    init(
        wrapped: ConversationStore, failSummary: Bool = false,
        holdSummary: Bool = false, holdSummarySave: Int = 1
    ) {
        self.wrapped = wrapped
        self.failSummary = failSummary
        self.holdSummary = holdSummary
        self.holdSummarySave = holdSummarySave
    }
    func load() async throws -> ConversationArchive? { try await wrapped.load() }
    func save(_ archive: ConversationArchive) async throws {
        history.append(archive)
        if !archive.snapshot.compaction.summary.isEmpty {
            if failSummary { throw CocoaError(.fileWriteOutOfSpace) }
            summarySaves += 1
            if holdSummary && summarySaves == holdSummarySave {
                entered = true
                await withCheckedContinuation { continuation = $0 }
            }
        }
        try await wrapped.save(archive)
    }
    func release() { continuation?.resume(); continuation = nil }
    func waitForEntry() async throws {
        for _ in 0..<2000 {
            if entered { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw ModelTestError.timeout
    }
}

@Test @MainActor
func failedManualSummarySaveLeavesThePreviouslyCommittedContextIntact() async throws {
    let fixture = try PresentationFixture(); defer { fixture.clean() }
    let file = ConversationStore(root: fixture.root.appendingPathComponent("chat"))
    let archive = manualCompactionArchive()
    try await file.save(archive)
    let store = ManualSummaryStore(wrapped: file, failSummary: true)
    let backend = PresentationBackend(pauseFirst: false)
    let model = LocalInferenceModel(repository: fixture.repository, manifest: fixture.manifest,
        session: InferenceSession { _, _ in backend }, chatStore: store)
    model.check(); await model.waitUntilIdle()
    model.compactNow(); await model.waitUntilIdle()
    #expect(model.error != nil)
    #expect(model.compaction == archive.snapshot.compaction)
    #expect(model.messages == archive.snapshot.messages)
    #expect(try await file.load()?.snapshot == archive.snapshot)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func draftCheckpointsCannotQueueOldContextBehindManualSummaryCommit() async throws {
    let fixture = try PresentationFixture(); defer { fixture.clean() }
    let file = ConversationStore(root: fixture.root.appendingPathComponent("chat"))
    try await file.save(manualCompactionArchive())
    let store = ManualSummaryStore(wrapped: file, holdSummary: true)
    let backend = PresentationBackend(pauseFirst: false)
    let model = LocalInferenceModel(repository: fixture.repository, manifest: fixture.manifest,
        session: InferenceSession { _, _ in backend }, chatStore: store)
    model.check(); await model.waitUntilIdle()
    model.compactNow()
    try await store.waitForEntry()
    model.prompt = "Draft edited during commit"
    try await Task.sleep(for: .milliseconds(650))
    await store.release()
    await model.waitUntilIdle()
    let history = await store.history
    let first = try #require(history.firstIndex { !$0.snapshot.compaction.summary.isEmpty })
    #expect(history.dropFirst(first).allSatisfy { !$0.snapshot.compaction.summary.isEmpty })
    let saved = try #require(await file.load())
    #expect(saved.snapshot.compaction == model.compaction)
    #expect(saved.draft == "Draft edited during commit")
}

private actor DelayedContextCounter {
    private var calls = 0
    private var continuation: CheckedContinuation<Int, Never>?
    func count() async -> Int {
        calls += 1
        if calls == 1 { return await withCheckedContinuation { continuation = $0 } }
        return 22
    }
    func waitForEntry() async throws {
        for _ in 0..<2000 {
            if continuation != nil { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw ModelTestError.timeout
    }
    func release() { continuation?.resume(returning: 11); continuation = nil }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func staleCountCannotReplaceTheCurrentDraftMeasurement() async throws {
    let fixture = try PresentationFixture(); defer { fixture.clean() }
    let counter = DelayedContextCounter()
    let backend = PresentationBackend()
    let model = await fixture.model(session: InferenceSession { _, _ in backend },
        countTokens: { _, _ in await counter.count() })
    try await counter.waitForEntry()
    let firstWait = Task { await model.waitForContextUsage() }
    await Task.yield()
    model.prompt = "New draft"
    await model.waitForContextUsage()
    await counter.release()
    await firstWait.value
    if case .ready(let usage) = model.contextUsage {
        #expect(usage.inputTokens == 22)
    } else { Issue.record("Current measurement was lost") }
    model.enteredBackground()
    await model.waitUntilIdle()
    if case .unavailable = model.contextUsage {} else { Issue.record("Background count stayed active") }
}

private actor FailingContextCount {
    var calls = 0
    func count() throws -> Int {
        calls += 1
        if calls == 1 { throw ModelTestError.backendFailure }
        return 17
    }
}

@Test @MainActor
func countingFailureHasNoInventedUsageAndExplicitRetryCanRecover() async throws {
    let fixture = try PresentationFixture(); defer { fixture.clean() }
    let counter = FailingContextCount()
    let backend = PresentationBackend()
    let model = await fixture.model(session: InferenceSession { _, _ in backend },
        countTokens: { _, _ in try await counter.count() })
    await model.waitForContextUsage()
    if case .failed(let message) = model.contextUsage {
        #expect(!message.isEmpty)
    } else { Issue.record("Counting failure did not remain visible") }
    model.refreshContextUsage()
    await model.waitForContextUsage()
    if case .ready(let usage) = model.contextUsage {
        #expect(usage.inputTokens == 17)
    } else { Issue.record("Explicit count retry failed") }
    #expect(backend.calls == 0)
    #expect(!model.loaded)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func completedManualSummarySaveIsExplicitlyNonCancellableAndKeepsDiskAndMemoryConsistent() async throws {
    let fixture = try PresentationFixture(); defer { fixture.clean() }
    let file = ConversationStore(root: fixture.root.appendingPathComponent("chat"))
    let archive = manualCompactionArchive()
    try await file.save(archive)
    let store = ManualSummaryStore(wrapped: file, holdSummary: true)
    let backend = PresentationBackend(pauseFirst: false)
    let model = LocalInferenceModel(repository: fixture.repository, manifest: fixture.manifest,
        session: InferenceSession { _, _ in backend }, chatStore: store)
    model.check(); await model.waitUntilIdle()
    model.compactNow()
    try await store.waitForEntry()
    #expect(model.busy)
    #expect(!model.running)  // The composer no longer offers Stop.
    #expect(model.status == "Saving completed summary…")
    #expect(model.compaction == archive.snapshot.compaction)
    model.stop()
    #expect(model.status == "Saving completed summary…")
    await store.release()
    await model.waitUntilIdle()
    #expect(model.error == nil)
    #expect(!model.compaction.summary.isEmpty)
    #expect(model.messages == archive.snapshot.messages)
    #expect(try await file.load()?.snapshot.compaction == model.compaction)
}


@Test(.timeLimit(.minutes(1))) @MainActor
func draftEditedDuringTheFinalManualSaveIsCheckpointedAfterTheBarrierClears() async throws {
    let fixture = try PresentationFixture(); defer { fixture.clean() }
    let file = ConversationStore(root: fixture.root.appendingPathComponent("chat"))
    try await file.save(manualCompactionArchive())
    let store = ManualSummaryStore(wrapped: file, holdSummary: true, holdSummarySave: 2)
    let backend = PresentationBackend(pauseFirst: false)
    let model = LocalInferenceModel(repository: fixture.repository, manifest: fixture.manifest,
        session: InferenceSession { _, _ in backend }, chatStore: store)
    model.check(); await model.waitUntilIdle()
    model.compactNow()
    try await store.waitForEntry()
    #expect(!model.compaction.summary.isEmpty)
    model.prompt = "Newest draft while final save is pending"
    await store.release()
    await model.waitUntilIdle()
    await model.waitForScheduledPersistence()
    let saved = try #require(await file.load())
    #expect(saved.draft == "Newest draft while final save is pending")
    #expect(saved.snapshot.compaction == model.compaction)
}

@Test @MainActor
func twoChatsKeepExactSummariesAndDraftsAcrossNavigationAndRestart() async throws {
    let fixture = try PresentationFixture(); defer { fixture.clean() }
    let root = fixture.root.appendingPathComponent("History")
    let first = ConversationSnapshot(
        conversationID: UUID(), messages: [
            ChatMessage(role: .user, text: "First chat requirement"),
            ChatMessage(role: .assistant, text: "First reply"),
            ChatMessage(role: .user, text: "Follow up"),
            ChatMessage(role: .assistant, text: "Second reply"),
        ], compaction: CompactionState(summary: "Retain first requirement", summarizedMessageCount: 2))
    try await ConversationStore(root: root).save(
        ConversationArchive(sequence: 1, snapshot: first, draft: "First unsent draft"))
    let backend = PresentationBackend(pauseFirst: false)
    let model = await fixture.model(
        session: InferenceSession { _, _ in backend }, chatStore: ConversationStore(root: root))
    model.newChat()
    await model.waitUntilIdle()
    let secondID = model.conversationID
    model.prompt = "Second unsent draft"
    model.selectChat(first.conversationID)
    await model.waitUntilIdle()
    #expect(model.messages == first.messages && model.compaction == first.compaction)
    #expect(model.prompt == "First unsent draft")
    #expect(model.history.first?.id == secondID)
    let reopened = await fixture.model(
        session: InferenceSession { _, _ in backend }, chatStore: ConversationStore(root: root))
    #expect(reopened.messages == first.messages && reopened.prompt == "First unsent draft")
    reopened.selectChat(secondID)
    await reopened.waitUntilIdle()
    #expect(reopened.messages.isEmpty && reopened.prompt == "Second unsent draft")
    #expect(reopened.history.first?.snapshot == first)
    #expect(!reopened.cloud.enabled && backend.calls == 0)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func navigatingDuringGenerationArchivesInterruptedOutputBeforeSwitching() async throws {
    let fixture = try PresentationFixture(); defer { fixture.clean() }
    let backend = PresentationBackend()
    let model = await fixture.model(session: InferenceSession { _, _ in backend })
    model.prompt = "A cancellable first chat"
    model.run()
    try await backend.waitForStart()
    let firstID = model.conversationID
    model.newChat()
    await model.waitUntilIdle()
    #expect(model.conversationID != firstID && model.messages.isEmpty)
    #expect(model.history.first?.id == firstID)
    #expect(model.history.first?.snapshot.messages.last?.state == .interrupted)
    model.selectChat(firstID)
    await model.waitUntilIdle()
    #expect(model.messages.last?.state == .interrupted)
    #expect(backend.calls == 1 && !model.busy)
}

@Test @MainActor
func projectMemoryIsCountedAndSentOnlyToChatsInTheAssignedProject() async throws {
    let fixture = try PresentationFixture(); defer { fixture.clean() }
    let source = ChatMessage(role: .user, text: "Synthetic source fact BLUE PENGUIN")
    let chatID = UUID()
    let project = ChatProject(name: "A", memory: [ProjectMemoryEntry(text: "BLUE PENGUIN",
        sourceConversationID: chatID, sourceMessageID: source.id)])
    let other = ChatProject(name: "B")
    var archive = ConversationArchive(sequence: 1, snapshot: ConversationSnapshot(
        conversationID: chatID, messages: [source], compaction: .init(), projectID: project.id))
    archive.projects = [project, other]
    let store = ConversationStore(root: fixture.root.appendingPathComponent("Projects"))
    try await store.save(archive)
    let backend = PresentationBackend(pauseFirst: false)
    let model = await fixture.model(session: InferenceSession { _, _ in backend }, chatStore: store,
        countTokens: { _, messages in messages.reduce(0) { $0 + $1.content.count + 4 } })
    model.newChat(in: project.id); await model.waitUntilIdle()
    await model.waitForContextUsage()
    guard case .ready(let usage) = model.contextUsage else {
        Issue.record("Project context counter did not become ready"); return
    }
    #expect(usage.inputTokens > "BLUE PENGUIN".count)
    model.prompt = "What is the saved fact?"
    model.run(); await model.waitUntilIdle()
    let a = try #require(backend.encodedMessages.last)
    #expect(a.filter { $0.role == .system }.count == 1)
    #expect(a.first?.content.contains("BLUE PENGUIN") == true)
    #expect(!model.messages.contains { $0.text.contains("BLUE PENGUIN") })
    model.newChat(in: other.id); await model.waitUntilIdle()
    model.prompt = "What is the saved fact?"
    model.run(); await model.waitUntilIdle()
    #expect(backend.encodedMessages.last?.contains { $0.content.contains("BLUE PENGUIN") } == false)
    model.newChat(); await model.waitUntilIdle()
    model.prompt = "An unrelated chat"
    model.run(); await model.waitUntilIdle()
    #expect(backend.encodedMessages.last?.contains { $0.content.contains("BLUE PENGUIN") } == false)
    #expect(model.projects.first(where: { $0.id == project.id })?.memory == project.memory)
}

@Test @MainActor
func oversizedProjectMemoryFailsClearlyWithoutTruncatingOrGenerating() async throws {
    let fixture = try PresentationFixture(); defer { fixture.clean() }
    let source = ChatMessage(role: .user, text: "Synthetic source for an oversized note")
    let chatID = UUID()
    let project = ChatProject(name: "Large notes", memory: [ProjectMemoryEntry(
        text: String(repeating: "Synthetic saved note. ", count: 500),
        sourceConversationID: chatID, sourceMessageID: source.id)])
    var archive = ConversationArchive(sequence: 1, snapshot: ConversationSnapshot(
        conversationID: chatID, messages: [source], compaction: .init(), projectID: project.id))
    archive.projects = [project]
    let store = ConversationStore(root: fixture.root.appendingPathComponent("Projects"))
    try await store.save(archive)
    let backend = PresentationBackend(pauseFirst: false, countCharacters: true)
    let model = await fixture.model(session: InferenceSession { _, _ in backend }, chatStore: store)
    model.prompt = "Please answer"
    model.run(); await model.waitUntilIdle()
    #expect(model.error?.contains("project memory") == true)
    #expect(backend.calls == 0)
    #expect(model.projects == [project] && model.compaction.summary.isEmpty)
    #expect(try await store.load()?.projects == [project])
}

/// Persisted schemas permit local compaction without contacting an unavailable test endpoint.
@Test(.timeLimit(.minutes(1))) @MainActor
func restartedToolChatCountsAndCompactsOfflineWithoutChangingVisibleHistory() async throws {
    let fixture = try PresentationFixture(); defer { fixture.clean() }
    let file = fixture.root.appendingPathComponent("servers.json")
    let setup = ToolWorkspace(configuration: file)
    let server = MCPServer(name: "Synthetic offline catalog",
        endpoint: URL(string: "https://example.invalid/mcp")!)
    try setup.saveServer(server)
    try setup.acceptDiscoveredTools([
        MCPTool(name: "synthetic_clock", description: "Fixture only, never called.",
            inputSchema: .object(["type": .string("object")]))], serverID: server.id)
    setup.pause()
    let workspace = ToolWorkspace(configuration: file)
    let store = ConversationStore(root: fixture.root.appendingPathComponent("chat"))
    let archive = manualCompactionArchive()
    try await store.save(archive)
    let model = await fixture.model(
        session: InferenceSession { _, _ in PresentationBackend(pauseFirst: false) },
        chatStore: store, countTokens: { _, messages in
            messages.reduce(0) { $0 + $1.content.count }
        }, tools: workspace)
    await model.waitForContextUsage()
    guard case .ready = model.contextUsage else {
        Issue.record("Saved schemas must allow offline context counting"); return
    }
    model.compactNow(); await model.waitUntilIdle()
    #expect(model.error == nil)
    #expect(model.compaction.summarizedMessageCount == 4)
    #expect(model.messages == archive.snapshot.messages && model.prompt == archive.draft)
    #expect(try await store.load()?.snapshot.compaction == model.compaction)
    #expect(workspace.discovered.isEmpty && workspace.connecting == nil)
}
