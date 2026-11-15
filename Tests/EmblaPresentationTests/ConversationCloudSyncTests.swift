import Foundation
import Testing
@testable import EmblaCore
@testable import EmblaPresentation

private func syncSnapshot(_ text: String) -> ConversationLibrary {
    ConversationLibrary(chats: [ConversationSnapshot(
        conversationID: UUID(), messages: [ChatMessage(role: .user, text: text)], compaction: .init())])
}

/// Explicit simulated provider for synchronization policy tests; never used by the app constructor.
private actor SyncProviderFixture: CloudConversationStorage {
    var document: CloudConversationRead
    private(set) var reads = 0
    private(set) var writes = 0
    private(set) var resolutions = 0
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
        _ snapshot: ConversationLibrary, replacing: CloudConversationRead,
        resolvingConflicts: Bool
    ) async throws {
        try Task.checkCancellation()
        guard try document.fingerprints == replacing.fingerprints else {
            throw CloudConversationError.changed
        }
        guard resolvingConflicts || document.conflicts.isEmpty else {
            throw CloudConversationError.conflict
        }
        if resolvingConflicts { resolutions += 1 }
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
    func addConflict(_ snapshot: ConversationLibrary) { document.conflicts.append(snapshot) }
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
    var local: ConversationLibrary
    var draft = false
    var busy = false
    var applications = 0
    var settingsSaves = 0
    let cloud: ConversationCloudSync

    init(local: ConversationLibrary, provider: SyncProviderFixture) {
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

@Test(arguments: ["upload", "download", "resolution"]) @MainActor
func failedSyncBaseSaveRetriesBeforeSyncedAndPreservesRemoteOnlyEdits(mode: String) async throws {
    let baseline = syncSnapshot("previous shared base")
    let local = syncSnapshot("local edit")
    let remote = syncSnapshot("remote edit")
    let provider = SyncProviderFixture(.init(
        current: mode == "upload" ? baseline : remote, uploaded: true))
    let harness = SyncHarness(local: mode == "download" ? baseline : local, provider: provider)
    var saves = 0
    var durableBase: String?
    harness.cloud.persist = { [weak cloud = harness.cloud] in
        saves += 1
        if saves == 1 { throw CocoaError(.fileWriteOutOfSpace) }
        durableBase = cloud?.baseFingerprint
    }
    harness.start(base: mode == "resolution" ? nil : try baseline.fingerprint())
    await harness.cloud.waitUntilIdle()
    if mode == "resolution" {
        let choice = try #require(harness.cloud.choices.first { $0.snapshot == local })
        harness.cloud.resolve(choiceID: choice.id)
        await harness.cloud.waitUntilIdle()
    }
    #expect(harness.cloud.error != nil && durableBase == nil)
    #expect(harness.cloud.status != "Synced with iCloud Drive.")
    await provider.confirmUpload()
    harness.cloud.refresh()
    await harness.cloud.waitUntilIdle()
    #expect(saves == 2)
    #expect(durableBase == (try harness.local.fingerprint()))
    #expect(harness.cloud.error == nil && harness.cloud.status == "Synced with iCloud Drive.")
    let laterEdit = syncSnapshot("edit made only on another device after synchronization")
    let reopened = SyncHarness(
        local: harness.local, provider: SyncProviderFixture(.init(current: laterEdit, uploaded: true)))
    reopened.start(base: try #require(durableBase))
    await reopened.cloud.waitUntilIdle()
    #expect(reopened.local == laterEdit && reopened.applications == 1)
    #expect(reopened.cloud.choices.isEmpty)
    harness.cloud.pause()
    reopened.cloud.pause()
}

private actor BaseSaveFailureStore: ConversationStoring {
    private let store: ConversationStore
    private let originalBase: String
    private var failNextBase = true
    init(root: URL, originalBase: String) {
        store = ConversationStore(root: root)
        self.originalBase = originalBase
    }
    func load() async throws -> ConversationArchive? { try await store.load() }
    func save(_ archive: ConversationArchive) async throws {
        if failNextBase, archive.cloudEnabled, archive.cloudBaseFingerprint != originalBase {
            failNextBase = false
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try await store.save(archive)
    }
}

private actor ReplacementSaveFailureStore: ConversationStoring {
    private let store: ConversationStore
    private let replacementID: UUID
    private var failOnce = true
    init(root: URL, replacementID: UUID) {
        store = ConversationStore(root: root)
        self.replacementID = replacementID
    }
    func load() async throws -> ConversationArchive? { try await store.load() }
    func save(_ archive: ConversationArchive) async throws {
        if failOnce, archive.snapshot.conversationID == replacementID {
            failOnce = false
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try await store.save(archive)
    }
}

@Test @MainActor
func failedCloudReplacementKeepsVisibleIdentityAndRetryDownloadsWithoutConflict() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let baseline = syncSnapshot("unchanged local chat")
    let remote = syncSnapshot("remote-only edit")
    var archive = ConversationArchive(sequence: 1, snapshot: baseline.chats[0])
    archive.cloudEnabled = true
    archive.cloudFolderBookmark = Data("fixture permission".utf8)
    archive.cloudBaseFingerprint = try baseline.fingerprint()
    try await ConversationStore(root: root).save(archive)
    let provider = SyncProviderFixture(.init(current: remote, uploaded: true))
    let cloud = ConversationCloudSync(factory: { _ in provider })
    let model = LocalInferenceModel(
        repository: nil, manifest: try ModelManifest.bundled(),
        session: InferenceSession { _, _ in throw InferenceError.modelNotDownloaded },
        chatStore: ReplacementSaveFailureStore(root: root, replacementID: remote.chats[0].conversationID),
        cloud: cloud)
    model.check()
    await model.waitUntilIdle()
    await cloud.waitUntilIdle()
    #expect(model.storageError != nil && cloud.error != nil)
    #expect(model.messages == baseline.chats[0].messages)
    #expect(cloud.current?()?.snapshot == baseline)
    #expect(try await ConversationStore(root: root).load()?.library == baseline)
    try await model.flushChatStorage()
    #expect(cloud.current?()?.snapshot == baseline)
    cloud.refresh()
    await cloud.waitUntilIdle()
    #expect(model.messages == remote.chats[0].messages)
    #expect(model.storageError == nil && cloud.error == nil && cloud.choices.isEmpty)
    #expect(try await ConversationStore(root: root).load()?.library == remote)
    cloud.pause()
}

@Test @MainActor
func storageRetryThenSyncSavesTheNewBaseBeforeReopeningAndAcceptingRemoteEdits() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let baseline = syncSnapshot("old shared base")
    let local = syncSnapshot("new local chat")
    let base = try baseline.fingerprint()
    var archive = ConversationArchive(sequence: 1, snapshot: local.chats[0])
    archive.cloudEnabled = true
    archive.cloudFolderBookmark = Data("fixture permission".utf8)
    archive.cloudBaseFingerprint = base
    try await ConversationStore(root: root).save(archive)
    let provider = SyncProviderFixture(.init(current: baseline))
    let cloud = ConversationCloudSync(factory: { _ in provider })
    let model = LocalInferenceModel(
        repository: nil, manifest: try ModelManifest.bundled(),
        session: InferenceSession { _, _ in throw InferenceError.modelNotDownloaded },
        chatStore: BaseSaveFailureStore(root: root, originalBase: base), cloud: cloud)
    model.check()
    await model.waitUntilIdle()
    await cloud.waitUntilIdle()
    #expect(model.storageError != nil && cloud.error != nil)
    #expect(try await ConversationStore(root: root).load()?.cloudBaseFingerprint == base)
    try await model.flushChatStorage()
    cloud.refresh()
    await cloud.waitUntilIdle()
    let saved = try #require(try await ConversationStore(root: root).load())
    #expect(saved.cloudBaseFingerprint == (try local.fingerprint()))
    let laterEdit = syncSnapshot("another device's subsequent edit")
    let laterProvider = SyncProviderFixture(.init(current: laterEdit, uploaded: true))
    let laterCloud = ConversationCloudSync(factory: { _ in laterProvider })
    let reopened = LocalInferenceModel(
        repository: nil, manifest: try ModelManifest.bundled(),
        session: InferenceSession { _, _ in throw InferenceError.modelNotDownloaded },
        chatStore: ConversationStore(root: root), cloud: laterCloud)
    reopened.check()
    await reopened.waitUntilIdle()
    await laterCloud.waitUntilIdle()
    #expect(reopened.messages == laterEdit.chats[0].messages && laterCloud.choices.isEmpty)
    cloud.pause()
    laterCloud.pause()
}

@Test @MainActor
func unresolvedCopiesBlockAutomaticWritesEvenWhenCurrentMatchesLocal() async throws {
    let local = syncSnapshot("shared current chat")
    let first = syncSnapshot("first unresolved copy")
    let second = syncSnapshot("second unresolved copy")
    let provider = SyncProviderFixture(.init(
        current: local, conflicts: [first, second, first], uploaded: true))
    let harness = SyncHarness(local: local, provider: provider)
    harness.start(base: try local.fingerprint())
    await harness.cloud.waitUntilIdle()
    #expect(await provider.writes == 0)
    #expect(harness.applications == 0)
    #expect(Set(harness.cloud.choices.map(\.id)) == Set(try [local, first, second].map {
        try $0.fingerprint()
    }))
    #expect(harness.cloud.choices.count == 3)
    harness.cloud.pause()
}

