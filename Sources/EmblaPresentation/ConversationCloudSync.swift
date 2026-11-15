import Foundation
import Observation

public struct CloudLocalConversation: Sendable {
    public let snapshot: ConversationSnapshot
    public let hasDraft: Bool
    public let canReplace: Bool
}

public struct CloudChatChoice: Identifiable, Sendable {
    public let id: String
    public let label: String
    public let snapshot: ConversationSnapshot
}

enum CloudSyncAction { case identical, upload, download, conflict, removed }

/// A shared base distinguishes local edits from another device's edits without last-writer-wins.
enum CloudSyncPolicy {
    static func action(
        local: CloudLocalConversation, remote: CloudConversationRead, base: String?
    ) throws -> CloudSyncAction {
        guard remote.conflicts.isEmpty else { return .conflict }
        guard let current = remote.current else { return base == nil ? .upload : .removed }
        let localID = try local.snapshot.fingerprint()
        let remoteID = try current.fingerprint()
        if localID == remoteID { return .identical }
        guard let base else { return .conflict }
        if remoteID == base { return .upload }
        if localID == base && !local.hasDraft { return .download }
        return .conflict
    }
}

/// Optional cloud orchestration. No provider is opened or called while disabled.
@MainActor @Observable
public final class ConversationCloudSync {
    public private(set) var enabled = false
    public private(set) var status = "iCloud is off."
    public private(set) var error: String?
    public private(set) var syncing = false
    public private(set) var resolving = false
    public private(set) var choices: [CloudChatChoice] = []
    @ObservationIgnored var bookmark: Data?
    @ObservationIgnored var baseFingerprint: String?
    @ObservationIgnored var current: (() -> CloudLocalConversation?)?
    @ObservationIgnored var apply: ((ConversationSnapshot, String) async throws -> Void)?
    @ObservationIgnored var persist: (() async throws -> Void)?
    @ObservationIgnored private let factory: @Sendable (Data) -> any CloudConversationStorage
    @ObservationIgnored private var storage: (any CloudConversationStorage)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var preferenceTask: Task<Void, Never>?
    @ObservationIgnored private var drainTask: Task<Void, Never>?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    // Lifecycle pauses invalidate transfers, while only a setting change supersedes consent saving.
    @ObservationIgnored private var configurationID = UUID()
    @ObservationIgnored private var needsSync = false
    @ObservationIgnored private var foreground = true
    @ObservationIgnored private var paused = true
    @ObservationIgnored private var conflictRead: CloudConversationRead?
    @ObservationIgnored private var conflictLocal: String?

    public init() { factory = { ICloudConversationStore(bookmark: $0) } }

    /// Only tests can inject a provider; production always uses the user-granted iCloud folder.
    init(factory: @escaping @Sendable (Data) -> any CloudConversationStorage) {
        self.factory = factory
    }

    func restore(enabled: Bool, bookmark: Data?, base: String?) {
        pause()
        configurationID = UUID()
        self.enabled = enabled
        self.bookmark = bookmark
        baseFingerprint = base
        storage = enabled ? bookmark.map(factory) : nil
        error = enabled && bookmark == nil ? CloudConversationError.permission.localizedDescription : nil
        status = enabled ? "Waiting to synchronize…" : "iCloud is off."
        if error != nil { status = "iCloud folder access is unavailable." }
    }

    /// Called only after explicit consent and successful Files folder selection.
    public func enable(folder: URL) async {
        let bookmark: Data
        do { bookmark = try ICloudConversationStore.bookmark(for: folder) } catch {
            folderSelectionFailed(error)
            return
        }
        do { try await enable(bookmark: bookmark) } catch {
            // The matching settings operation and local persistence expose their failures.
        }
    }

    public func folderSelectionFailed(_ failure: Error) {
        if (failure as? CocoaError)?.code == .userCancelled { return }
        error = failure.localizedDescription
        status = "Could not select the iCloud folder."
    }

    func enable(bookmark: Data) async throws {
        pause()
        let configuration = UUID()
        configurationID = configuration
        enabled = true
        self.bookmark = bookmark
        baseFingerprint = nil
        choices = []
        conflictRead = nil
        conflictLocal = nil
        storage = nil
        error = nil
        status = "Saving the iCloud preference…"
        do { try await persistSettings() } catch {
            if configurationID == configuration {
                enabled = false
                storage = nil
                self.error = error.localizedDescription
                status = "Could not save the iCloud preference."
            }
            throw error
        }
        guard configurationID == configuration, enabled else { return }
        storage = factory(bookmark)
        resume()
    }

    /// Stops new app operations. Data already handed to iCloud Drive may still finish uploading.
    public func disable() {
        pause()
        configurationID = UUID()
        enabled = false
        storage = nil
        choices = []
        conflictRead = nil
        conflictLocal = nil
        error = nil
        status = "iCloud is off. Existing cloud files are kept."
        let epoch = generation
        preferenceTask = Task {
            do { try await persistSettings() } catch {
                guard generation == epoch, !enabled else { return }
                self.error = error.localizedDescription
                status = "iCloud stopped, but the preference could not be saved. Retry before closing."
            }
        }
    }

    public func refresh() {
        choices = []
        conflictRead = nil
        conflictLocal = nil
        requestSync()
    }

    func setForeground(_ active: Bool) {
        foreground = active
        if active { resume() } else { pause() }
    }

