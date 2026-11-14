import Foundation
import Observation

import EmblaCore
import EmblaRuntime

/// A visible turn in the single active conversation.
public struct ChatMessage: Identifiable, Sendable {
    public enum State: Sendable { case streaming, complete, interrupted, failed, limited }
    public let id = UUID()
    public let role: ConversationMessage.Role
    public var text: String
    public var reasoning = ""
    public var state: State = .complete
}

/// Shared presentation state for model setup and the single active conversation.
@MainActor @Observable
public final class LocalInferenceModel {
    public var prompt = ""
    public private(set) var messages: [ChatMessage] = []
    public private(set) var manifest: ModelManifest?
    public private(set) var readyDirectory: URL?
    public private(set) var storedBytes: Int64 = 0
    public private(set) var downloadedBytes: Int64 = 0
    public private(set) var status = "Checking model storage…"
    public private(set) var busy = false
    public private(set) var downloading = false
    public private(set) var running = false
    public private(set) var loaded = false
    public private(set) var error: String?
    public private(set) var reasoning = ""
    public private(set) var answer = ""
    public private(set) var metrics: GenerationMetrics?
    public private(set) var loadMilliseconds: Double?
    @ObservationIgnored private var repository: ModelRepository?
    @ObservationIgnored private let session: InferenceSession
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var activeRun: GenerationRun?
    @ObservationIgnored private var operationID: UUID?
    @ObservationIgnored private var pendingUnload = false
    @ObservationIgnored private var pendingClear = false

    public var canRun: Bool {
        !busy && readyDirectory != nil
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Production always uses the pinned Embla runtime and app-managed model storage.
    public init() {
        session = EmblaRuntime.makeSession()
        do {
            let manifest = try ModelManifest.bundled()
            self.manifest = manifest
            repository = ModelRepository(
                root: try ModelRepository.defaultRoot(), manifest: manifest)
        } catch {
            self.error = error.localizedDescription
            status = "Model setup is unavailable."
        }
    }

    /// Test-only construction is internal; the app cannot select a substitute runtime.
    init(repository: ModelRepository, manifest: ModelManifest, session: InferenceSession) {
        self.repository = repository
        self.manifest = manifest
        self.session = session
    }

    public func check() { start(.check) }
    public func download() { start(.download) }
    public func delete() { start(.delete) }
    public func run() { start(.generate) }

    /// Requests cancellation but leaves controls busy until the worker has actually stopped.
    public func stop() {
        guard busy else { return }
        status = "Stopping…"
        activeRun?.cancel()
        task?.cancel()
    }

    /// Defers clearing until any current generation has drained, preventing stale text.
    public func newChat() {
        guard !busy || running else { return }
        pendingClear = true
        if busy { stop() } else { start(.clear) }
    }

    /// Called on inactivity; blocking prefill can only stop at the runtime's next callback.
    public func becameInactive() {
        if running { stop() }
    }

    /// Cancels work and releases the loaded model once all engine activity has drained.
    public func enteredBackground() {
        pendingUnload = true
        if busy { stop() } else { start(.unload) }
    }

    /// Deterministic synchronization for presentation lifecycle tests.
    func waitUntilIdle() async {
        while let current = task { await current.value }
    }

    private enum Operation { case check, download, delete, generate, clear, unload }

    private func start(_ operation: Operation) {
        guard !busy, let repository else { return }
        busy = true
        downloading = operation == .download
        running = operation == .generate
        if operation != .unload { error = nil }
        downloadedBytes = 0
        let id = UUID()
        let input = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if operation == .generate { prompt = "" }
        operationID = id
        if operation != .unload {
            status = downloading ? "Downloading and verifying model…" : "Checking model storage…"
        }
        task = Task {
            do {
                if loaded && operation != .generate && operation != .clear {
                    try await session.unload()
                    loaded = false
                }
                switch operation {
                case .check:
                    readyDirectory = try await repository.installedDirectory()
                    status =
                        readyDirectory == nil
                        ? "Model not downloaded." : "Model verified and ready."
                case .download:
                    readyDirectory = try await repository.install { [weak self] bytes in
                        Task { @MainActor in
                            guard let self, self.operationID == id else { return }
                            self.downloadedBytes = max(self.downloadedBytes, bytes)
                        }
                    }
                    status = "Model verified and ready."
                case .delete:
                    try await repository.delete()
                    readyDirectory = nil
                    status = "Model deleted."
                case .generate:
                    try await generate(input: input, repository: repository)
                case .clear:
                    break  // Deferred actions reset the session and clear the visible text.
                case .unload:
                    if error == nil { status = "Model unloaded. Run again when ready." }
                }
            } catch {
                if operation == .generate, messages.last?.role == .assistant {
                    messages[messages.count - 1].state =
                        error is CancellationError || (error as? URLError)?.code == .cancelled
                        ? .interrupted : .failed
                }
                if operation == .check || operation == .download || operation == .delete {
                    readyDirectory = nil
                }
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    status = "Stopped. You can retry."
                } else {
                    self.error = error.localizedDescription
                    status = "Operation failed."
                }
            }
            do { storedBytes = try await repository.storedBytes() } catch {
                self.error = "Could not read model storage usage: \(error.localizedDescription)"
            }
            await finishDeferredActions()
        }
    }