@Test @MainActor
func everyDistinctUnresolvedCopyIsOfferedAndOnlyExplicitChoiceResolvesIt() async throws {
    let local = syncSnapshot("local chat")
    let current = syncSnapshot("current cloud chat")
    let first = syncSnapshot("first unresolved copy")
    let second = syncSnapshot("second unresolved copy")
    let provider = SyncProviderFixture(.init(current: current, conflicts: [first, second, first]))
    let harness = SyncHarness(local: local, provider: provider)
    harness.start()
    await harness.cloud.waitUntilIdle()
    #expect(harness.cloud.choices.count == 4)
    #expect(await provider.writes == 0)
    let choice = try #require(harness.cloud.choices.first { $0.snapshot == second })
    harness.cloud.resolve(choiceID: choice.id)
    await harness.cloud.waitUntilIdle()
    #expect(harness.local == second)
    #expect(harness.cloud.choices.isEmpty)
    #expect(await provider.document.current == second)
    #expect(await provider.document.conflicts.isEmpty == true)
    #expect(await provider.resolutions == 1)
    harness.cloud.pause()
}

@Test @MainActor
func newUnresolvedCopyInvalidatesThePendingResolutionUntilRefreshed() async throws {
    let local = syncSnapshot("local chat")
    let current = syncSnapshot("current cloud chat")
    let first = syncSnapshot("existing unresolved copy")
    let newlyArrived = syncSnapshot("new unresolved copy")
    let provider = SyncProviderFixture(.init(current: current, conflicts: [first]))
    let harness = SyncHarness(local: local, provider: provider)
    harness.start()
    await harness.cloud.waitUntilIdle()
    let choice = try #require(harness.cloud.choices.first { $0.snapshot == first })
    await provider.addConflict(newlyArrived)
    harness.cloud.resolve(choiceID: choice.id)
    await harness.cloud.waitUntilIdle()
    #expect(harness.cloud.error == CloudConversationError.changed.localizedDescription)
    #expect(harness.local == local)
    #expect(await provider.writes == 0)
    #expect(await provider.document.conflicts == [first, newlyArrived])
    harness.cloud.refresh()
    await harness.cloud.waitUntilIdle()
    #expect(harness.cloud.choices.count == 4)
    let refreshed = try #require(harness.cloud.choices.first { $0.snapshot == newlyArrived })
    harness.cloud.resolve(choiceID: refreshed.id)
    await harness.cloud.waitUntilIdle()
    #expect(harness.local == newlyArrived)
    #expect(await provider.resolutions == 1)
    harness.cloud.pause()
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
    let reset = ConversationLibrary(chats: [ConversationSnapshot(
        conversationID: UUID(), messages: [], compaction: .init())])
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
    var archive = ConversationArchive(sequence: 1, snapshot: baseline.chats[0])
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
    #expect(model.messages == remote.chats[0].messages)
    #expect(model.conversationID == remote.chats[0].conversationID)
    let local = try await ConversationStore(root: root).load()
    #expect(local?.library == remote)
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
    var archive = ConversationArchive(sequence: 1, snapshot: baseline.chats[0])
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
    let uploaded = try #require(await provider.document.current)
    #expect(uploaded.chats.first(where: { $0.conversationID == resetID })?.messages.isEmpty == true)
    #expect(uploaded.chats.contains(baseline.chats[0]))
    #expect(try await ConversationStore(root: root).load()?.snapshot.conversationID == resetID)
    cloud.pause()
    await cloud.waitUntilIdle()
}

