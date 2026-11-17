import Foundation
import Observation

/// Loads the configured source; failed/missing cloud config never selects local substitutes.
@MainActor @Observable
public final class QuickActionsModel {
    public private(set) var actions: [QuickAction] = []
    public private(set) var loading = false
    public private(set) var applying = false
    @ObservationIgnored private var applicationID = UUID()
    public private(set) var error: String?
    public private(set) var sourceDescription = "On My iPhone / Embla Chat / Actions/actions.json"
    public private(set) var loadedSourceKey: String?
    @ObservationIgnored private var storage: (any QuickActionsStoring)?
    @ObservationIgnored private var setupError: String?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var draining: Task<Void, Never>?
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private var foreground = true

    public init() {
        do {
            let files = FileManager.default
            let documents = try files.url(
                for: .documentDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
            let support = try files.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
            storage = QuickActionStore(
                localRoot: documents.appendingPathComponent("Actions"),
                stateRoot: support.appendingPathComponent("EmblaChat/ActionSettings"))
        } catch {
            setupError = error.localizedDescription
            self.error = error.localizedDescription
        }
    }

    /// Only tests can supply a provider. Production uses the native Files storage above.
    init(storage: any QuickActionsStoring) { self.storage = storage }

    public static func sourceKey(for cloud: ConversationCloudSync) -> String {
        guard cloud.enabled else { return "device" }
        guard !cloud.requiresScopeConsent, cloud.folderAccessReady else {
            return "unavailable:" + cloud.configurationRevision.uuidString + ":" + cloud.status
        }
        return "cloud:" + cloud.configurationRevision.uuidString
    }

    public func reload(using cloud: ConversationCloudSync) { start(using: cloud, create: false) }
    public func createStarter(using cloud: ConversationCloudSync) {
        start(using: cloud, create: true)
    }

    public func pause() {
        cancelApplication()
        foreground = false
        cancelWorker()
        requestID = UUID()
        actions = []
        loadedSourceKey = nil
        loading = false
    }

    public func resume(using cloud: ConversationCloudSync) {
        foreground = true
        reload(using: cloud)
    }

    /// Revalidate a selected card after draft confirmation or a source/configuration change.
    public func prompt(for action: QuickAction, using cloud: ConversationCloudSync) throws -> String
    {
        _ = try validatedAction(action, using: cloud)
        guard action.type == .prompt else { throw QuickActionError.skillsUnavailable }
        guard let prompt = action.prompt else {
            throw QuickActionError.invalidAction("Action '\(action.id)' has no prompt.")
        }
        return prompt
    }

    public func validatedAction(_ action: QuickAction, using cloud: ConversationCloudSync) throws
        -> QuickAction
    {
        guard loadedSourceKey == Self.sourceKey(for: cloud), !loading, error == nil,
            actions.contains(action)
        else { throw QuickActionError.changed }
        return action
    }

    /// Draft-only and immediate actions share the same preflight, consent and Send path.
    public func apply(
        _ action: QuickAction, to model: LocalInferenceModel,
        replacing: QuickActionReplacement? = nil
    ) async throws -> QuickActionApplication {
        try Task.checkCancellation()
        guard !applying else {
            throw QuickActionError.notReady("Wait for the current action to finish.")
        }
        _ = try validatedAction(action, using: model.cloud)
        try QuickActionConfiguration(actions: [action]).validate()
        try requireActionReady(action, model: model)
        let chat = model.conversationID
        let draft = model.prompt
        let prompt = action.prompt ?? draft
        if let replacing {
            guard replacing.action == action, replacing.conversationID == chat,
                replacing.draft == draft
            else { throw QuickActionError.changed }
        } else if !draft.isEmpty && draft != prompt {
            return .needsConfirmation(
                QuickActionReplacement(action: action, conversationID: chat, draft: draft))
        }
        let request = UUID()
        applicationID = request
        applying = true
        defer { if applicationID == request { applying = false } }
        if action.type == .skill {
            guard let name = action.skill else { throw QuickActionError.changed }
            try await model.tools.selectSkill(name, using: model.cloud)
        }
        try Task.checkCancellation()
        _ = try validatedAction(action, using: model.cloud)
        guard applicationID == request, model.conversationID == chat, model.prompt == draft else {
            throw QuickActionError.changed
        }
        try requireActionReady(action, model: model)
        if action.autoSend { try model.tools.validateSelectedPreference() }
        model.prompt = prompt
        if action.autoSend { model.run() }
        return .applied
    }

    /// Invalidates a pending UI selection; its late completion cannot change another draft.
    public func cancelApplication() {
        applicationID = UUID()
        applying = false
    }

    private func requireActionReady(_ action: QuickAction, model: LocalInferenceModel) throws {
        guard model.chatRestored, !model.busy, !model.resetting, !model.cloud.resolving,
            model.storageError == nil, !model.tools.settingsLoading, !model.tools.settingsWriting
        else {
            throw QuickActionError.notReady(
                model.storageError
                    ?? "Wait for the current operation or resolve storage in Settings.")
        }
        if action.autoSend {
            guard model.readyDirectory != nil else {
                throw QuickActionError.notReady(
                    "Download and verify the model in Settings before sending an action.")
            }
            if action.type == .prompt { try model.tools.validateSelectedPreference() }
        }
    }

    private func start(using cloud: ConversationCloudSync, create: Bool) {
        guard foreground else { return }
        cancelWorker()
        let request = UUID()
        requestID = request
        let key = Self.sourceKey(for: cloud)
        actions = []
        loadedSourceKey = nil
        loading = false
        error = nil
        sourceDescription =
            cloud.enabled
            ? "Selected iCloud EmblaChat / Actions/actions.json"
            : "On My iPhone / Embla Chat / Actions/actions.json"
        guard let storage else {
            error = setupError ?? "Quick-action storage is unavailable."
            return
        }
        let source: QuickActionSource
        if cloud.enabled {
            guard !cloud.requiresScopeConsent, let bookmark = cloud.authorizedFolderBookmark else {
                error = QuickActionError.sourceUnavailable.localizedDescription
                return
            }
            source = .cloud(bookmark)
        } else {
            source = .device
        }
        loading = true
        worker = Task { [weak self] in
            defer {
                if let self, requestID == request {
                    loading = false
                    worker = nil
                }
            }
            do {
                try Task.checkCancellation()
                if create { try await storage.createStarter(source) }
                let config = try await storage.read(source)
                try Task.checkCancellation()
                guard let self, requestID == request,
                    Self.sourceKey(for: cloud) == key
                else { return }
                actions = config.visibleActions
                loadedSourceKey = key
            } catch {
                guard let self, requestID == request,
                    Self.sourceKey(for: cloud) == key
                else { return }
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
    }

    private func cancelWorker() {
        guard let worker else { return }
        worker.cancel()
        let previous = draining
        draining = Task {
            await previous?.value
            await worker.value
        }
        self.worker = nil
    }

    func waitUntilIdle() async {
        while let worker { await worker.value }
        await draining?.value
    }
}
