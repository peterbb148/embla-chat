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
    private var gate: CheckedContinuation<Void, Never>?

    init(_ document: CloudConversationRead = .init(), holdRead: Bool = false) {
        self.document = document
        self.holdRead = holdRead
    }
    func read() async throws -> CloudConversationRead {
        reads += 1
        if holdRead {
            holdRead = false
            await withCheckedContinuation { gate = $0 }
        }
        return document
    }
    func write(
        _ snapshot: ConversationSnapshot, replacing: CloudConversationRead,
        resolvingConflicts: Bool
    ) throws {
        try Task.checkCancellation()
        guard try document.fingerprints == replacing.fingerprints else {
            throw CloudConversationError.changed
        }
        writes += 1
        document = CloudConversationRead(current: snapshot)
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