@Test @MainActor
func disabledPreferenceWithAnOldFolderBookmarkNeverOpensTheProviderOnRestore() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var archive = ConversationArchive(sequence: 1, snapshot: syncSnapshot("private local message").chats[0])
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

/// Holds the first enabled-preference write before it becomes durable.
private actor PreferenceCheckpointStore: ConversationStoring {
    private let store: ConversationStore
    let gate = SyncCheckpointGate()
    private var failEnabled: Bool

    init(root: URL, failEnabled: Bool = false) {
        store = ConversationStore(root: root)
        self.failEnabled = failEnabled
    }
    func load() async throws -> ConversationArchive? { try await store.load() }
    func save(_ archive: ConversationArchive) async throws {
        if archive.cloudEnabled {
            await gate.blockOnce()
            if failEnabled {
                failEnabled = false
                throw CocoaError(.fileWriteOutOfSpace)
            }
        }
        try await store.save(archive)
    }
    func allowEnabledSaves() { failEnabled = false }
}

@Test @MainActor
func failedFolderPreferenceChangeReportsTheSavedOnSettingWithoutResumingProvider() async throws {
    let provider = SyncProviderFixture()
    let harness = SyncHarness(local: syncSnapshot("saved chat"), provider: provider)
    harness.cloud.restore(enabled: true, bookmark: Data("saved permission".utf8), base: nil)
    harness.cloud.persist = { throw CocoaError(.fileWriteOutOfSpace) }
    do {
        try await harness.cloud.enable(bookmark: Data("new permission".utf8))
        Issue.record("Changing the folder preference must fail.")
    } catch { #expect((error as? CocoaError)?.code == .fileWriteOutOfSpace) }
    #expect(harness.cloud.enabled)
    #expect(harness.cloud.error != nil)
    #expect(harness.cloud.status.contains("saved setting is still on"))
    harness.cloud.setForeground(false)
    harness.cloud.setForeground(true)
    await harness.cloud.waitUntilIdle()
    #expect(await provider.reads == 0)
    #expect(await provider.writes == 0)
    harness.cloud.pause()
}

private actor OffSaveFailureStore: ConversationStoring {
    private let store: ConversationStore
    private var failOffOnce = true
    init(root: URL) { store = ConversationStore(root: root) }
    func load() async throws -> ConversationArchive? { try await store.load() }
    func save(_ archive: ConversationArchive) async throws {
        if failOffOnce, !archive.cloudEnabled {
            failOffOnce = false
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try await store.save(archive)
    }
}

@Test @MainActor
func backgroundPauseDoesNotHideFailedOffSaveAndStorageRetryConfirmsOff() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let snapshot = syncSnapshot("saved cloud chat")
    var archive = ConversationArchive(sequence: 1, snapshot: snapshot.chats[0])
    archive.cloudEnabled = true
    archive.cloudFolderBookmark = Data("saved permission".utf8)
    archive.cloudBaseFingerprint = try snapshot.fingerprint()
    try await ConversationStore(root: root).save(archive)
    let provider = SyncProviderFixture(.init(current: snapshot, uploaded: true))
    let cloud = ConversationCloudSync(factory: { _ in provider })
    let model = LocalInferenceModel(
        repository: nil, manifest: try ModelManifest.bundled(),
        session: InferenceSession { _, _ in throw InferenceError.modelNotDownloaded },
        chatStore: OffSaveFailureStore(root: root), cloud: cloud)
    model.check()
    await model.waitUntilIdle()
    await cloud.waitUntilIdle()
    let reads = await provider.reads
    cloud.disable()
    cloud.setForeground(false)
    await cloud.waitUntilIdle()
    #expect(!cloud.enabled && cloud.error != nil)
    #expect(cloud.status.contains("saved setting is still on"))
    #expect(try await ConversationStore(root: root).load()?.cloudEnabled == true)
    try await model.flushChatStorage()
    #expect(cloud.error == nil)
    #expect(cloud.status == "iCloud is off. Existing cloud files are kept.")
    #expect(try await ConversationStore(root: root).load()?.cloudEnabled == false)
    cloud.setForeground(true)
    await cloud.waitUntilIdle()
    #expect(await provider.reads == reads)
    #expect(await provider.writes == 0)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func checkpointQueuedDuringFailedConsentCannotEnableCloudAfterReopening() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let snapshot = syncSnapshot("local conversation before consent")
    try await ConversationStore(root: root).save(ConversationArchive(sequence: 1, snapshot: snapshot.chats[0]))
    let provider = SyncProviderFixture()
    let cloud = ConversationCloudSync(factory: { _ in provider })
    let store = PreferenceCheckpointStore(root: root, failEnabled: true)
    let model = LocalInferenceModel(
        repository: nil, manifest: try ModelManifest.bundled(),
        session: InferenceSession { _, _ in throw InferenceError.modelNotDownloaded },
        chatStore: store, cloud: cloud)
    model.check()
    await model.waitUntilIdle()
    let enabling = Task { try await cloud.enable(bookmark: Data("fixture permission".utf8)) }
    try await store.gate.waitForEntry()
    model.prompt = "Draft checkpoint during pending consent"
    let checkpoint = Task { try await model.flushChatStorage() }
    for _ in 0..<20 { await Task.yield() }
    await store.gate.release()
    do {
        try await enabling.value
        Issue.record("Consent save must fail.")
    } catch { #expect((error as? CocoaError)?.code == .fileWriteOutOfSpace) }
    try await checkpoint.value
    let saved = try #require(try await ConversationStore(root: root).load())
    #expect(!cloud.enabled && !saved.cloudEnabled)
    #expect(saved.draft == model.prompt && saved.library == snapshot)
    let reopenedCloud = ConversationCloudSync(factory: { _ in provider })
    let reopened = LocalInferenceModel(
        repository: nil, manifest: try ModelManifest.bundled(),
        session: InferenceSession { _, _ in throw InferenceError.modelNotDownloaded },
        chatStore: ConversationStore(root: root), cloud: reopenedCloud)
    reopened.check()
    await reopened.waitUntilIdle()
    await reopenedCloud.waitUntilIdle()
    #expect(!reopenedCloud.enabled)
    #expect(reopened.prompt == model.prompt)
    #expect(await provider.reads == 0)
    #expect(await provider.writes == 0)
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true]) @MainActor
func optInWaitsForDurableConsentAndPendingDisablePreventsProviderAccess(
    disableWhileSaving: Bool
) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let snapshot = syncSnapshot("private until consent is saved")
    try await ConversationStore(root: root).save(ConversationArchive(sequence: 1, snapshot: snapshot.chats[0]))
    let provider = SyncProviderFixture()
    let cloud = ConversationCloudSync(factory: { _ in provider })
    let store = PreferenceCheckpointStore(root: root)
    let model = LocalInferenceModel(
        repository: nil, manifest: try ModelManifest.bundled(),
        session: InferenceSession { _, _ in throw InferenceError.modelNotDownloaded },
        chatStore: store, cloud: cloud)
    model.check()
    await model.waitUntilIdle()
    let enabling = Task { try await cloud.enable(bookmark: Data("fixture permission".utf8)) }
    try await store.gate.waitForEntry()
    // Lifecycle callbacks and manual refresh must not bypass the pending consent save.
    cloud.resume()
    cloud.setForeground(false)
    cloud.setForeground(true)
    cloud.refresh()
    #expect(await provider.reads == 0)
    #expect(await provider.writes == 0)
    #expect(try await ConversationStore(root: root).load()?.cloudEnabled == false)
    if disableWhileSaving { cloud.disable() }
    await store.gate.release()
    try await enabling.value
    await cloud.waitUntilIdle()
    let saved = try #require(try await ConversationStore(root: root).load())
    #expect(saved.cloudEnabled == !disableWhileSaving)
    #expect(saved.library == snapshot)
    if disableWhileSaving {
        #expect(await provider.reads == 0)
        #expect(await provider.writes == 0)
    } else {
        #expect(await provider.reads > 0)
        #expect(await provider.writes == 1)
    }
    cloud.pause()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func failedOptInSaveStaysOffWithoutProviderAccessAndCanBeRetried() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let snapshot = syncSnapshot("preserve this local chat")
    try await ConversationStore(root: root).save(ConversationArchive(sequence: 1, snapshot: snapshot.chats[0]))
    let provider = SyncProviderFixture()
    let cloud = ConversationCloudSync(factory: { _ in provider })
    let store = PreferenceCheckpointStore(root: root, failEnabled: true)
    let model = LocalInferenceModel(
        repository: nil, manifest: try ModelManifest.bundled(),
        session: InferenceSession { _, _ in throw InferenceError.modelNotDownloaded },
        chatStore: store, cloud: cloud)
    model.check()
    await model.waitUntilIdle()
    let enabling = Task { try await cloud.enable(bookmark: Data("fixture permission".utf8)) }
    try await store.gate.waitForEntry()
    await store.gate.release()
    do {
        try await enabling.value
        Issue.record("Opt-in must fail when consent cannot be saved.")
    } catch { #expect((error as? CocoaError)?.code == .fileWriteOutOfSpace) }
    #expect(!cloud.enabled && cloud.error != nil && model.storageError != nil)
    #expect(await provider.reads == 0)
    #expect(await provider.writes == 0)
    let saved = try #require(try await ConversationStore(root: root).load())
    #expect(!saved.cloudEnabled && saved.library == snapshot)
    await store.allowEnabledSaves()
    try await cloud.enable(bookmark: Data("fixture permission".utf8))
    await cloud.waitUntilIdle()
    #expect(cloud.enabled && cloud.error == nil && model.storageError == nil)
    #expect(try await ConversationStore(root: root).load()?.cloudEnabled == true)
    #expect(await provider.writes == 1)
    cloud.pause()
}

/// Holds a real empty-archive write's completion while the old transcript is still visible.
private actor ResetCheckpointStore: ConversationStoring {
    private let store: ConversationStore
    private let heldConversationID: UUID?
    let resetGate = SyncCheckpointGate()
    init(root: URL, heldConversationID: UUID? = nil) {
        store = ConversationStore(root: root)
        self.heldConversationID = heldConversationID
    }
    func load() async throws -> ConversationArchive? { try await store.load() }
    func save(_ archive: ConversationArchive) async throws {
        try await store.save(archive)
        let hold = heldConversationID.map { archive.snapshot.conversationID == $0 }
            ?? archive.snapshot.messages.isEmpty
        if hold { await resetGate.blockOnce() }
    }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func disablingDuringCloudReplacementPreservesTheDurableRestoredChat() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let baseline = syncSnapshot("old shared chat")
    let remote = syncSnapshot("restored shared chat")
    var archive = ConversationArchive(sequence: 1, snapshot: baseline.chats[0])
    archive.cloudEnabled = true
    archive.cloudFolderBookmark = Data("fixture permission".utf8)
    archive.cloudBaseFingerprint = try baseline.fingerprint()
    try await ConversationStore(root: root).save(archive)
    let provider = SyncProviderFixture(.init(current: remote, uploaded: true))
    let cloud = ConversationCloudSync(factory: { _ in provider })
    let store = ResetCheckpointStore(root: root, heldConversationID: remote.chats[0].conversationID)
    let model = LocalInferenceModel(
        repository: nil, manifest: try ModelManifest.bundled(),
        session: InferenceSession { _, _ in throw InferenceError.modelNotDownloaded },
        chatStore: store, cloud: cloud)
    model.check()
    await model.waitUntilIdle()
    try await store.resetGate.waitForEntry()
    #expect(model.messages == baseline.chats[0].messages && model.resetting)
    cloud.disable()
    for _ in 0..<20 { await Task.yield() }
    await store.resetGate.release()
    await cloud.waitUntilIdle()
    let reopened = try #require(try await ConversationStore(root: root).load())
    #expect(model.messages == remote.chats[0].messages && reopened.library == remote)
    #expect(!reopened.cloudEnabled)
}

@Test @MainActor
func unchangedCloudPollDoesNotRewriteTheLocalArchive() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let snapshot = syncSnapshot("unchanged shared chat")
    var archive = ConversationArchive(sequence: 1, snapshot: snapshot.chats[0])
    archive.cloudEnabled = true
    archive.cloudFolderBookmark = Data("fixture permission".utf8)
    archive.cloudBaseFingerprint = try snapshot.fingerprint()
    let store = ConversationStore(root: root)
    try await store.save(archive)
    let provider = SyncProviderFixture(.init(current: snapshot, uploaded: true))
    let cloud = ConversationCloudSync(factory: { _ in provider })
    let model = LocalInferenceModel(
        repository: nil, manifest: try ModelManifest.bundled(),
        session: InferenceSession { _, _ in throw InferenceError.modelNotDownloaded },
        chatStore: store, cloud: cloud)
    model.check()
    await model.waitUntilIdle()
    await cloud.waitUntilIdle()
    let before = try await store.load()
    cloud.refresh()
    await cloud.waitUntilIdle()
    #expect(try await store.load() == before)
    #expect(await provider.reads >= 2)
    #expect(await provider.writes == 0)
    #expect(cloud.status == "Synced with iCloud Drive.")
    cloud.pause()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func disablingCloudDuringDurableResetCannotSaveTheOldTranscriptAgain() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let local = syncSnapshot("chat being cleared")
    var archive = ConversationArchive(sequence: 1, snapshot: local.chats[0])
    archive.cloudEnabled = true
    archive.cloudFolderBookmark = Data("fixture permission".utf8)
    archive.cloudBaseFingerprint = try local.fingerprint()
    try await ConversationStore(root: root).save(archive)
    let provider = SyncProviderFixture(.init(current: local))
    let cloud = ConversationCloudSync(factory: { _ in provider })
    let store = ResetCheckpointStore(root: root)
    let model = LocalInferenceModel(
        repository: nil, manifest: try ModelManifest.bundled(),
        session: InferenceSession { _, _ in throw InferenceError.modelNotDownloaded },
        chatStore: store, cloud: cloud)
    model.check()
    await model.waitUntilIdle()
    await cloud.waitUntilIdle()
    model.newChat()
    try await store.resetGate.waitForEntry()
    #expect(model.messages == local.chats[0].messages)
    cloud.disable()
    // Let the preference task enter persistence while reset completion is held.
    for _ in 0..<20 { await Task.yield() }
    await store.resetGate.release()
    await model.waitUntilIdle()
    await cloud.waitUntilIdle()
    let reopened = try #require(try await ConversationStore(root: root).load())
    #expect(model.messages.isEmpty && reopened.snapshot.messages.isEmpty)
    #expect(reopened.snapshot.conversationID == model.conversationID)
    #expect(!reopened.cloudEnabled)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func cloudUploadCannotQueueOldMetadataWhileResetArchiveCompletionIsPending() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let baseline = syncSnapshot("previous shared baseline")
    let local = syncSnapshot("current local conversation")
    var archive = ConversationArchive(sequence: 1, snapshot: local.chats[0])
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
    var archive = ConversationArchive(sequence: 1, snapshot: baseline.chats[0])
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
    var archive = ConversationArchive(sequence: 1, snapshot: local.chats[0])
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
    let reset = try #require(try await ConversationStore(root: root).load()).library
    #expect(model.messages.isEmpty)
    #expect(cloud.choices.contains(where: { $0.snapshot == reset }))
    #expect(!cloud.choices.contains(where: { $0.snapshot == local }))
    #expect(await provider.reads > reads)
    cloud.pause()
    await cloud.waitUntilIdle()
}

