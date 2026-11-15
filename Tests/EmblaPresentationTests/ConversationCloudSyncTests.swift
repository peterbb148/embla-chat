import Foundation
import Testing
@testable import EmblaCore
@testable import EmblaPresentation

private func syncSnapshot(_ text: String) -> ConversationSnapshot {
    ConversationSnapshot(
        conversationID: UUID(), messages: [ChatMessage(role: .user, text: text)], compaction: .init())
}

/// Explicit simulated provider for synchronization policy tests; never used by the app constructor.
private actor SyncProviderFixture: CloudConversationStorage {
    var document: CloudConversationRead
    private(set) var reads = 0
    private(set) var writes = 0
    private var holdRead: Bool
    private var holdWrite: Bool
    private let readFailure: CocoaError?
    private var writeGate: CheckedContinuation<Void, Never>?
    private var gate: CheckedContinuation<Void, Never>?

    init(
        _ document: CloudConversationRead = .init(), holdRead: Bool = false,
        holdWrite: Bool = false, readFailure: CocoaError? = nil
    ) {
        self.document = document
        self.holdRead = holdRead
        self.holdWrite = holdWrite
        self.readFailure = readFailure
    }
    func read() async throws -> CloudConversationRead {
        reads += 1
        if holdRead {
            holdRead = false
            await withCheckedContinuation { gate = $0 }
        }
        if let readFailure { throw readFailure }
        return document
    }
    func write(
        _ snapshot: ConversationSnapshot, replacing: CloudConversationRead,
        resolvingConflicts: Bool
    ) async throws {
        try Task.checkCancellation()
        guard try document.fingerprints == replacing.fingerprints else {
            throw CloudConversationError.changed
        }
        writes += 1
        document = CloudConversationRead(current: snapshot)
        if holdWrite {
            holdWrite = false
            await withCheckedContinuation { writeGate = $0 }
        }
    }
    func releaseWrite() { writeGate?.resume(); writeGate = nil }
    func waitForWrite() async throws {
        for _ in 0..<1_000 {
            if writes > 0 { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CloudConversationError.coordination
    }
    func releaseRead() { gate?.resume(); gate = nil }
    func confirmUpload() { document.uploaded = true }
    func waitForRead() async throws {
        for _ in 0..<1_000 {
            if reads > 0 { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CloudConversationError.coordination
    }
}

@MainActor
private final class SyncHarness {
    var local: ConversationSnapshot
    var draft = false
    var busy = false
    var applications = 0
    var settingsSaves = 0
    let cloud: ConversationCloudSync

    init(local: ConversationSnapshot, provider: SyncProviderFixture) {
        self.local = local
        cloud = ConversationCloudSync(factory: { _ in provider })
        cloud.current = { [weak self] in
            guard let self else { return nil }
            return CloudLocalConversation(
                snapshot: self.local, hasDraft: self.draft, canReplace: !self.busy)
        }
        cloud.apply = { [weak self] snapshot, expected in
            guard let self, try self.local.fingerprint() == expected else {
                throw CloudConversationError.changed
            }
            self.local = snapshot
            self.draft = false
            self.applications += 1
        }
        cloud.persist = { [weak self] in self?.settingsSaves += 1 }
    }
    func start(base: String? = nil) {
        cloud.restore(enabled: true, bookmark: Data("fixture permission".utf8), base: base)
        cloud.resume()
    }
}

@Test @MainActor
func disabledCloudPerformsNoProviderReadsOrWrites() async throws {
    let provider = SyncProviderFixture()
    let harness = SyncHarness(local: syncSnapshot("local"), provider: provider)
    harness.cloud.restore(enabled: false, bookmark: Data("old permission".utf8), base: nil)
    harness.cloud.resume()
    harness.cloud.requestSync()
    await harness.cloud.waitUntilIdle()
    #expect(await provider.reads == 0)
    #expect(await provider.writes == 0)
    #expect(!harness.cloud.enabled)
}

@Test @MainActor
func firstConnectionRequiresChoiceAndNeverClaimsUploadFromAWrite() async throws {
    let local = syncSnapshot("this device")
    let remote = syncSnapshot("existing cloud")
    let provider = SyncProviderFixture(.init(current: remote, uploaded: true))
    let harness = SyncHarness(local: local, provider: provider)
    harness.start()
    defer { harness.cloud.disable() }
    await harness.cloud.waitUntilIdle()
    #expect(harness.cloud.choices.count == 2)
    #expect(await provider.writes == 0)
    #expect(harness.local == local)
    let choice = try #require(harness.cloud.choices.first(where: { $0.snapshot == local }))
    harness.cloud.resolve(choiceID: choice.id)
    await harness.cloud.waitUntilIdle()
    #expect(await provider.document.current == local)
    #expect(harness.cloud.status != "Synced with iCloud Drive.")
    await provider.confirmUpload()
    harness.cloud.refresh()
    await harness.cloud.waitUntilIdle()
    #expect(harness.cloud.status == "Synced with iCloud Drive.")
}

@Test @MainActor
func unchangedLocalChatAcceptsRemoteChangesButAnUnsentDraftRequiresChoice() async throws {
    let baseline = syncSnapshot("old shared chat")
    let remote = syncSnapshot("new remote chat")
    let provider = SyncProviderFixture(.init(current: remote, uploaded: true))
    let harness = SyncHarness(local: baseline, provider: provider)
    harness.draft = true
    harness.start(base: try baseline.fingerprint())
    defer { harness.cloud.disable() }
    await harness.cloud.waitUntilIdle()
    #expect(harness.cloud.choices.count == 2)
    #expect(harness.applications == 0 && harness.draft)
    let remoteChoice = try #require(harness.cloud.choices.first(where: { $0.snapshot == remote }))
    harness.cloud.resolve(choiceID: remoteChoice.id)
    await harness.cloud.waitUntilIdle()
    #expect(harness.local == remote && !harness.draft)
    #expect(harness.applications == 1)
}

@Test @MainActor
func disablingWhileAReadIsPendingPreventsTheSubsequentUpload() async throws {
    let provider = SyncProviderFixture(holdRead: true)
    let harness = SyncHarness(local: syncSnapshot("private local chat"), provider: provider)
    harness.start()
    try await provider.waitForRead()
    harness.cloud.disable()
    await provider.releaseRead()
    await harness.cloud.waitUntilIdle()
    #expect(await provider.writes == 0)
    #expect(harness.applications == 0)
    #expect(!harness.cloud.enabled)
}

@Test @MainActor
func remoteReadStartedBeforeNewChatCannotRestoreTheOldConversation() async throws {
    let baseline = syncSnapshot("old shared chat")
    let provider = SyncProviderFixture(.init(current: baseline), holdRead: true)
    let harness = SyncHarness(local: baseline, provider: provider)
    harness.start(base: try baseline.fingerprint())
    defer { harness.cloud.disable() }
    try await provider.waitForRead()
    let reset = ConversationSnapshot(conversationID: UUID(), messages: [], compaction: .init())
    harness.local = reset
    await provider.releaseRead()
    await harness.cloud.waitUntilIdle()
    #expect(harness.local == reset)
    #expect(harness.applications == 0)
    #expect(await provider.document.current == reset)
}

@Test func bothLocalAndRemoteEditsRequireExplicitConflictResolution() throws {
    let baseline = syncSnapshot("baseline")
    let local = CloudLocalConversation(snapshot: syncSnapshot("local edit"), hasDraft: false, canReplace: true)
    let remote = CloudConversationRead(current: syncSnapshot("remote edit"))
    #expect(try CloudSyncPolicy.action(local: local, remote: remote, base: baseline.fingerprint()) == .conflict)
    let unchanged = CloudLocalConversation(snapshot: baseline, hasDraft: false, canReplace: true)
    #expect(try CloudSyncPolicy.action(local: unchanged, remote: remote, base: baseline.fingerprint()) == .download)
}


/// Uses real local archive files plus an explicit provider fixture; no model is required to restore.
@Test @MainActor
func cloudRestorationIsSavedLocallyBeforeBeingShownInTheController() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let baseline = syncSnapshot("old shared message")
    let remote = syncSnapshot("new shared message")
    var archive = ConversationArchive(sequence: 1, snapshot: baseline)
    archive.cloudEnabled = true
    archive.cloudFolderBookmark = Data("fixture permission".utf8)
    archive.cloudBaseFingerprint = try baseline.fingerprint()
    try await ConversationStore(root: root).save(archive)
    let provider = SyncProviderFixture(.init(current: remote, uploaded: true))
    let cloud = ConversationCloudSync(factory: { _ in provider })
    let model = LocalInferenceModel(
        repository: nil, manifest: try ModelManifest.bundled(),
        session: InferenceSession { _, _ in throw InferenceError.modelNotDownloaded },
        chatStore: ConversationStore(root: root), cloud: cloud)
    model.check()
    await model.waitUntilIdle()
    await cloud.waitUntilIdle()
    #expect(model.messages == remote.messages)
    #expect(model.conversationID == remote.conversationID)
    let local = try await ConversationStore(root: root).load()
    #expect(local?.snapshot == remote)
    let remoteFingerprint = try remote.fingerprint()
    #expect(local?.cloudBaseFingerprint == remoteFingerprint)
    cloud.disable()
    await cloud.waitUntilIdle()
    #expect(try await ConversationStore(root: root).load()?.cloudEnabled == false)
}

@Test @MainActor
func controllerNewChatDuringCloudReadSynchronizesTheResetWithoutRestoringOldMessages() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let baseline = syncSnapshot("old chat that must stay cleared")
    var archive = ConversationArchive(sequence: 1, snapshot: baseline)
    archive.cloudEnabled = true
    archive.cloudFolderBookmark = Data("fixture permission".utf8)
    archive.cloudBaseFingerprint = try baseline.fingerprint()
    try await ConversationStore(root: root).save(archive)
    let provider = SyncProviderFixture(.init(current: baseline), holdRead: true)
    let cloud = ConversationCloudSync(factory: { _ in provider })
    let model = LocalInferenceModel(
        repository: nil, manifest: try ModelManifest.bundled(),
        session: InferenceSession { _, _ in throw InferenceError.modelNotDownloaded },
        chatStore: ConversationStore(root: root), cloud: cloud)
    model.check()
    await model.waitUntilIdle()
    try await provider.waitForRead()
    model.newChat()
    await model.waitUntilIdle()
    let resetID = model.conversationID
    await provider.releaseRead()
    await cloud.waitUntilIdle()
    #expect(model.messages.isEmpty && model.conversationID == resetID)
    #expect(await provider.document.current?.messages.isEmpty == true)
    #expect(await provider.document.current?.conversationID == resetID)
    #expect(try await ConversationStore(root: root).load()?.snapshot.conversationID == resetID)
    cloud.pause()
    await cloud.waitUntilIdle()
}

@Test @MainActor
func disabledPreferenceWithAnOldFolderBookmarkNeverOpensTheProviderOnRestore() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var archive = ConversationArchive(sequence: 1, snapshot: syncSnapshot("private local message"))
    archive.cloudFolderBookmark = Data("previously granted permission".utf8)
    try await ConversationStore(root: root).save(archive)
    let provider = SyncProviderFixture()
    let cloud = ConversationCloudSync(factory: { _ in provider })
    let model = LocalInferenceModel(
        repository: nil, manifest: try ModelManifest.bundled(),
        session: InferenceSession { _, _ in throw InferenceError.modelNotDownloaded },
        chatStore: ConversationStore(root: root), cloud: cloud)
    model.check()
    await model.waitUntilIdle()
    await cloud.waitUntilIdle()
    #expect(model.messages == archive.snapshot.messages)
    #expect(await provider.reads == 0)
    #expect(await provider.writes == 0)
    #expect(!cloud.enabled)
}


private actor SyncCheckpointGate {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func blockOnce() async {
        guard !entered else { return }
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
    func waitForEntry() async throws {
        for _ in 0..<1_000 {
            if entered { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CloudConversationError.coordination
    }
}

/// Holds a real empty-archive write's completion while the old transcript is still visible.
private actor ResetCheckpointStore: ConversationStoring {
    private let store: ConversationStore
    let resetGate = SyncCheckpointGate()
    init(root: URL) { store = ConversationStore(root: root) }
    func load() async throws -> ConversationArchive? { try await store.load() }
    func save(_ archive: ConversationArchive) async throws {
        try await store.save(archive)
        if archive.snapshot.messages.isEmpty { await resetGate.blockOnce() }
    }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func cloudUploadCannotQueueOldMetadataWhileResetArchiveCompletionIsPending() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let baseline = syncSnapshot("previous shared baseline")
    let local = syncSnapshot("current local conversation")
    var archive = ConversationArchive(sequence: 1, snapshot: local)
    archive.cloudEnabled = true
    archive.cloudFolderBookmark = Data("fixture permission".utf8)
    archive.cloudBaseFingerprint = try baseline.fingerprint()
    try await ConversationStore(root: root).save(archive)
    let provider = SyncProviderFixture(.init(current: baseline), holdWrite: true)
    let cloud = ConversationCloudSync(factory: { _ in provider })
    let store = ResetCheckpointStore(root: root)
    let model = LocalInferenceModel(
        repository: nil, manifest: try ModelManifest.bundled(),
        session: InferenceSession { _, _ in throw InferenceError.modelNotDownloaded },
        chatStore: store, cloud: cloud)
    model.check()
    await model.waitUntilIdle()
    try await provider.waitForWrite()
    model.newChat()
    try await store.resetGate.waitForEntry()
    #expect(!cloud.syncing) // The old upload is invalidated before the durable reset begins.
    await provider.releaseWrite()
    if !cloud.syncing { await cloud.waitUntilIdle() }
    await store.resetGate.release()
    await model.waitUntilIdle()
    await cloud.waitUntilIdle()
    #expect(model.messages.isEmpty)
    let reopened = try await ConversationStore(root: root).load()
    #expect(reopened?.snapshot.messages.isEmpty == true)
    #expect(reopened?.snapshot.conversationID == model.conversationID)
    cloud.pause()
    await cloud.waitUntilIdle()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func disablingDuringConflictSettingsSaveCannotReplaceTheOffStatus() async throws {
    let provider = SyncProviderFixture(.init(current: syncSnapshot("remote")))
    let harness = SyncHarness(local: syncSnapshot("local"), provider: provider)
    harness.start()
    await harness.cloud.waitUntilIdle()
    let choice = try #require(harness.cloud.choices.first)
    let gate = SyncCheckpointGate()
    let persist = harness.cloud.persist
    harness.cloud.persist = {
        await gate.blockOnce()
        try await persist?()
    }
    harness.cloud.resolve(choiceID: choice.id)
    try await gate.waitForEntry()
    harness.cloud.disable()
    await gate.release()
    await harness.cloud.waitUntilIdle()
    #expect(!harness.cloud.enabled)
    #expect(harness.cloud.status == "iCloud is off. Existing cloud files are kept.")
    #expect(harness.cloud.choices.isEmpty)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func disablingDuringConflictApplicationCannotCommitStaleResolutionState() async throws {
    let remote = syncSnapshot("remote")
    let provider = SyncProviderFixture(.init(current: remote))
    let harness = SyncHarness(local: syncSnapshot("local"), provider: provider)
    harness.start()
    await harness.cloud.waitUntilIdle()
    let choice = try #require(harness.cloud.choices.first(where: { $0.snapshot == remote }))
    let gate = SyncCheckpointGate()
    let apply = harness.cloud.apply
    harness.cloud.apply = { snapshot, expected in
        try await apply?(snapshot, expected)
        await gate.blockOnce()
    }
    harness.cloud.resolve(choiceID: choice.id)
    try await gate.waitForEntry()
    harness.cloud.disable()
    await gate.release()
    await harness.cloud.waitUntilIdle()
    #expect(!harness.cloud.enabled)
    #expect(harness.cloud.baseFingerprint == nil)
    #expect(harness.cloud.status == "iCloud is off. Existing cloud files are kept.")
}

@Test @MainActor
func backgroundUnloadAndLocalSavesDoNotRestartCloudUntilForeground() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let baseline = syncSnapshot("shared")
    var archive = ConversationArchive(sequence: 1, snapshot: baseline)
    archive.cloudEnabled = true
    archive.cloudFolderBookmark = Data("fixture permission".utf8)
    archive.cloudBaseFingerprint = try baseline.fingerprint()
    try await ConversationStore(root: root).save(archive)
    let provider = SyncProviderFixture(.init(current: baseline, uploaded: true))
    let cloud = ConversationCloudSync(factory: { _ in provider })
    let model = LocalInferenceModel(
        repository: nil, manifest: try ModelManifest.bundled(),
        session: InferenceSession { _, _ in throw InferenceError.modelNotDownloaded },
        chatStore: ConversationStore(root: root), cloud: cloud)
    model.check()
    await model.waitUntilIdle()
    await cloud.waitUntilIdle()
    let reads = await provider.reads
    model.enteredBackground()
    await model.waitUntilIdle()
    model.prompt = "Local draft while inactive"
    try await model.flushChatStorage()
    cloud.requestSync()
    cloud.resume()
    await cloud.waitUntilIdle()
    #expect(await provider.reads == reads)
    model.becameActive()
    await cloud.waitUntilIdle()
    #expect(await provider.reads > reads)
    cloud.pause()
    await cloud.waitUntilIdle()
}

@Test @MainActor
func providerTransferFailureStaysAnErrorRatherThanPendingConfirmation() async throws {
    let failure = CocoaError(.fileWriteOutOfSpace)
    let provider = SyncProviderFixture(readFailure: failure)
    let harness = SyncHarness(local: syncSnapshot("local"), provider: provider)
    harness.start()
    await harness.cloud.waitUntilIdle()
    #expect(harness.cloud.error == failure.localizedDescription)
    #expect(harness.cloud.status == "iCloud synchronization needs attention.")
    #expect(await provider.writes == 0)
    harness.cloud.pause()
    await harness.cloud.waitUntilIdle()
}


@Test @MainActor
func newChatReevaluatesPendingConflictChoicesWithoutManualRefresh() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let baseline = syncSnapshot("baseline")
    let local = syncSnapshot("local edit")
    let remote = syncSnapshot("remote edit")
    var archive = ConversationArchive(sequence: 1, snapshot: local)
    archive.cloudEnabled = true
    archive.cloudFolderBookmark = Data("fixture permission".utf8)
    archive.cloudBaseFingerprint = try baseline.fingerprint()
    try await ConversationStore(root: root).save(archive)
    let provider = SyncProviderFixture(.init(current: remote))
    let cloud = ConversationCloudSync(factory: { _ in provider })
    let model = LocalInferenceModel(
        repository: nil, manifest: try ModelManifest.bundled(),
        session: InferenceSession { _, _ in throw InferenceError.modelNotDownloaded },
        chatStore: ConversationStore(root: root), cloud: cloud)
    model.check()
    await model.waitUntilIdle()
    await cloud.waitUntilIdle()
    #expect(cloud.choices.contains(where: { $0.snapshot == local }))
    let reads = await provider.reads
    model.newChat()
    await model.waitUntilIdle()
    await cloud.waitUntilIdle()
    let reset = try #require(try await ConversationStore(root: root).load()).snapshot
    #expect(model.messages.isEmpty)
    #expect(cloud.choices.contains(where: { $0.snapshot == reset }))
    #expect(!cloud.choices.contains(where: { $0.snapshot == local }))
    #expect(await provider.reads > reads)
    cloud.pause()
    await cloud.waitUntilIdle()
}
