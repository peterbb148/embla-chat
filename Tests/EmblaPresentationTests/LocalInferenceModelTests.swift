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
    private let failOnStop: Bool
    var calls: Int { lock.withLock { count } }

    init(failOnStop: Bool = false) { self.failOnStop = failOnStop }
    func encode(_ messages: [ConversationMessage]) throws -> [Int] { [1, 2] }
    func reset() {}
    func generate(
        prompt: [Int], options: GenerationOptions,
        emit: @escaping @Sendable (GenerationDelta) -> Bool
    ) throws -> GenerationMetrics {
        let index = lock.withLock {
            count += 1; return count
        }
        if index == 1 {
            while emit(.reasoning("fixture reasoning")) { Thread.sleep(forTimeInterval: 0.01) }
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
    model.prompt = "Second prompt"
    model.run()
    await model.waitUntilIdle()
    #expect(model.answer == "fixture answer")
    #expect(model.metrics?.completionTokens == 2)
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
    #expect(!model.loaded && !model.busy)
}