@Test @MainActor
func globalOptInUploadsAllChatsButNeverAnyDrafts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = syncSnapshot("Earlier saved transcript").chats[0]
    let active = syncSnapshot("Selected saved transcript").chats[0]
    var archive = ConversationArchive(sequence: 1, snapshot: active, draft: "PRIVATE ACTIVE DRAFT")
    archive.history = [SavedConversation(snapshot: first, draft: "PRIVATE HISTORY DRAFT")]
    try await ConversationStore(root: root).save(archive)
    let provider = SyncProviderFixture()
    let cloud = ConversationCloudSync(factory: { _ in provider })
    let model = LocalInferenceModel(
        repository: nil, manifest: try ModelManifest.bundled(),
        session: InferenceSession { _, _ in throw InferenceError.modelNotDownloaded },
        chatStore: ConversationStore(root: root), cloud: cloud)
    model.check()
    await model.waitUntilIdle()
    model.selectChat(first.conversationID)
    await model.waitUntilIdle()
    #expect(await provider.reads == 0)
    #expect(await provider.writes == 0)
    try await cloud.enable(bookmark: Data("explicit fixture consent".utf8))
    await cloud.waitUntilIdle()
    let uploaded = try #require(await provider.document.current)
    #expect(Set(uploaded.chats.map(\.conversationID)) == [first.conversationID, active.conversationID])
    let bytes = String(decoding: try uploaded.encodedDocument(), as: UTF8.self)
    #expect(!bytes.contains("PRIVATE ACTIVE DRAFT") && !bytes.contains("PRIVATE HISTORY DRAFT"))
    let saved = try #require(try await ConversationStore(root: root).load())
    #expect(saved.draft == "PRIVATE HISTORY DRAFT")
    #expect(saved.history?.first?.draft == "PRIVATE ACTIVE DRAFT")
    cloud.disable()
    await cloud.waitUntilIdle()
}

