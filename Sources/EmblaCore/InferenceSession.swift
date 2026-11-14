import Foundation

/// Cancellation must remain accessible while the serial engine is inside synchronous GPU work.
private final class CancellationControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

/// A single run. Cancellation requests a stop; waiting proves the engine is actually idle.
public struct GenerationRun: Sendable {
    public let events: AsyncThrowingStream<InferenceEvent, Error>
    private let control: CancellationControl
    private let worker: Task<Void, Never>

    fileprivate init(
        events: AsyncThrowingStream<InferenceEvent, Error>,
        control: CancellationControl, worker: Task<Void, Never>
    ) {
        self.events = events
        self.control = control
        self.worker = worker
    }

    public func cancel() { control.cancel() }
    public func waitUntilFinished() async { await worker.value }
}

/// Gives blocking Metal work a dedicated serial queue instead of occupying cooperative threads.
private final class InferenceExecutor: SerialExecutor {
    private let queue = DispatchQueue(label: "embla.inference", qos: .userInitiated)

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = asUnownedSerialExecutor()
        queue.async { job.runSynchronously(on: executor) }
    }
}

/// Owns one loaded model and serializes loading, tokenization, generation, reset and unloading.
public actor InferenceSession {
    private nonisolated let executor = InferenceExecutor()
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    public enum State: Sendable, Equatable {
        case unloaded, loading, ready, generating
        case failed(String)
    }

    public private(set) var state: State = .unloaded
    private let factory: @Sendable (URL, Int) throws -> any InferenceBackend
    private var backend: (any InferenceBackend)?
    private var busy = false

    public init(factory: @escaping @Sendable (URL, Int) throws -> any InferenceBackend) {
        self.factory = factory
    }

    /// Revalidates stored assets before constructing the runtime, away from the main actor.
    public func load(from repository: ModelRepository, contextSize: Int = 8_192) async throws {
        guard !busy else { throw InferenceError.busy }
        guard contextSize > 1 && contextSize <= 262_144 else {
            throw InferenceError.invalidSettings
        }
        busy = true
        state = .loading
        backend = nil
        defer { busy = false }
        do {
            guard let directory = try await repository.installedDirectory() else {
                throw InferenceError.modelNotDownloaded
            }
            try Task.checkCancellation()
            let loaded = try factory(directory, contextSize)
            try Task.checkCancellation()
            backend = loaded
            state = .ready
        } catch {
            backend = nil
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    /// Returns a cancellable stream after validating the real tokenizer's prompt budget.
    public func generate(
        messages: [ConversationMessage], options: GenerationOptions = GenerationOptions()
    ) throws -> GenerationRun {
        guard !busy else { throw InferenceError.busy }
        guard let backend else { throw InferenceError.notLoaded }
        guard
            messages.contains(where: {
                $0.role == .user
                    && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })
        else { throw InferenceError.emptyPrompt }
        guard options.maxTokens > 0, options.temperature.isFinite, options.temperature >= 0,
            options.topP.isFinite, options.topP > 0, options.topP <= 1
        else {
            throw InferenceError.invalidSettings
        }
        let prompt = try backend.encode(messages)
        let room = max(0, backend.contextSize - prompt.count - 1)
        guard !prompt.isEmpty, options.maxTokens <= room else {
            throw InferenceError.contextExceeded(promptTokens: prompt.count, availableOutput: room)
        }
        try Task.checkCancellation()
        let control = CancellationControl()
        let (events, continuation) = AsyncThrowingStream<InferenceEvent, Error>.makeStream()
        continuation.onTermination = { reason in
            if case .cancelled = reason { control.cancel() }
        }
        busy = true
        state = .generating
        let worker = Task {
            self.perform(
                backend: backend, prompt: prompt, options: options,
                control: control, continuation: continuation
            )
        }
        return GenerationRun(events: events, control: control, worker: worker)
    }

    /// Counts the complete upstream template, including its generation prefix.
    public func tokenCount(messages: [ConversationMessage]) throws -> Int {
        guard !busy else { throw InferenceError.busy }
        guard let backend else { throw InferenceError.notLoaded }
        return try backend.encode(messages).count
    }

    /// Call after cancelling and awaiting any active run, including when entering the background.
    public func unload() throws {
        guard !busy else { throw InferenceError.busy }
        backend = nil
        state = .unloaded
    }

    /// Clears runtime state after a completed run; the application owns conversation text.
    public func reset() throws {
        guard !busy else { throw InferenceError.busy }
        guard let backend else { throw InferenceError.notLoaded }
        backend.reset()
        state = .ready
    }

    private func perform(
        backend: any InferenceBackend, prompt: [Int], options: GenerationOptions,
        control: CancellationControl,
        continuation: AsyncThrowingStream<InferenceEvent, Error>.Continuation
    ) {
        defer { busy = false }
        do {
            guard !control.isCancelled else { throw CancellationError() }
            let metrics = try backend.generate(prompt: prompt, options: options) { delta in
                guard !control.isCancelled else { return false }
                let event: InferenceEvent
                switch delta {
                case let .reasoning(text): event = .reasoning(text)
                case let .answer(text): event = .answer(text)
                }
                if case .terminated = continuation.yield(event) {
                    control.cancel()
                    return false
                }
                return true
            }
            guard !control.isCancelled else { throw CancellationError() }
            backend.reset()
            state = .ready
            continuation.yield(.finished(metrics))
            continuation.finish()
        } catch {
            if control.isCancelled || error is CancellationError {
                backend.reset()
                state = .ready
                continuation.finish(throwing: CancellationError())
            } else {
                self.backend = nil
                state = .failed(error.localizedDescription)
                continuation.finish(throwing: error)
            }
        }
    }
}
