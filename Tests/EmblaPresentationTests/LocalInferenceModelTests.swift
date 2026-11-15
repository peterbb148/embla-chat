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
        session: InferenceSession, chatStore: ConversationStore? = nil
    ) async -> LocalInferenceModel {
        let model = LocalInferenceModel(
            repository: repository, manifest: manifest, session: session, chatStore: chatStore)
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
    try FileManager.default.moveItem(at: root, to: backup)
    try Data("blocked directory".utf8).write(to: root)
    model.newChat()
    await model.waitUntilIdle()
    #expect(model.messages == original && model.conversationID == originalID)
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