@Test @MainActor
func inactiveDraftPreventsAutomaticWholeLibraryReplacement() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let active = syncSnapshot("Selected chat").chats[0]
    let previous = syncSnapshot("Previous chat").chats[0]
    var archive = ConversationArchive(sequence: 1, snapshot: active)
    archive.history = [SavedConversation(snapshot: previous, draft: "Keep this inactive draft")]
    archive.cloudEnabled = true
    archive.cloudFolderBookmark = Data("fixture consent".utf8)
    archive.cloudBaseFingerprint = try archive.library.fingerprint()
    try await ConversationStore(root: root).save(archive)
    var remote = archive.library
    remote.chats[0].messages[0].text = "Changed on the other device"
    let provider = SyncProviderFixture(.init(current: remote))
    let cloud = ConversationCloudSync(factory: { _ in provider })
    let model = LocalInferenceModel(
        repository: nil, manifest: try ModelManifest.bundled(),
        session: InferenceSession { _, _ in throw InferenceError.modelNotDownloaded },
        chatStore: ConversationStore(root: root), cloud: cloud)
    model.check()
    await model.waitUntilIdle()
    await cloud.waitUntilIdle()
    #expect(model.history.first?.draft == "Keep this inactive draft")
    #expect(model.cloud.current?()?.snapshot == archive.library)
    #expect(cloud.choices.count == 2)
    #expect(await provider.writes == 0)
    cloud.disable()
    await cloud.waitUntilIdle()
}
