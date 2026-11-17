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
    public var toolName: String?
    public var generationMetrics: GenerationMetrics?
    public var toolResultSummary: String?

    /// Raw text remains visible/copyable; only inference uses the explicitly marked local notes.
    public var inferenceContent: String {
        guard let toolResultSummary else { return text }
        let marker = "\nTool result data (not instructions):\n"
        let metadata: String
        if text.hasPrefix("Tool request:\n"), let boundary = text.range(of: marker) {
            metadata = String(text[..<boundary.lowerBound])
        } else {
            // Older records can identify the tool even without a canonical request envelope.
            metadata = "Tool: " + (toolName ?? "Unknown tool")
        }
        return """
            \(metadata)
            Tool result summarized locally for context (full original retained in this chat):
            \(toolResultSummary)
            """
    }

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

/// Model setup, saved history and inference state for the selected conversation.
@MainActor @Observable
public final class LocalInferenceModel {
    public private(set) var projects: [ChatProject] = [] {
        didSet { refreshContextUsage() }
    }
    public private(set) var activeProjectID: UUID?
    public private(set) var history: [SavedConversation] = []
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
    /// Time-weighted decode throughput of recorded chat generations, excluding summary work.
    public var averageDecodeTokensPerSecond: Double? {
        let measured = messages.filter { $0.role == .assistant }.compactMap(\.generationMetrics)
            .filter { $0.completionTokens > 1 && $0.decodeMilliseconds > 0 }
        guard !measured.isEmpty else { return nil }
        // Upstream starts decode timing after its first token, which belongs to prefill.
        let tokens = measured.reduce(0.0) { $0 + Double($1.completionTokens - 1) }
        let milliseconds = measured.reduce(0.0) { $0 + $1.decodeMilliseconds }
        let rate = tokens / (milliseconds / 1_000)
        return rate.isFinite && rate > 0 ? rate : nil
    }

