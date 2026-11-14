import CryptoKit
import Foundation
import Testing
@testable import EmblaCore

private enum InferenceTestError: Error { case load, generation, timeout }

/// Test-only backend: blocking callbacks let tests observe actual cancellation and serialization.
private final class TestBackend: InferenceBackend, @unchecked Sendable {
    let contextSize = 32
    private let lock = NSLock()
    private var running = 0
    private var count = 0
    private var maximum = 0
    private let failFirst: Bool
    private let holdFirst: Bool
    var calls: Int { lock.withLock { count } }
    var maximumConcurrentCalls: Int { lock.withLock { maximum } }

    init(failFirst: Bool = false, holdFirst: Bool = false) {
        self.failFirst = failFirst
        self.holdFirst = holdFirst
    }
    func encode(_ messages: [ConversationMessage]) throws -> [Int] { [1, 2] }
    func reset() {}

    func generate(
        prompt: [Int], options: GenerationOptions,
        emit: @escaping @Sendable (GenerationDelta) -> Bool
    ) throws -> GenerationMetrics {
        let index = lock.withLock {
            count += 1
            running += 1
            maximum = max(maximum, running)
            return count
        }
        defer { lock.withLock { running -= 1 } }
        if failFirst && index == 1 { throw InferenceTestError.generation }
        var made = 0
        var token = 0
        while token < options.maxTokens || (holdFirst && index == 1) {
            Thread.sleep(forTimeInterval: 0.01)
            made += 1
            if !emit(token == 0 ? .reasoning("thinking") : .answer("answer")) { break }
            token += 1
        }
        return GenerationMetrics(
            finishReason: "stop", promptTokens: prompt.count, completionTokens: made,
            promptMilliseconds: 1, decodeMilliseconds: 1
        )
    }

    func waitForStart() async throws {
        for _ in 0..<2_000 {
            if calls > 0 { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw InferenceTestError.timeout
    }
}

private struct SessionFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let data = Data("fixture".utf8)
    func repository(installed: Bool = true) throws -> ModelRepository {
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let manifest = ModelManifest(
            repository: "test/model", revision: "test-revision",
            files: [
                ModelManifest.Asset(path: "config.json", sizeBytes: Int64(data.count), sha256: sha)
            ]
        )
        if installed {
            let directory = root.appendingPathComponent(manifest.revision)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent("config.json"))
        }
        return ModelRepository(root: root, manifest: manifest)
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}

private let userMessage = [ConversationMessage(role: .user, content: "Hello")]

@Test func streamingSeparatesReasoningAnswerAndMetricsThenAllowsResetAndUnload() async throws {
    let fixture = SessionFixture(); defer { fixture.clean() }
    let backend = TestBackend()
    let session = InferenceSession { _, _ in backend }
    try await session.load(from: fixture.repository())
    let count = try await session.tokenCount(messages: userMessage)
    #expect(count == 2)
    let run = try await session.generate(
        messages: userMessage, options: GenerationOptions(maxTokens: 3))
    var reasoning = "", answer = ""
    var metrics: GenerationMetrics?
    for try await event in run.events {
        switch event {
        case let .reasoning(text): reasoning += text
        case let .answer(text): answer += text
        case let .finished(value): metrics = value
        }
    }
    await run.waitUntilFinished()
    #expect(reasoning == "thinking")
    #expect(answer == "answeranswer")
    #expect(metrics?.completionTokens == 3)
    try await session.reset()
    try await session.unload()
    let state = await session.state
    #expect(state == .unloaded)
    await #expect(throws: InferenceError.notLoaded) {
        try await session.generate(messages: userMessage)
    }
}

