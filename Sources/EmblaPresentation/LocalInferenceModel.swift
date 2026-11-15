import Foundation
import Observation

import EmblaCore
import EmblaRuntime

/// A visible turn in the single active conversation.
public struct ChatMessage: Identifiable, Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case streaming, complete, interrupted, failed, limited
    }
    public let id: UUID
    public let role: ConversationMessage.Role
    public var text: String
    public var reasoning = ""
    public var state: State = .complete

    public init(
        id: UUID = UUID(), role: ConversationMessage.Role, text: String,
        reasoning: String = "", state: State = .complete
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.reasoning = reasoning
        self.state = state
    }
}

/// Shared presentation state for model setup and the single active conversation.
@MainActor @Observable
public final class LocalInferenceModel {
    public private(set) var conversationID = UUID()
    public private(set) var compaction = CompactionState() {
        didSet { refreshContextUsage() }
    }
    public private(set) var compacting = false
    @ObservationIgnored private let compactionPolicy = ContextCompaction()
    public var prompt = "" {
        didSet { scheduleChatSave(); refreshContextUsage() }
    }
    public private(set) var messages: [ChatMessage] = [] {
        didSet { refreshContextUsage() }
    }
    public private(set) var manifest: ModelManifest?
    public private(set) var readyDirectory: URL? {
        didSet { refreshContextUsage() }
    }
    public private(set) var storedBytes: Int64 = 0
    public private(set) var downloadedBytes: Int64 = 0
    public private(set) var status = "Checking model storage…"
    public private(set) var busy = false
    public private(set) var downloading = false
    public private(set) var running = false
    public private(set) var resetting = false
    public private(set) var loaded = false
    public private(set) var error: String?
    public private(set) var reasoning = ""
    public private(set) var answer = ""
    public private(set) var metrics: GenerationMetrics?
    public private(set) var loadMilliseconds: Double?
    public let cloud: ConversationCloudSync
    public private(set) var chatRestored = false
    public private(set) var storageStatus = "Opening saved chat…"
    public private(set) var storageError: String?
    public private(set) var contextUsage: ContextUsageState = .unavailable("Checking model storage…")
    @ObservationIgnored private var usageTask: Task<Void, Never>?
    @ObservationIgnored private var usageRequest = UUID()
    @ObservationIgnored private var usageActive = true
    @ObservationIgnored private let countTokens:
        (@Sendable (URL, [ConversationMessage]) async throws -> Int)?
    @ObservationIgnored private var chatStore: (any ConversationStoring)?
    @ObservationIgnored private var chatStoreFactory: (() throws -> any ConversationStoring)?
    @ObservationIgnored private var saveTask: Task<Void, Error>?
    @ObservationIgnored private var checkpointTask: Task<Void, Never>?
    @ObservationIgnored private var persistenceSequence: UInt64 = 0
    @ObservationIgnored private var lastSnapshot: ConversationSnapshot?
    private struct PersistedCloudSettings: Sendable {
        var enabled = false
        var bookmark: Data?
        var base: String?
    }
    @ObservationIgnored private var persistedCloudSettings = PersistedCloudSettings()
    @ObservationIgnored private var restoringChat = false
    @ObservationIgnored private var replacingContext = false
    @ObservationIgnored private var repository: ModelRepository?
    @ObservationIgnored private let session: InferenceSession
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var activeRun: GenerationRun?
    @ObservationIgnored private var operationID: UUID?
    @ObservationIgnored private var pendingUnload = false
    @ObservationIgnored private var pendingClear = false
    @ObservationIgnored private var replacementWaiters: [CheckedContinuation<Void, Never>] = []