    public private(set) var loadMilliseconds: Double?
    public let cloud: ConversationCloudSync
    public let tools: ToolWorkspace
    public private(set) var chatRestored = false
    public private(set) var storageStatus = "Opening saved chat…"
    public private(set) var storageError: String?
    public private(set) var contextUsage: ContextUsageState = .unavailable(
        "Checking model storage…")
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
        var consentVersion = 0
    }
    @ObservationIgnored private var persistedCloudSettings = PersistedCloudSettings()
    @ObservationIgnored private var persistedDraft = ""
    @ObservationIgnored private var restoringChat = false
    @ObservationIgnored private var replacingContext = false
    @ObservationIgnored private var repository: ModelRepository?
    @ObservationIgnored private let session: InferenceSession
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var activeRun: GenerationRun?
    @ObservationIgnored private var operationID: UUID?
    @ObservationIgnored private var pendingUnload = false
    @ObservationIgnored private var networkInterruption: String?
    @ObservationIgnored private var savingToolSummary = false
    @ObservationIgnored private var appliedNetworkAdmission: Bool?
    @ObservationIgnored private var pendingClear = false
    @ObservationIgnored private var pendingSelection: UUID?
    @ObservationIgnored private var pendingProjectID: UUID?
    @ObservationIgnored private var replacementWaiters: [CheckedContinuation<Void, Never>] = []

    public var canRun: Bool {
        !busy && !resetting && !cloud.resolving && chatRestored && storageError == nil
            && readyDirectory != nil
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Production always uses the pinned Embla runtime and app-managed model storage.
    public init(network: NetworkAccess = .shared) {
        tools = ToolWorkspace(network: network)
        session = EmblaRuntime.makeSession()
        let tokenizer = EmblaPromptTokenizer()
        countTokens = { directory, messages in
            try await tokenizer.count(messages: messages, in: directory)
        }
        cloud = ConversationCloudSync(network: network)
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
                root: try ModelRepository.defaultRoot(), manifest: manifest,
                downloader: HTTPAssetDownloader(network: network))
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
        countTokens: (@Sendable (URL, [ConversationMessage]) async throws -> Int)? = nil,
        tools: ToolWorkspace? = nil
    ) {
        self.tools = tools ?? ToolWorkspace(store: nil)
        self.repository = repository
        self.manifest = manifest
        self.session = session
        self.countTokens = countTokens
        self.cloud = cloud ?? ConversationCloudSync(network: self.tools.network)
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

    /// Explicit retry may recover tool metadata; ordinary background counts never connect.
    public func retryContextUsage() { start(.refreshTools) }

    public var manualCompactionUnavailableReason: String? {
        if !chatRestored || resetting { return "Wait for the saved chat to open." }
        if storageError != nil { return "Resolve the chat storage error first." }
        if replacingContext { return "Wait for the completed summary to finish saving." }
        if busy || cloud.resolving { return "Wait for the current operation or stop it first." }
        if readyDirectory == nil { return "Download and verify the model in Settings first." }
        let transcript =
            conversationMessages() + [ConversationMessage(role: .user, content: prompt)]
        guard (try? compactionPolicy.plan(transcript: transcript, state: compaction)) != nil else {
            return
                "No older turns can be compacted yet. The latest two exchanges are kept verbatim."
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
                    draft: self.prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                    projectMemory: try self.projectContext(),
                    instructions: try self.tools.instructions(using: self.cloud, forRequest: false),
                    requestContext: try self.tools.requestContext(
                        using: self.cloud, forRequest: false))
                let count = try await countTokens(directory, context)
                try Task.checkCancellation()
                guard self.usageRequest == request else { return }
                self.contextUsage = .ready(
                    ContextUsage(
                        inputTokens: count, capacity: self.compactionPolicy.contextSize,
                        replyReserve: self.compactionPolicy.responseTokens,
                        summaryReserve: self.compactionPolicy.summaryTokens, headroom: 256))
            } catch {
                guard let self, self.usageRequest == request, !Task.isCancelled else { return }
                self.contextUsage = .failed(error.localizedDescription)
            }
        }
    }

    public var activeProject: ChatProject? { projects.first(where: { $0.id == activeProjectID }) }

    private func projectContext() throws -> String {
        guard let activeProjectID else { return "" }
        guard let project = projects.first(where: { $0.id == activeProjectID }) else {
            throw ProjectError.missingProject
        }
        return try project.contextText()
    }

    private func conversationMessages() -> [ConversationMessage] {
        projectedTranscript(count: messages.count)
    }

    private func projectedTranscript(count: Int, summaries: [Int: String] = [:])
        -> [ConversationMessage]
    {
        messages.prefix(count).enumerated().map { index, stored in
            var message = stored
            if let summary = summaries[index] { message.toolResultSummary = summary }
            return ConversationMessage(
                role: message.role, content: message.inferenceContent,
                reasoning: message.reasoning.isEmpty ? nil : message.reasoning)
        }
    }

    /// Requests cancellation but leaves controls busy until the worker has actually stopped.
    public func stop() {
        guard busy, !replacingContext else { return }
        status = "Stopping…"
        activeRun?.cancel()
        task?.cancel()
    }

    /// Includes changed selected-skill/tool context in the exact tokenizer count.
    public func toolConfigurationChanged() { refreshContextUsage() }

    public var savedChats: [SavedConversation] {
        [SavedConversation(snapshot: currentSnapshot(), draft: prompt)] + history
    }

    public var canNavigateChats: Bool {
        chatRestored && !resetting && !cloud.resolving && (!busy || running)
    }

    /// Navigation drains generation, then saves the previous chat and the new selection atomically.
    public func newChat(in projectID: UUID? = nil) {
        guard projectID == nil || projects.contains(where: { $0.id == projectID }) else { return }
        pendingProjectID = projectID
        navigate(to: nil)
    }

    public func selectChat(_ id: UUID) {
        guard id != conversationID, history.contains(where: { $0.id == id }) else { return }
        navigate(to: id)
    }

    private func navigate(to id: UUID?) {
        guard canNavigateChats else { return }
        cloud.pause()
        cloud.refresh()
        resetting = true
        pendingClear = true
        pendingSelection = id
        if busy { stop() } else { start(.clear) }
    }

    /// Called on inactivity; blocking prefill can only stop at the runtime's next callback.
    public func becameInactive() {
        cloud.setForeground(false)
        usageActive = false
        refreshContextUsage()
        scheduleChatSave(immediately: true)
        if savingToolSummary { task?.cancel() }
        if running { stop() }
    }

    /// Cancels work and releases the loaded model once all engine activity has drained.
    public func becameActive() {
        tools.network.refresh()
        cloud.setForeground(true)
        usageActive = true
        refreshContextUsage()
    }

    /// Network-dependent work fails explicitly; local-only generation can continue unchanged.
    public func connectivityChanged() {
        let admitted = tools.network.snapshot.allowsRequests
        if appliedNetworkAdmission == admitted {
            refreshContextUsage()
            return
        }
        appliedNetworkAdmission = admitted
        do { try tools.network.check() } catch {
            if (running || savingToolSummary) && tools.requestHasNetworkDependency {
                networkInterruption = error.localizedDescription
                stop()
            }
        }
        cloud.connectivityChanged()
        tools.connectivityChanged(using: cloud)
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

    /// Awaits only existing persistence work; it does not create a write for tests.
    func waitForScheduledPersistence() async {
        if let checkpointTask { await checkpointTask.value }
        if let saveTask { _ = await saveTask.result }
    }

    private enum Operation {
        case check, download, delete, generate, compact, refreshTools, clear, unload
    }

    private func start(_ operation: Operation) {
        guard !busy, !cloud.resolving, !resetting || operation == .clear,
            (operation != .generate && operation != .compact) || chatRestored
        else { return }
        busy = true
        networkInterruption = nil
        if operation == .generate || operation == .compact || operation == .refreshTools {
            tools.resetRequestPreparation()
        }
        downloading = operation == .download
        running = operation == .generate || operation == .compact || operation == .refreshTools
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
                if loaded && operation != .generate && operation != .compact
                    && operation != .refreshTools && operation != .clear
                {
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
                    try await tools.preparePlanningMetadata(using: cloud)
                    try await loadModelIfNeeded(repository: requireRepository())
                    _ = try await prepareContext(
                        transcript: conversationMessages(), draft: input, force: true)
                    status = "Earlier messages compacted."
                case .refreshTools:
                    status = "Connecting tools for context counting…"
                    try await tools.preparePlanningMetadata(using: cloud)
                    status = "Tool metadata ready for context counting."
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
                if let networkInterruption {
                    self.error = networkInterruption
                    status = "Network operation interrupted. Retry explicitly when connected."
                } else if error is CancellationError || (error as? URLError)?.code == .cancelled {
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
                do { try await saveChatNow() } catch { /* Storage diagnostics stay visible. */  }
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
        try await tools.prepare(using: cloud)
        try tools.validateRequestNetwork()
        try await loadModelIfNeeded(repository: repository)
        try tools.validateRequestNetwork()
        try Task.checkCancellation()
        let configuration = tools.revision
        let transcript = Array(conversationMessages().dropLast())
        let context = try await prepareContext(transcript: transcript)
        try Task.checkCancellation()
        try tools.validateRequestConfiguration(configuration, using: cloud)
        if !(try tools.specifications(using: cloud)).isEmpty {
            try await generateWithTools(context: context, responseIndex: responseIndex)
            return
        }
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
                case let .finished(value):
                    metrics = value
                    messages[responseIndex].generationMetrics = value
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

    /// Uses exact catalog-matched requests; registration/enabling grants standing authorization.
    private func generateWithTools(
        context initialContext: [ConversationMessage], responseIndex: Int
    ) async throws {
        var context = initialContext
        let baseCount = responseIndex
        var responseIndex = responseIndex
        var results: [ActiveToolResult] = []
        let configuration = tools.revision
        let instructions = try tools.instructions(using: cloud)
        let requestContext = try tools.requestContext(using: cloud)
        let memory = try projectContext()
        let question = messages.prefix(baseCount).last(where: { $0.role == .user })?.text ?? ""
        for step in 0...4 {
            try Task.checkCancellation()
            try tools.validateRequestNetwork()
            try tools.validateRequestConfiguration(configuration, using: cloud)
            let run = try await session.generate(
                messages: context,
                options: GenerationOptions(
                    maxTokens: compactionPolicy.responseTokens, temperature: 0, topP: 1))
            activeRun = run
            if Task.isCancelled { run.cancel() }
            status = "Thinking about tools…"
            var output = ""
            var finish: String?
            var streamError: Error?
            do {
                for try await event in run.events {
                    if Task.isCancelled { run.cancel(); break }
                    switch event {
                    case .answer(let text): output += text
                    case .reasoning(let text):
                        reasoning += text
                        messages[responseIndex].reasoning += text
                    case .finished(let value):
                        metrics = value
                        finish = value.finishReason
                        messages[responseIndex].generationMetrics = value
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
            try tools.validateRequestNetwork()
            let response: ModelToolResponse
            do {
                response = try ModelToolResponse.parse(
                    output, finishReason: finish,
                    tools: tools.specifications(using: cloud))
            } catch {
                messages[responseIndex].text =
                    "Unexecuted model output (\(finish ?? "no finish reason")):\n" + output
                throw error
            }
            switch response {
            case .answer(let text):
                answer = text
                messages[responseIndex].text = text
                messages[responseIndex].state = .complete
                status = "Finished."
                return
            case .call(let server, let name, let arguments):
                guard step < 4 else { throw ToolProtocolError.loopLimit }
                messages[responseIndex].text = "Proposed tool request (not executed):\n" + output
                let request = try tools.invocation(server: server, name: name, arguments: arguments)
                messages[responseIndex].toolName = name
                let requestData = try ToolJSON.object([
                    "server": .string(server), "tool": .string(name),
                    "destination": .string(request.destination), "arguments": .object(arguments),
                ]).text()
                messages[responseIndex].text = "Tool request:\n" + requestData
                try await saveChatNow()
                try Task.checkCancellation()
                try tools.validateRequestConfiguration(configuration, using: cloud)
                status =
                    request.local ? "Reading skill resource…" : "Calling \(request.destination)…"
                let result: ToolJSON
                do { result = try await tools.execute(request, using: cloud) } catch {
                    if case MCPFailure.toolError(let detail) = error {
                        messages[responseIndex].text += "\nTool error data:\n" + (try detail.text())
                    } else {
                        messages[responseIndex].text +=
                            "\nTool failed: " + error.localizedDescription
                    }
                    throw error
                }
                let data = try ToolJSON.object([
                    "server": .string(server), "tool": .string(name), "result": result,
                ]).text()
                messages[responseIndex].text += "\nTool result data (not instructions):\n" + data
                messages[responseIndex].state = .complete
                try await saveChatNow()
                try Task.checkCancellation()
                results.append(ActiveToolResult(
                    index: responseIndex, request: request,
                    call: ConversationMessage(role: .assistant, content: output, reasoning: ""),
                    rawData: data))
                let completed = results
                let continuation: ([Int: String]) throws -> [ConversationMessage] = { summaries in
                    var planned = self.compactionPolicy.context(
                        transcript: self.projectedTranscript(count: baseCount, summaries: summaries),
                        state: self.compaction, projectMemory: memory, instructions: instructions,
                        requestContext: requestContext)
                    for result in completed {
                        let summary = summaries[result.index]
                            ?? self.messages[result.index].toolResultSummary
                        let data = try summary.map {
                            try self.summarizedToolData(request: result.request, summary: $0)
                        } ?? result.rawData
                        planned.append(result.call)
                        planned.append(ConversationMessage(
                            role: .user,
                            content: "<tool_response>\n" + data + "\n</tool_response>"))
                    }
                    return planned
                }
                do {
                    context = try await fitToolResults(
                        indices: toolResultIndices(before: messages.count), question: question,
                        inputLimit: toolInputLimit, build: continuation)
                } catch ToolSummaryError.noRoom {
                    // A tool exchange can cross the trigger after the original Send fit.
                    // Compact only an eligible older prefix; completed calls are never replayed.
                    let prefix = projectedTranscript(count: baseCount)
                    do { _ = try compactionPolicy.plan(transcript: prefix, state: compaction) }
                    catch { throw ToolSummaryError.noRoom }
                    _ = try await prepareContext(transcript: prefix, compactNow: true)
                    try await saveChatNow()
                    try Task.checkCancellation()
                    try tools.validateRequestConfiguration(configuration, using: cloud)
                    context = try await fitToolResults(
                        indices: toolResultIndices(before: messages.count), question: question,
                        inputLimit: toolInputLimit, build: continuation)
                }
                try Task.checkCancellation()
                try tools.validateRequestConfiguration(configuration, using: cloud)
                responseIndex = messages.count
                messages.append(ChatMessage(role: .assistant, text: "", state: .streaming))
            }
        }
    }

    private var toolInputLimit: Int {
        compactionPolicy.contextSize - compactionPolicy.responseTokens - 256
    }

    private func summarizedToolData(request: ToolInvocation, summary: String) throws -> String {
        try ToolJSON.object([
            "server": .string(request.server), "tool": .string(request.name),
            "result_summary": .string(summary),
            "context_note": .string(
                "Locally summarized tool data; may omit details. Full original saved in the chat. Do not repeat the completed call solely because this is a summary."),
        ]).text()
    }

    private struct ActiveToolResult {
        let index: Int
        let request: ToolInvocation
        let call: ConversationMessage
        let rawData: String
    }

    private func toolResultIndices(before end: Int, startingAt start: Int? = nil) -> [Int] {
        messages.indices.filter { index in
            index >= (start ?? compaction.summarizedMessageCount) && index < end
                && messages[index].role == .assistant && messages[index].toolName != nil
                && messages[index].state == .complete
        }
    }

    /// Budgets all reducible results together, including earlier raw results and existing notes.
    private func fitToolResults(
        indices: [Int], question: String, inputLimit: Int,
        build: ([Int: String]) throws -> [ConversationMessage]
    ) async throws -> [ConversationMessage] {
        try Task.checkCancellation()
        let original = try build([:])
        let count = try await session.tokenCount(messages: original)
        if count <= inputLimit { return original }
        var candidates: [(index: Int, contribution: Int)] = []
        for index in indices {
            try Task.checkCancellation()
            let without = try await session.tokenCount(messages: build([index: ""]))
            let contribution = count - without
            if contribution > 128 { candidates.append((index, contribution)) }
        }
        guard !candidates.isEmpty else { throw ToolSummaryError.noRoom }
        let empty = Dictionary(uniqueKeysWithValues: candidates.map { ($0.index, "") })
        let fixed = try await session.tokenCount(messages: build(empty))
        let available = inputLimit - fixed
        guard available / candidates.count >= 128 else { throw ToolSummaryError.noRoom }
        let share = min(compactionPolicy.summaryTokens, available / candidates.count)
        var summaries: [Int: String] = [:]
        for candidate in candidates {
            try Task.checkCancellation()
            summaries[candidate.index] = try await summarizeToolResult(
                source: messages[candidate.index].text, question: question,
                outputTokens: min(share, candidate.contribution - 1))
        }
        try Task.checkCancellation()
        let reduced = try build(summaries)
        guard try await session.tokenCount(messages: reduced) <= inputLimit else {
            throw ToolSummaryError.doesNotFit
        }
        try await saveToolSummaries(summaries)
        return reduced
    }

    private func summarizeToolResult(source: String, question: String, outputTokens: Int)
        async throws -> String
    {
        let wasCompacting = compacting
        compacting = true
        defer { compacting = wasCompacting }
        let session = session
        return try await ToolResultSummarizer().summarize(
            source: source, question: question, outputTokens: outputTokens,
            count: { try await session.tokenCount(messages: $0) },
            generate: { context, limit, chunk in
                try await self.generateToolSummary(context, limit: limit, chunk: chunk)
            })
    }

    /// Summary generations use the same serial engine and are excluded from chat throughput.
    private func generateToolSummary(_ context: [ConversationMessage], limit: Int, chunk: Int)
        async throws -> ToolSummaryGeneration
    {
        try Task.checkCancellation()
        status = "Summarizing tool result — part \(chunk)…"
        let run = try await session.generate(
            messages: context,
            options: GenerationOptions(maxTokens: limit, temperature: 0, topP: 1))
        activeRun = run
        if Task.isCancelled { run.cancel() }
        var text = ""
        var finish: String?
        var streamError: Error?
        do {
            for try await event in run.events {
                if Task.isCancelled { run.cancel(); break }
                switch event {
                case .answer(let delta): text += delta
                case .finished(let value): finish = value.finishReason
                case .reasoning: break
                }
            }
        } catch { streamError = error }
        await run.waitUntilFinished()
        activeRun = nil
        if case .failed(let message) = await session.state {
            loaded = false
            throw PresentationFailure(message: message)
        }
        if let streamError { throw streamError }
        try Task.checkCancellation()
        return ToolSummaryGeneration(text: text, finishReason: finish)
    }

    /// Publishing follows the atomic save; Stop/navigation are honored before continuing.
    private func saveToolSummaries(_ summaries: [Int: String]) async throws {
        try Task.checkCancellation()
        var updated = messages
        for (index, summary) in summaries { updated[index].toolResultSummary = summary }
        savingToolSummary = true
        defer { savingToolSummary = false }
        replacingContext = true
        let wasRunning = running
        running = false
        status = "Saving tool result summary…"
        do {
            try await saveChatNow(snapshot: ConversationSnapshot(
                conversationID: conversationID, messages: updated, compaction: compaction,
                projectID: activeProjectID))
            messages = updated
            replacingContext = false
            running = wasRunning
        } catch {
            replacingContext = false
            running = wasRunning
            throw error
        }
        try Task.checkCancellation()
        if let networkInterruption { throw PresentationFailure(message: networkInterruption) }
        guard usageActive, !pendingClear, !pendingUnload else { throw CancellationError() }
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
        transcript original: [ConversationMessage], draft: String? = nil, force: Bool = false,
        compactNow: Bool = false
    ) async throws -> [ConversationMessage] {
        let memory = try projectContext()
        let instructions = try tools.instructions(using: cloud)
        let requestContext = try tools.requestContext(using: cloud)
        let transcriptCount = original.count
        let question = draft.flatMap { $0.isEmpty ? nil : $0 }
            ?? messages.prefix(transcriptCount).last(where: { $0.role == .user })?.text ?? ""
        var transcript = original
        let context = compactionPolicy.context(
            transcript: transcript, state: compaction, draft: draft, projectMemory: memory,
            instructions: instructions, requestContext: requestContext)
        let inputCount = try await session.tokenCount(messages: context)
        if !force && !compactNow && inputCount <= compactionPolicy.triggerTokens { return context }
        func planning(_ transcript: [ConversationMessage]) -> [ConversationMessage] {
            transcript + (draft.map { [ConversationMessage(role: .user, content: $0)] } ?? [])
        }
        var plan: CompactionPlan
        do {
            plan = try compactionPolicy.plan(transcript: planning(transcript), state: compaction)
        } catch CompactionError.insufficientHistory {
            if force { throw CompactionError.insufficientHistory }
            let indices = toolResultIndices(before: transcriptCount)
            if indices.isEmpty {
                guard inputCount <= toolInputLimit else { throw CompactionError.insufficientHistory }
                return context
            }
            return try await fitToolResults(
                indices: indices, question: question, inputLimit: toolInputLimit,
                build: { summaries in
                    self.compactionPolicy.context(
                        transcript: self.projectedTranscript(count: transcriptCount, summaries: summaries),
                        state: self.compaction, draft: draft, projectMemory: memory,
                        instructions: instructions, requestContext: requestContext)
                })
        }
        let summaryInputLimit = compactionPolicy.contextSize - compactionPolicy.summaryTokens - 257
        if try await session.tokenCount(messages: plan.messages) > summaryInputLimit {
            let indices = toolResultIndices(before: plan.boundary)
            if !indices.isEmpty {
                _ = try await fitToolResults(
                    indices: indices, question: question, inputLimit: summaryInputLimit,
                    build: { summaries in
                        try self.compactionPolicy.plan(
                            transcript: planning(self.projectedTranscript(
                                count: transcriptCount, summaries: summaries)), state: self.compaction
                        ).messages
                    })
                transcript = projectedTranscript(count: transcriptCount)
                plan = try compactionPolicy.plan(transcript: planning(transcript), state: compaction)
            }
        }
        compacting = true
        status = "Compacting earlier messages…"
        defer { compacting = false }
        let run = try await session.generate(
            messages: plan.messages,
            options: GenerationOptions(
                maxTokens: compactionPolicy.summaryTokens, temperature: 0, topP: 1))
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
        var compacted = compactionPolicy.context(
            transcript: transcript, state: candidate, draft: draft, projectMemory: memory,
            instructions: instructions, requestContext: requestContext)
        if try await session.tokenCount(messages: compacted) > toolInputLimit {
            let indices = toolResultIndices(before: transcriptCount, startingAt: plan.boundary)
            guard !indices.isEmpty else { throw CompactionError.summaryDoesNotFit }
            compacted = try await fitToolResults(
                indices: indices, question: question, inputLimit: toolInputLimit,
                build: { summaries in
                    self.compactionPolicy.context(
                        transcript: self.projectedTranscript(count: transcriptCount, summaries: summaries),
                        state: candidate, draft: draft, projectMemory: memory,
                        instructions: instructions, requestContext: requestContext)
                })
        }
        try Task.checkCancellation()
        if force {
            // Once the completed summary enters its atomic commit, Stop is no longer offered.
            replacingContext = true
            running = false
            status = "Saving completed summary…"
            let snapshot = ConversationSnapshot(
                conversationID: conversationID, messages: messages, compaction: candidate,
                projectID: activeProjectID)
            try await saveChatNow(snapshot: snapshot)
        }
        compaction = candidate
        return compacted
    }

    /// Retries local persistence explicitly; corrupt startup data is never replaced with empty state.
    public func retryChatStorage() {
        if !chatRestored { check(); return }
        Task {
            do { try await saveChatNow() } catch { /* saveChatNow exposes the failure. */  }
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
            let archive =
                (existing
                ?? ConversationArchive(
                    sequence: 1,
                    snapshot: ConversationSnapshot(
                        conversationID: conversationID, messages: [], compaction: CompactionState())
                )).recoveringInterruptedResponses()
            if existing == nil || archive != existing { try await chatStore.save(archive) }
            restoringChat = true
            projects = archive.projects ?? []
            activeProjectID = archive.snapshot.projectID
            history = archive.history ?? []
            conversationID = archive.snapshot.conversationID
            messages = archive.snapshot.messages
            compaction = archive.snapshot.compaction
            prompt = archive.draft
            persistenceSequence = archive.sequence
            lastSnapshot = archive.snapshot
            persistedDraft = archive.draft
            persistedCloudSettings = PersistedCloudSettings(
                enabled: archive.cloudEnabled, bookmark: archive.cloudFolderBookmark,
                base: archive.cloudBaseFingerprint,
                consentVersion: archive.cloudConsentVersion ?? 0)
            cloud.restore(
                enabled: archive.cloudEnabled, bookmark: archive.cloudFolderBookmark,
                base: archive.cloudBaseFingerprint,
                consentVersion: archive.cloudConsentVersion ?? 0)
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
        guard chatRestored, chatStore != nil, !restoringChat, !resetting, !replacingContext else {
            return
        }
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
            } catch { /* Cancellation is expected; save errors are exposed by saveChatNow. */  }
        }
    }

    /// Captures on the main actor and queues writes in order; only the latest write sets status.
    private func saveChatNow(
        snapshot replacement: ConversationSnapshot? = nil, draft: String? = nil,
        notifyCloud: Bool = true, cloudSettings requestedSettings: PersistedCloudSettings? = nil,
        history replacementHistory: [SavedConversation]? = nil,
        projects replacementProjects: [ChatProject]? = nil
    ) async throws {
        guard chatRestored, let chatStore else { return }
        checkpointTask?.cancel()
        checkpointTask = nil
        var snapshot =
            replacement
            ?? ConversationSnapshot(
                conversationID: conversationID, messages: messages, compaction: compaction,
                projectID: activeProjectID)
        if replacement == nil, let lastSnapshot,
            lastSnapshot.conversationID == snapshot.conversationID,
            lastSnapshot.messages == snapshot.messages,
            lastSnapshot.compaction == snapshot.compaction,
            lastSnapshot.projectID == snapshot.projectID
        {
            snapshot.revision = lastSnapshot.revision
        }
        // A replacement is not the visible conversation until its write succeeds.
        if replacement == nil { lastSnapshot = snapshot }
        persistenceSequence += 1
        let sequence = persistenceSequence
        var pendingArchive = ConversationArchive(
            sequence: sequence, snapshot: snapshot, draft: draft ?? prompt)
        pendingArchive.history = replacementHistory ?? history
        pendingArchive.projects = replacementProjects ?? projects
        let capturedArchive = pendingArchive
        storageStatus = "Saving on this device…"
        let previous = saveTask
        let write = Task {
            if let previous { _ = await previous.result }
            // Ordinary checkpoints inherit settings from the preceding successful write,
            // never from an opt-in whose own save is still pending or has failed.
            var settings = requestedSettings ?? self.persistedCloudSettings
            if requestedSettings == nil && !self.cloud.enabled { settings.enabled = false }
            var archive = capturedArchive
            archive.cloudEnabled = settings.enabled
            archive.cloudFolderBookmark = settings.bookmark
            archive.cloudBaseFingerprint = settings.base
            archive.cloudConsentVersion = settings.consentVersion
            try await chatStore.save(archive)
            self.persistedDraft = archive.draft
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
            conversationID: conversationID, messages: messages, compaction: compaction,
            projectID: activeProjectID)
        if let lastSnapshot, lastSnapshot.conversationID == conversationID,
            lastSnapshot.messages == messages, lastSnapshot.compaction == compaction,
            lastSnapshot.projectID == activeProjectID
        {
            snapshot.revision = lastSnapshot.revision
        }
        return snapshot
    }

    private func configureCloud() {
        cloud.current = { [weak self] in
            guard let self, self.chatRestored else { return nil }
            return CloudLocalConversation(
                snapshot: self.currentLibrary(),
                hasDraft: !self.prompt.isEmpty
                    || self.history.contains(where: { !$0.draft.isEmpty }),
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
                base: self.cloud.baseFingerprint, consentVersion: self.cloud.consentVersion)
            try await self.saveChatNow(notifyCloud: false, cloudSettings: settings)
        }
        cloud.apply = { [weak self] snapshot, expected in
            guard let self else { throw CancellationError() }
            try await self.applyCloudSnapshot(snapshot, expected: expected)
        }
    }

    /// Project edits preserve every chat/draft and become visible only after one durable write.
    func commitProjectLibrary(_ library: ConversationLibrary) async throws {
        guard canEditProjects else { throw ProjectError.busy }
        try library.validate()
        guard Set(library.chats.map(\.conversationID)) == Set(savedChats.map(\.id)),
            let selected = library.chats.first(where: { $0.conversationID == conversationID })
        else { throw ConversationStorageError.invalidDocument }
        let saved = try history.map { old in
            guard let snapshot = library.chats.first(where: { $0.conversationID == old.id }) else {
                throw ConversationStorageError.invalidDocument
            }
            return SavedConversation(snapshot: snapshot, draft: old.draft)
        }
        let draft = prompt
        try Task.checkCancellation()
        busy = true
        resetting = true
        cloud.pause()
        cloud.refresh()  // Drop choices tied to the library being edited; resume re-reads it.
        do {
            if loaded { try await session.reset() }
            try Task.checkCancellation()
            try await saveChatNow(
                snapshot: selected, draft: draft, history: saved, projects: library.projects)
            projects = library.projects
            publish(selected, draft: draft, history: saved)
            status = "Project changes saved."
        } catch {
            self.error = error.localizedDescription
            await finishDeferredActions()
            throw error
        }
        await finishDeferredActions()
    }

    private func currentLibrary() -> ConversationLibrary {
        ConversationLibrary(
            chats: [currentSnapshot()] + history.map(\.snapshot), projects: projects)
    }

    private func applyCloudSnapshot(_ library: ConversationLibrary, expected: String) async throws {
        guard !busy, !resetting, try currentLibrary().fingerprint() == expected else {
            throw CloudConversationError.changed
        }
        try library.validate()
        try Task.checkCancellation()
        busy = true
        resetting = true
        // Selection is device-local; a replacement library may not include the current ID.
        guard
            let selected = library.chats.first(where: { $0.conversationID == conversationID })
                ?? library.chats.first
        else { throw ConversationStorageError.invalidDocument }
        var archive = ConversationArchive(sequence: 0, snapshot: selected)
        archive.projects = library.projects
        archive.history = library.chats.filter { $0.conversationID != selected.conversationID }
            .map { SavedConversation(snapshot: $0) }
        archive = archive.recoveringInterruptedResponses()
        do {
            if loaded { try await session.reset() }
            try await saveChatNow(
                snapshot: archive.snapshot, draft: "", notifyCloud: false,
                history: archive.history, projects: archive.projects)
            projects = library.projects
            publish(archive.snapshot, draft: "", history: archive.history ?? [])
            status = "Restored the iCloud chat library."
        } catch {
            await finishDeferredActions()
            throw error
        }
        await finishDeferredActions()
    }

    private func publish(
        _ snapshot: ConversationSnapshot, draft: String, history: [SavedConversation]
    ) {
        restoringChat = true
        self.history = history
        activeProjectID = snapshot.projectID
        messages = snapshot.messages
        compaction = snapshot.compaction
        conversationID = snapshot.conversationID
        prompt = draft
        reasoning = ""
        answer = ""
        metrics = nil
        restoringChat = false
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
                    var saved = history
                    let selected: SavedConversation
                    if let id = pendingSelection {
                        guard let index = saved.firstIndex(where: { $0.id == id }) else {
                            throw ConversationStorageError.invalidDocument
                        }
                        selected = saved.remove(at: index)
                    } else {
                        selected = SavedConversation(
                            snapshot: ConversationSnapshot(
                                conversationID: UUID(), messages: [], compaction: CompactionState(),
                                projectID: pendingProjectID))
                    }
                    pendingSelection = nil
                    pendingProjectID = nil
                    saved.insert(
                        SavedConversation(snapshot: currentSnapshot(), draft: prompt), at: 0)
                    try await saveChatNow(
                        snapshot: selected.snapshot, draft: selected.draft, history: saved)
                    publish(selected.snapshot, draft: selected.draft, history: saved)
                    status = "Chat ready."
                }
            } catch {
                self.error = error.localizedDescription
                status = "Cleanup failed."
            }
        }
        let heldContextBarrier = replacingContext
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
        if heldContextBarrier && persistedDraft != prompt {
            scheduleChatSave(immediately: true)
        }
    }
}

private struct PresentationFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