@Test(.timeLimit(.minutes(1))) func cancellationAndAQueuedRequestNeverOverlap() async throws {
    let fixture = SessionFixture(); defer { fixture.clean() }
    let backend = TestBackend(holdFirst: true)
    let session = InferenceSession { _, _ in backend }
    try await session.load(from: fixture.repository())
    let first = try await session.generate(
        messages: userMessage, options: GenerationOptions(maxTokens: 20))
    try await backend.waitForStart()
    let next = Task {
        try await session.generate(messages: userMessage, options: GenerationOptions(maxTokens: 3))
    }
    first.cancel()
    do {
        for try await _ in first.events {}
        Issue.record("Cancelled run unexpectedly finished normally")
    } catch is CancellationError {}
    await first.waitUntilFinished()
    let second = try await next.value
    for try await _ in second.events {}
    await second.waitUntilFinished()
    #expect(backend.calls == 2)
    #expect(backend.maximumConcurrentCalls == 1)
    let state = await session.state
    #expect(state == .ready)
}

@Test(.timeLimit(.minutes(1))) func cancellingTheStreamConsumerAlsoStopsTheWorker() async throws {
    let fixture = SessionFixture(); defer { fixture.clean() }
    let backend = TestBackend(holdFirst: true)
    let session = InferenceSession { _, _ in backend }
    try await session.load(from: fixture.repository())
    let run = try await session.generate(
        messages: userMessage, options: GenerationOptions(maxTokens: 20))
    let consumer = Task { for try await _ in run.events {} }
    try await backend.waitForStart()
    consumer.cancel()
    _ = await consumer.result
    await run.waitUntilFinished()
    let state = await session.state
    #expect(state == .ready)
    try await session.unload()
}

@Test func invalidBudgetsAndEmptyPromptsDoNotReachGeneration() async throws {
    let fixture = SessionFixture(); defer { fixture.clean() }
    let backend = TestBackend()
    let session = InferenceSession { _, _ in backend }
    try await session.load(from: fixture.repository())
    await #expect(throws: InferenceError.contextExceeded(promptTokens: 2, availableOutput: 29)) {
        try await session.generate(messages: userMessage, options: GenerationOptions(maxTokens: 30))
    }
    await #expect(throws: InferenceError.emptyPrompt) {
        try await session.generate(messages: [ConversationMessage(role: .user, content: "  ")])
    }
    await #expect(throws: InferenceError.invalidSettings) {
        try await session.generate(messages: userMessage, options: GenerationOptions(maxTokens: 0))
    }
    #expect(backend.calls == 0)
}

@Test func missingOrFailedLoadDoesNotExposeAReadyModel() async throws {
    let fixture = SessionFixture(); defer { fixture.clean() }
    let session = InferenceSession { _, _ in throw InferenceTestError.load }
    await #expect(throws: InferenceError.modelNotDownloaded) {
        try await session.load(from: fixture.repository(installed: false))
    }
    await #expect(throws: InferenceTestError.load) {
        try await session.load(from: fixture.repository())
    }
    await #expect(throws: InferenceError.notLoaded) {
        try await session.generate(messages: userMessage)
    }
}

@Test func thrownGenerationFailureRequiresReloadAndThenCanRecover() async throws {
    let fixture = SessionFixture(); defer { fixture.clean() }
    let backend = TestBackend(failFirst: true)
    let session = InferenceSession { _, _ in backend }
    try await session.load(from: fixture.repository())
    let run = try await session.generate(
        messages: userMessage, options: GenerationOptions(maxTokens: 3))
    do {
        for try await _ in run.events {}
        Issue.record("Backend failure unexpectedly succeeded")
    } catch InferenceTestError.generation {}
    await run.waitUntilFinished()
    await #expect(throws: InferenceError.notLoaded) {
        try await session.generate(messages: userMessage)
    }
    try await session.load(from: fixture.repository())
    let recovered = try await session.generate(
        messages: userMessage, options: GenerationOptions(maxTokens: 3))
    for try await _ in recovered.events {}
    await recovered.waitUntilFinished()
    let state = await session.state
    #expect(state == .ready)
}