    func resume() {
        guard foreground, enabled, storage != nil else { return }
        paused = false
        if timer == nil {
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                    guard let self else { return }
                    self.requestSync()
                }
            }
        }
        requestSync()
    }

    func pause() {
        paused = true
        generation = UUID()
        if let task {
            task.cancel()
            let previous = drainTask
            drainTask = Task {
                if let previous { await previous.value }
                await task.value
            }
        }
        timer?.cancel()
        task = nil
        timer = nil
        syncing = false
        resolving = false
    }

    func requestSync() {
        guard foreground, !paused, enabled, let storage, choices.isEmpty else { return }
        guard task == nil else { needsSync = true; return }
        guard let local = current?(), local.canReplace else {
            needsSync = true
            status = "Waiting for the current chat operation…"
            return
        }
        needsSync = false
        syncing = true
        status = "Synchronizing with iCloud Drive…"
        let epoch = generation
        task = Task {
            do { try await synchronize(local: local, storage: storage, epoch: epoch) } catch {
                if generation == epoch && enabled && !(error is CancellationError) {
                    self.error = error.localizedDescription
                    status = "iCloud synchronization needs attention."
                }
            }
            finish(epoch: epoch)
        }
    }

    private func synchronize(
        local: CloudLocalConversation, storage: any CloudConversationStorage, epoch: UUID
    ) async throws {
        let remote = try await storage.read()
        try Task.checkCancellation()
        guard generation == epoch, enabled else { return }
        guard let latest = current?(), latest.canReplace,
            try latest.snapshot.fingerprint() == local.snapshot.fingerprint(),
            latest.hasDraft == local.hasDraft
        else { needsSync = true; return }
        let previousBase = baseFingerprint
        switch try CloudSyncPolicy.action(local: latest, remote: remote, base: baseFingerprint) {
        case .identical:
            baseFingerprint = try latest.snapshot.fingerprint()
        case .upload:
            try await storage.write(latest.snapshot, replacing: remote, resolvingConflicts: false)
            try Task.checkCancellation()
            guard generation == epoch, enabled else { return }
            baseFingerprint = try latest.snapshot.fingerprint()
        case .download:
            guard let snapshot = remote.current else { throw CloudConversationError.removed }
            try await applySnapshot(snapshot, expected: latest.snapshot.fingerprint())
            guard generation == epoch, enabled else { return }
            baseFingerprint = try snapshot.fingerprint()
        case .conflict:
            try showConflict(local: latest.snapshot, remote: remote)
            return
        case .removed: throw CloudConversationError.removed
        }
        if baseFingerprint != previousBase { try await persistSettings() }
        guard generation == epoch, enabled else { return }
        error = nil
        let same = try current?()?.snapshot.fingerprint() == remote.current?.fingerprint()
        status = remote.uploaded && same
            ? "Synced with iCloud Drive." : "Saved to iCloud Drive; upload confirmation pending."
        if let now = current?(), try now.snapshot.fingerprint() != baseFingerprint { needsSync = true }
    }

    private func showConflict(local: ConversationSnapshot, remote: CloudConversationRead) throws {
        conflictRead = remote
        conflictLocal = try local.fingerprint()
        var result = [CloudChatChoice(
            id: try local.fingerprint(), label: "Keep this device’s chat", snapshot: local)]
        for (index, snapshot) in ([remote.current].compactMap { $0 } + remote.conflicts).enumerated() {
            let id = try snapshot.fingerprint()
            if !result.contains(where: { $0.id == id }) {
                result.append(CloudChatChoice(
                    id: id, label: index == 0 ? "Use iCloud chat" : "Use iCloud conflict copy \(index)",
                    snapshot: snapshot))
            }
        }
        choices = result
        error = nil
        status = "Choose which chat to keep. Nothing has been overwritten."
    }

    /// The UI confirms this replacement, including discarding the current unsent draft if needed.
    public func resolve(choiceID: String) {
        guard enabled, task == nil, let storage, let expected = conflictRead,
            let choice = choices.first(where: { $0.id == choiceID }),
            let local = current?(), local.canReplace,
            let localID = try? local.snapshot.fingerprint(), localID == conflictLocal
        else {
            error = "The chat changed. Refresh before choosing a version."
            return
        }
        resolving = true
        syncing = true
        let epoch = generation
        task = Task {
            do {
                try await storage.write(choice.snapshot, replacing: expected, resolvingConflicts: true)
                try Task.checkCancellation()
                guard generation == epoch, enabled else { finish(epoch: epoch); return }
                if choice.id != localID { try await applySnapshot(choice.snapshot, expected: localID) }
                try Task.checkCancellation()
                guard generation == epoch, enabled else { finish(epoch: epoch); return }
                baseFingerprint = try choice.snapshot.fingerprint()
                try await persistSettings()
                try Task.checkCancellation()
                guard generation == epoch, enabled else { finish(epoch: epoch); return }
                choices = []
                conflictRead = nil
                conflictLocal = nil
                error = nil
                status = "Choice saved; upload confirmation pending."
                needsSync = true
            } catch {
                if generation == epoch && enabled && !(error is CancellationError) {
                    self.error = error.localizedDescription
                    status = "Could not resolve the iCloud conflict."
                }
            }
            finish(epoch: epoch)
        }
    }

    private func finish(epoch: UUID) {
        guard generation == epoch else { return }
        task = nil
        syncing = false
        resolving = false
        if needsSync, enabled, choices.isEmpty, current?()?.canReplace == true { requestSync() }
    }

    private func persistSettings() async throws {
        guard let persist else { throw CloudConversationError.configuration }
        try await persist()
    }

    private func applySnapshot(_ snapshot: ConversationSnapshot, expected: String) async throws {
        guard let apply else { throw CloudConversationError.configuration }
        try await apply(snapshot, expected)
    }

    func waitUntilIdle() async {
        while let task { await task.value }
        await drainTask?.value
        await preferenceTask?.value
    }
}
