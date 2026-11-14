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
    private let pauseFirst: Bool
    private let failOnStop: Bool
    private let stopGate: DispatchSemaphore?
    private var reachedStop = false
    var calls: Int { lock.withLock { count } }
    var encodedMessages: [[ConversationMessage]] { lock.withLock { inputs } }

    init(
        failOnStop: Bool = false, stopGate: DispatchSemaphore? = nil, pauseFirst: Bool = true
    ) {
        self.failOnStop = failOnStop
        self.stopGate = stopGate
        self.pauseFirst = pauseFirst
    }
    func encode(_ messages: [ConversationMessage]) throws -> [Int] {
        lock.withLock { inputs.append(messages) }
        return [1, 2]
    }
    func reset() {}
    func generate(
        prompt: [Int], options: GenerationOptions,
        emit: @escaping @Sendable (GenerationDelta) -> Bool
    ) throws -> GenerationMetrics {
        let index = lock.withLock {
            count += 1; return count
        }
        if index == 1 && pauseFirst {
            while emit(.reasoning("fixture reasoning")) { Thread.sleep(forTimeInterval: 0.01) }
            lock.withLock { reachedStop = true }
            stopGate?.wait()
            if failOnStop { throw ModelTestError.backendFailure }
        } else {
            _ = emit(.reasoning("fixture reasoning"))
            _ = emit(.answer("fixture answer"))
        }
        return GenerationMetrics(
            finishReason: "stop", promptTokens: 2, completionTokens: 2,
            promptMilliseconds: 1, decodeMilliseconds: 1
        )
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

    @MainActor func model(session: InferenceSession) async -> LocalInferenceModel {
        let model = LocalInferenceModel(
            repository: repository, manifest: manifest, session: session)
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