    public var canRun: Bool {
        !busy && !resetting && !cloud.resolving && chatRestored && storageError == nil && readyDirectory != nil
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Production always uses the pinned Embla runtime and app-managed model storage.
    public init() {
        session = EmblaRuntime.makeSession()
        let tokenizer = EmblaPromptTokenizer()
        countTokens = { directory, messages in
            try await tokenizer.count(messages: messages, in: directory)
        }
        cloud = ConversationCloudSync()
        configureCloud()
        chatStoreFactory = { ConversationStore(root: try ConversationStore.defaultRoot()) }
        do { chatStore = try chatStoreFactory?() } catch {
            storageError = error.localizedDescription
            storageStatus = "Chat storage is unavailable."
        }
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
    init(
        repository: ModelRepository?, manifest: ModelManifest, session: InferenceSession,
        chatStore: (any ConversationStoring)? = nil, cloud: ConversationCloudSync? = nil,
        chatStoreFactory: (() throws -> any ConversationStoring)? = nil,
        countTokens: (@Sendable (URL, [ConversationMessage]) async throws -> Int)? = nil
    ) {
        self.repository = repository
        self.manifest = manifest
        self.session = session
        self.countTokens = countTokens
        self.cloud = cloud ?? ConversationCloudSync()
        configureCloud()
        self.chatStore = chatStore
        self.chatStoreFactory = chatStoreFactory
        chatRestored = chatStore == nil && chatStoreFactory == nil
        if chatRestored { storageStatus = "Test session without persistence." }
        if repository == nil {
            error = "Model setup is unavailable."
            status = "Model setup is unavailable."
        }
    }

    public func check() { start(.check) }
    public func download() { start(.download) }
    public func delete() { start(.delete) }
    public func run() { start(.generate) }

    /// Explicitly summarizes eligible older turns even below the automatic threshold.
    public func compactNow() {
        guard manualCompactionUnavailableReason == nil else { return }
        start(.compact)
    }

    public var manualCompactionUnavailableReason: String? {
        if !chatRestored || resetting { return "Wait for the saved chat to open." }
        if storageError != nil { return "Resolve the chat storage error first." }
        if busy || cloud.resolving { return "Wait for the current operation or stop it first." }
        if readyDirectory == nil { return "Download and verify the model in Settings first." }
        let transcript = conversationMessages() + [ConversationMessage(role: .user, content: prompt)]
        guard (try? compactionPolicy.plan(transcript: transcript, state: compaction)) != nil else {
            return "No older turns can be compacted yet. The latest two exchanges are kept verbatim."
        }
        return nil
    }

    /// Debounces draft/stream changes and rejects results from superseded chat snapshots.
    public func refreshContextUsage() {
        usageTask?.cancel()
        let request = UUID()
        usageRequest = request
        guard usageActive else {
            contextUsage = .unavailable("Context usage updates when the app is active.")
            return
        }
        guard chatRestored, !restoringChat, !resetting else {
            contextUsage = .unavailable("Opening the saved chat…")
            return
        }
        guard let directory = readyDirectory else {
            contextUsage = .unavailable("Download and verify the model in Settings first.")
            return
        }
        // Internal fixture construction may omit counting; production always supplies it.
        guard let countTokens else { return }
        contextUsage = .counting
        usageTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(180))
                guard let self, self.usageRequest == request else { return }
                let context = self.compactionPolicy.context(
                    transcript: self.conversationMessages(), state: self.compaction,
                    draft: self.prompt.trimmingCharacters(in: .whitespacesAndNewlines))
                let count = try await countTokens(directory, context)
                try Task.checkCancellation()
                guard self.usageRequest == request else { return }
                self.contextUsage = .ready(ContextUsage(
                    inputTokens: count, capacity: self.compactionPolicy.contextSize,
                    replyReserve: self.compactionPolicy.responseTokens,
                    summaryReserve: self.compactionPolicy.summaryTokens, headroom: 256))
            } catch {
                guard let self, self.usageRequest == request, !Task.isCancelled else { return }
                self.contextUsage = .failed(error.localizedDescription)
            }
        }
    }

    private func conversationMessages() -> [ConversationMessage] {
        messages.map {
            ConversationMessage(role: $0.role, content: $0.text,
                reasoning: $0.reasoning.isEmpty ? nil : $0.reasoning)
        }
    }

    /// Requests cancellation but leaves controls busy until the worker has actually stopped.
    public func stop() {
        guard busy else { return }
        status = "Stopping…"
        activeRun?.cancel()
        task?.cancel()
    }

    /// Defers clearing until any current generation has drained, preventing stale text.
    public func newChat() {
        guard chatRestored, !cloud.resolving, !busy || running else { return }
        cloud.pause()
        cloud.refresh()
        resetting = true
        pendingClear = true
        if busy { stop() } else { start(.clear) }
    }

    /// Called on inactivity; blocking prefill can only stop at the runtime's next callback.
    public func becameInactive() {
        cloud.setForeground(false)
        usageActive = false
        refreshContextUsage()
        scheduleChatSave(immediately: true)
        if running { stop() }
    }

    /// Cancels work and releases the loaded model once all engine activity has drained.
    public func becameActive() {
        cloud.setForeground(true)
        usageActive = true
        refreshContextUsage()
    }

    public func enteredBackground() {
        usageActive = false
        refreshContextUsage()
        cloud.setForeground(false)
        pendingUnload = true
        if busy { stop() } else { start(.unload) }
    }

    /// Deterministic synchronization for presentation lifecycle tests.
    func waitUntilIdle() async {
        while let current = task { await current.value }
    }

    /// Lets tests await a debounced count without timing assumptions.
    func waitForContextUsage() async { await usageTask?.value }

    private enum Operation { case check, download, delete, generate, compact, clear, unload }

    private func start(_ operation: Operation) {
        guard !busy, !cloud.resolving, !resetting || operation == .clear,
            (operation != .generate && operation != .compact) || chatRestored else { return }
        busy = true
        downloading = operation == .download
        running = operation == .generate || operation == .compact
        if operation != .unload && repository != nil { error = nil }
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
                if operation != .delete { try await restoreChatIfNeeded() }
                if loaded && operation != .generate && operation != .compact && operation != .clear {
                    try await session.unload()
                    loaded = false
                }
                switch operation {
                case .check:
                    readyDirectory = try await requireRepository().installedDirectory()
                    status =
                        readyDirectory == nil
                        ? "Model not downloaded." : "Model verified and ready."
                case .download:
                    readyDirectory = try await requireRepository().install { [weak self] bytes in
                        Task { @MainActor in
                            guard let self, self.operationID == id else { return }
                            self.downloadedBytes = max(self.downloadedBytes, bytes)
                        }
                    }
                    status = "Model verified and ready."
                case .delete:
                    try await requireRepository().delete()
                    readyDirectory = nil
                    status = "Model deleted."
                case .generate:
                    try await generate(input: input, repository: requireRepository())
                case .compact:
                    try await loadModelIfNeeded(repository: requireRepository())
                    _ = try await prepareContext(
                        transcript: conversationMessages(), draft: input, force: true)
                    status = "Earlier messages compacted."
                case .clear:
                    break  // Deferred actions reset the session and clear the visible text.
                case .unload:
                    if error == nil { status = "Model unloaded. Run again when ready." }
                }
            } catch {
                if operation == .generate, messages.last?.role == .assistant,
                    messages.last?.state == .streaming
                {
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
            if let repository {
                do { storedBytes = try await repository.storedBytes() } catch {
                    self.error = "Could not read model storage usage: \(error.localizedDescription)"
                }
            }
            if chatRestored && operation != .clear {
                do { try await saveChatNow() } catch { /* Storage diagnostics stay visible. */ }
            }
            await finishDeferredActions()
        }
    }

    private func requireRepository() throws -> ModelRepository {
        guard let repository else {
            throw PresentationFailure(message: error ?? "Model setup is unavailable.")
        }
        return repository
    }

    private func generate(input: String, repository: ModelRepository) async throws {
        guard !input.isEmpty else { throw InferenceError.emptyPrompt }
        messages.append(ChatMessage(role: .user, text: input))
        let responseIndex = messages.count
        messages.append(ChatMessage(role: .assistant, text: "", state: .streaming))
        reasoning = ""
        answer = ""
        metrics = nil
        try await saveChatNow()
        try await loadModelIfNeeded(repository: repository)
        try Task.checkCancellation()
        let transcript = messages.dropLast().map {
            ConversationMessage(
                role: $0.role, content: $0.text,
                reasoning: $0.reasoning.isEmpty ? nil : $0.reasoning)
        }
        let context = try await prepareContext(transcript: transcript)
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
                scheduleChatSave()
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

    private func loadModelIfNeeded(repository: ModelRepository) async throws {
        if !loaded {
            status = "Verifying and loading model…"
            loadMilliseconds = nil
            let start = Date()
            try await session.load(from: repository)
            loadMilliseconds = Date().timeIntervalSince(start) * 1_000
            loaded = true
        }
    }

    /// Summarizes through the same serial session and atomically replaces only inference context.
    private func prepareContext(
        transcript: [ConversationMessage], draft: String? = nil, force: Bool = false
    ) async throws
        -> [ConversationMessage]
    {
        let context = compactionPolicy.context(transcript: transcript, state: compaction, draft: draft)
        if !force {
            let count = try await session.tokenCount(messages: context)
            if count <= compactionPolicy.triggerTokens { return context }
        }
        compacting = true
        status = "Compacting earlier messages…"
        defer { compacting = false }
        let planning = transcript + (draft.map { [ConversationMessage(role: .user, content: $0)] } ?? [])
        let plan = try compactionPolicy.plan(transcript: planning, state: compaction)
        let run = try await session.generate(
            messages: plan.messages,
            options: GenerationOptions(maxTokens: compactionPolicy.summaryTokens))
        activeRun = run
        if Task.isCancelled { run.cancel() }
        var summary = ""
        var finishReason: String?
        var streamError: Error?
        do {
            for try await event in run.events {
                if Task.isCancelled { run.cancel(); break }
                switch event {
                case let .answer(text): summary += text
                case let .finished(metrics): finishReason = metrics.finishReason
                case .reasoning: break
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
        let candidate = try compactionPolicy.candidate(
            text: summary, finishReason: finishReason, plan: plan)
        let compacted = compactionPolicy.context(transcript: transcript, state: candidate, draft: draft)
        let count = try await session.tokenCount(messages: compacted)
        guard count + compactionPolicy.responseTokens < compactionPolicy.contextSize else {
            throw CompactionError.summaryDoesNotFit
        }
        try Task.checkCancellation()
        if force {
            replacingContext = true
            let snapshot = ConversationSnapshot(
                conversationID: conversationID, messages: messages, compaction: candidate)
            try await saveChatNow(snapshot: snapshot)
        }
        compaction = candidate
        return compacted
    }

    /// Retries local persistence explicitly; corrupt startup data is never replaced with empty state.
    public func retryChatStorage() {
        if !chatRestored { check(); return }
        Task {
            do { try await saveChatNow() } catch { /* saveChatNow exposes the failure. */ }
        }
    }

    /// Drains checkpoints for deterministic persistence/lifecycle tests.
    func flushChatStorage() async throws { try await saveChatNow() }

    private func restoreChatIfNeeded() async throws {
        guard !chatRestored else { return }
        do {
            if chatStore == nil { chatStore = try chatStoreFactory?() }
            guard let chatStore else {
                throw PresentationFailure(message: storageError ?? "Chat storage is unavailable.")
            }
            let existing = try await chatStore.load()
            let archive = (existing ?? ConversationArchive(
                sequence: 1,
                snapshot: ConversationSnapshot(
                    conversationID: conversationID, messages: [], compaction: CompactionState())
            )).recoveringInterruptedResponses()
            if existing == nil || archive != existing { try await chatStore.save(archive) }
            restoringChat = true
            conversationID = archive.snapshot.conversationID
            messages = archive.snapshot.messages
            compaction = archive.snapshot.compaction
            prompt = archive.draft
            persistenceSequence = archive.sequence
            lastSnapshot = archive.snapshot
            persistedCloudSettings = PersistedCloudSettings(
                enabled: archive.cloudEnabled, bookmark: archive.cloudFolderBookmark,
                base: archive.cloudBaseFingerprint)
            cloud.restore(
                enabled: archive.cloudEnabled, bookmark: archive.cloudFolderBookmark,
                base: archive.cloudBaseFingerprint)
            restoringChat = false
            chatRestored = true
            storageError = nil
            storageStatus = "Saved on this device."
        } catch {
            storageError = error.localizedDescription
            storageStatus = "Could not open the saved chat."
            throw error
        }
    }

    /// Coalesces streamed updates, while draft changes and background transitions also checkpoint.
    private func scheduleChatSave(immediately: Bool = false) {
        guard chatRestored, chatStore != nil, !restoringChat, !resetting, !replacingContext else { return }
        if immediately { checkpointTask?.cancel(); checkpointTask = nil }
        storageStatus = "Saving on this device…"
        guard checkpointTask == nil else { return }
        checkpointTask = Task { [weak self] in
            do {
                if !immediately { try await Task.sleep(for: .milliseconds(500)) }
                try Task.checkCancellation()
                guard let self else { return }
                self.checkpointTask = nil
                try await self.saveChatNow()
            } catch { /* Cancellation is expected; save errors are exposed by saveChatNow. */ }
        }
    }

    /// Captures on the main actor and queues writes in order; only the latest write sets status.
    private func saveChatNow(
        snapshot replacement: ConversationSnapshot? = nil, draft: String? = nil,
        notifyCloud: Bool = true, cloudSettings requestedSettings: PersistedCloudSettings? = nil
    ) async throws {
        guard chatRestored, let chatStore else { return }
        checkpointTask?.cancel()
        checkpointTask = nil
        var snapshot = replacement ?? ConversationSnapshot(
            conversationID: conversationID, messages: messages, compaction: compaction)
        if replacement == nil, let lastSnapshot,
            lastSnapshot.conversationID == snapshot.conversationID,
            lastSnapshot.messages == snapshot.messages, lastSnapshot.compaction == snapshot.compaction
        {
            snapshot.revision = lastSnapshot.revision
        }
        // A replacement is not the visible conversation until its write succeeds.
        if replacement == nil { lastSnapshot = snapshot }
        persistenceSequence += 1
        let sequence = persistenceSequence
        let pendingArchive = ConversationArchive(
            sequence: sequence, snapshot: snapshot, draft: draft ?? prompt)
        storageStatus = "Saving on this device…"
        let previous = saveTask
        let write = Task {
            if let previous { _ = await previous.result }
            // Ordinary checkpoints inherit settings from the preceding successful write,
            // never from an opt-in whose own save is still pending or has failed.
            var settings = requestedSettings ?? self.persistedCloudSettings
            if requestedSettings == nil && !self.cloud.enabled { settings.enabled = false }
            var archive = pendingArchive
            archive.cloudEnabled = settings.enabled
            archive.cloudFolderBookmark = settings.bookmark
            archive.cloudBaseFingerprint = settings.base
            try await chatStore.save(archive)
            self.persistedCloudSettings = settings
            self.cloud.settingsSaved(enabled: settings.enabled)
        }
        saveTask = write
        do {
            try await write.value
            if replacement != nil { lastSnapshot = snapshot }
            if notifyCloud && cloud.enabled { cloud.requestSync() }
            if sequence == persistenceSequence && checkpointTask == nil {
                storageError = nil
                storageStatus = "Saved on this device."
            }
        } catch {
            if sequence == persistenceSequence {
                storageError = error.localizedDescription
                storageStatus = "Chat has unsaved changes."
            }
            throw error
        }
    }

    private func currentSnapshot() -> ConversationSnapshot {
        var snapshot = ConversationSnapshot(
            conversationID: conversationID, messages: messages, compaction: compaction)
        if let lastSnapshot, lastSnapshot.conversationID == conversationID,
            lastSnapshot.messages == messages, lastSnapshot.compaction == compaction
        {
            snapshot.revision = lastSnapshot.revision
        }
        return snapshot
    }

    private func configureCloud() {
        cloud.current = { [weak self] in
            guard let self, self.chatRestored else { return nil }
            return CloudLocalConversation(
                snapshot: self.currentSnapshot(), hasDraft: !self.prompt.isEmpty,
                canReplace: !self.busy && !self.resetting && self.storageError == nil)
        }
        cloud.persist = { [weak self] in
            guard let self else { throw CancellationError() }
            // A replacement publishes its transcript only after the new archive is durable.
            // Preference writes must capture that published state, never the old visible chat.
            while self.resetting || self.replacingContext {
                await withCheckedContinuation { self.replacementWaiters.append($0) }
            }
            let settings = PersistedCloudSettings(
                enabled: self.cloud.enabled, bookmark: self.cloud.bookmark,
                base: self.cloud.baseFingerprint)
            try await self.saveChatNow(notifyCloud: false, cloudSettings: settings)
        }
        cloud.apply = { [weak self] snapshot, expected in
            guard let self else { throw CancellationError() }
            try await self.applyCloudSnapshot(snapshot, expected: expected)
        }
    }

    private func applyCloudSnapshot(_ snapshot: ConversationSnapshot, expected: String) async throws {
        guard !busy, !resetting, try currentSnapshot().fingerprint() == expected else {
            throw CloudConversationError.changed
        }
        try Task.checkCancellation()
        busy = true
        resetting = true
        let recovered = ConversationArchive(sequence: 0, snapshot: snapshot)
            .recoveringInterruptedResponses().snapshot
        do {
            if loaded { try await session.reset() }
            try await saveChatNow(snapshot: recovered, draft: "", notifyCloud: false)
            restoringChat = true
            messages = recovered.messages
            compaction = recovered.compaction
            conversationID = recovered.conversationID
            prompt = ""
            reasoning = ""
            answer = ""
            metrics = nil
            restoringChat = false
            status = "Restored the iCloud chat."
        } catch {
            await finishDeferredActions()
            throw error
        }
        await finishDeferredActions()
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
                    let newID = UUID()
                    let snapshot = ConversationSnapshot(
                        conversationID: newID, messages: [], compaction: CompactionState())
                    try await saveChatNow(snapshot: snapshot, draft: "")
                    restoringChat = true
                    prompt = ""
                    messages.removeAll()
                    compaction = CompactionState()
                    reasoning = ""
                    answer = ""
                    metrics = nil
                    conversationID = newID
                    restoringChat = false
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
        resetting = false
        replacingContext = false
        let waiters = replacementWaiters
        replacementWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        busy = false
        task = nil
        cloud.resume()
        refreshContextUsage()
    }
}

private struct PresentationFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