    private func generate(input: String, repository: ModelRepository) async throws {
        guard !input.isEmpty else { throw InferenceError.emptyPrompt }
        messages.append(ChatMessage(role: .user, text: input))
        let context = messages.compactMap { message -> ConversationMessage? in
            guard !message.text.isEmpty || !message.reasoning.isEmpty else { return nil }
            return ConversationMessage(
                role: message.role, content: message.text,
                reasoning: message.reasoning.isEmpty ? nil : message.reasoning)
        }
        let responseIndex = messages.count
        messages.append(ChatMessage(role: .assistant, text: "", state: .streaming))
        reasoning = ""
        answer = ""
        metrics = nil
        if !loaded {
            status = "Verifying and loading model…"
            loadMilliseconds = nil
            let start = Date()
            try await session.load(from: repository)
            loadMilliseconds = Date().timeIntervalSince(start) * 1_000
            loaded = true
        }
        try Task.checkCancellation()
        let run = try await session.generate(messages: context)
        activeRun = run
        if Task.isCancelled { run.cancel() }
        status = Task.isCancelled ? "Stopping…" : "Thinking…"
        var streamError: Error?
        do {
            for try await event in run.events {
                if Task.isCancelled { run.cancel(); break }
                switch event {
                case let .reasoning(text):
                    reasoning += text
                    messages[responseIndex].reasoning += text
                    status = "Thinking…"
                case let .answer(text):
                    answer += text
                    messages[responseIndex].text += text
                    status = "Answering…"
                case let .finished(value): metrics = value
                }
            }
        } catch { streamError = error }
        await run.waitUntilFinished()
        activeRun = nil
        if case let .failed(message) = await session.state {
            loaded = false
            throw PresentationFailure(message: message)
        }
        if let streamError { throw streamError }
        try Task.checkCancellation()
        messages[responseIndex].state = metrics?.finishReason == "length" ? .limited : .complete
        status = metrics?.finishReason == "length" ? "Output limit reached." : "Finished."
    }

    private func finishDeferredActions() async {
        // Main-actor callbacks can enqueue another action while reset/unload awaits the session.
        while pendingUnload || pendingClear {
            let unload = pendingUnload
            let clear = pendingClear
            pendingUnload = false
            pendingClear = false
            do {
                if unload {
                    try await session.unload()
                    loaded = false
                    if error == nil { status = "Model unloaded. Run again when ready." }
                }
                if clear {
                    if loaded { try await session.reset() }
                    prompt = ""
                    messages.removeAll()
                    reasoning = ""
                    answer = ""
                    metrics = nil
                    status = error == nil ? "New chat." : "Chat cleared after an error."
                }
            } catch {
                self.error = error.localizedDescription
                status = "Cleanup failed."
            }
        }
        operationID = nil
        downloading = false
        running = false
        busy = false
        task = nil
    }
}

private struct PresentationFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
