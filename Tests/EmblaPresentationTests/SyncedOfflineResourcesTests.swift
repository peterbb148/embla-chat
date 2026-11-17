import Darwin
import Foundation
import Synchronization
import Testing

import EmblaCore
@testable import EmblaPresentation

private func snapshotRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test @MainActor func syncedActionsSurviveOfflineColdStartWithoutOpeningCloudOrDeviceProfile()
    async throws
{
    let root = try snapshotRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let state = root.appendingPathComponent("State")
    let cache = SyncedResourceCache(root: state.appendingPathComponent("CloudSnapshots"))
    let bookmark = Data("synthetic durable cloud grant".utf8)
    let configuration = QuickActionConfiguration(actions: [
        QuickAction(id: "synced", label: "Saved action", order: 0, prompt: "My synced prompt")
    ])
    try cache.write(configuration.encoded(), name: "actions", bookmark: bookmark)
    let policy = NetworkAccess(initialState: .unsatisfied)
    let local = root.appendingPathComponent("OffProfile")
    let cloud = ConversationCloudSync(network: policy)
    cloud.restore(enabled: true, bookmark: bookmark, base: nil)
    let model = QuickActionsModel(
        storage: QuickActionStore(localRoot: local, stateRoot: state, network: policy))
    model.reload(using: cloud)
    await model.waitUntilIdle()
    #expect(model.error == nil && model.actions == configuration.actions)
    #expect(model.sourceDescription.contains("Last synced"))
    #expect(try model.prompt(for: configuration.actions[0], using: cloud) == "My synced prompt")
    #expect(!FileManager.default.fileExists(atPath: local.path))
    #expect(cloud.enabled && !cloud.folderAccessReady && cloud.authorizedFolderBookmark == nil)
    await #expect(throws: NetworkAccessFailure.offline) {
        try await QuickActionStore(localRoot: local, stateRoot: state, network: policy)
            .createStarter(.cachedCloud(bookmark))
    }
    cloud.restore(enabled: true, bookmark: Data("another folder".utf8), base: nil)
    model.reload(using: cloud)
    await model.waitUntilIdle()
    #expect(model.actions.isEmpty && model.error?.contains("not been saved") == true)
    cloud.restore(enabled: true, bookmark: bookmark, base: nil, consentVersion: 1)
    model.reload(using: cloud)
    await model.waitUntilIdle()
    #expect(model.actions.isEmpty && model.error != nil)
}

private final class SnapshotSettingsFixture: SharedSettingsStoring, @unchecked Sendable {
    let identity = "synthetic snapshot settings"
    let reads = Mutex(0)
    let document: SharedSettings
    init(_ document: SharedSettings) { self.document = document }
    func read() throws -> SharedSettingsRead {
        reads.withLock { $0 += 1 }
        return SharedSettingsRead(current: document)
    }
    func write(
        _ value: SharedSettings, replacing: SharedSettingsRead, resolve: Bool,
        access: SettingsAccessLease
    ) throws {
        throw SharedSettingsError.changed
    }
}

@Test @MainActor func syncedSettingsAndSkillsWorkOfflineAfterRestartWithoutProviderReads()
    async throws
{
    let root = try snapshotRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = root.appendingPathComponent("servers.json")
    let bookmark = Data("synthetic grant, never resolved".utf8)
    let policy = NetworkAccess(initialState: .satisfied)
    let server = MCPServer(
        name: "Remote saved registration", endpoint: URL(string: "https://example.invalid/mcp")!,
        enabledTools: ["search"])
    let document = SharedSettings(
        servers: [SharedServer(server, token: "synthetic-key")], selectedSkill: "saved-skill")
    let provider = SnapshotSettingsFixture(document)
    let cloud = ConversationCloudSync(network: policy)
    cloud.restore(enabled: true, bookmark: bookmark, base: nil)
    let first = ToolWorkspace(
        configuration: configuration, network: policy, settingsFactory: { _ in provider })
    await first.reloadSettings(using: cloud)
    #expect(first.settingsError == nil && provider.reads.withLock { $0 } == 1)

    let skillData = Data(
        "---\nname: saved-skill\ndescription: Synthetic cached skill.\n---\nRead reference.txt when needed."
            .utf8)
    let skill = try SkillDocument.decode(skillData, directoryName: "saved-skill")
    let skillCacheRoot = root.appendingPathComponent("SkillSnapshots")
    let cache = SyncedResourceCache(root: skillCacheRoot)
    // Explicit cache fixture: no personal iCloud or File Provider access is claimed.
    let listing = ["documents": ["saved-skill": skillData], "errors": [:]]
    try cache.write(JSONEncoder().encode(listing), name: "listing", bookmark: bookmark)
    try cache.write(
        Data("Previously loaded supporting file".utf8),
        name: "resource:saved-skill:\(skill.fingerprint):reference.txt", bookmark: bookmark)

    policy.updatePath(.unsatisfied)
    cloud.connectivityChanged()
    let factoryCalls = Mutex(0)
    let restarted = ToolWorkspace(
        store: SkillStore(
            localRoot: root.appendingPathComponent("OffSkills"), network: policy,
            cacheRoot: skillCacheRoot),
        configuration: configuration, network: policy,
        settingsFactory: { _ in
            factoryCalls.withLock { $0 += 1 }; return provider
        })
    try await restarted.prepare(using: cloud)
    #expect(factoryCalls.withLock { $0 } == 0 && provider.reads.withLock { $0 } == 1)
    #expect(restarted.servers.map(\.id) == [server.id] && restarted.selectedSkill == skill)
    #expect(restarted.settingsStatus.contains("last synced"))
    #expect(try restarted.token(for: server) == "synthetic-key")
    await #expect(throws: SharedSettingsError.unavailable) {
        try await restarted.removeServer(server.id)
    }
    #expect(try restarted.specifications(using: cloud).map(\.name) == ["read_skill_file"])
    let invocation = try restarted.invocation(
        server: "skill", name: "read_skill_file", arguments: ["path": .string("reference.txt")])
    #expect(
        try await restarted.execute(invocation, using: cloud)
            == .object(["text": .string("Previously loaded supporting file")]))
    await #expect(throws: SyncedResourceFailure.self) {
        try await restarted.readResource("not-cached.txt", skill: skill, using: cloud)
    }
    #expect(throws: NetworkAccessFailure.offline) {
        try restarted.invocation(server: server.modelID, name: "search", arguments: [:])
    }
    // An offline choice lasts through Send preparation but never writes the shared document.
    try await restarted.selectSkill(nil, using: cloud)
    try await restarted.prepare(using: cloud)
    #expect(restarted.selectedSkill == nil)
    #expect(try restarted.specifications(using: cloud).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("OffSkills").path))
    cloud.restore(enabled: true, bookmark: bookmark, base: nil)
    try await restarted.prepare(using: cloud)
    #expect(restarted.selectedSkill == skill)
    let preparedRevision = restarted.revision
    policy.updatePath(.satisfied)
    policy.activateRequests(after: policy.snapshot.revision)
    cloud.connectivityChanged()
    await restarted.reloadSettings(using: cloud)
    try restarted.validateRequestConfiguration(preparedRevision, using: cloud)
    #expect(try restarted.specifications(using: cloud).map(\.name) == ["read_skill_file"])
    #expect(try restarted.remoteTools(forRequest: true).isEmpty)
    // A later live refresh can change its listing without changing the prepared turn.
    try cache.write(
        JSONEncoder().encode(["documents": [String: Data](), "errors": [:]]),
        name: "listing", bookmark: bookmark)
    let resumedInvocation = try restarted.invocation(
        server: "skill", name: "read_skill_file", arguments: ["path": .string("reference.txt")])
    #expect(
        try await restarted.execute(resumedInvocation, using: cloud)
            == .object(["text": .string("Previously loaded supporting file")]))
    #expect(factoryCalls.withLock { $0 } == 1 && provider.reads.withLock { $0 } == 2)
    // The shared preference still selects the original skill, not the session-only None.
    #expect(provider.document.selectedSkill == "saved-skill")
    policy.updatePath(.unsatisfied)
    cloud.restore(enabled: true, bookmark: Data("different authorized folder".utf8), base: nil)
    await #expect(throws: SkillFailure.self) {
        try await restarted.execute(invocation, using: cloud)
    }
    try await restarted.prepare(using: cloud)
    #expect(restarted.servers.isEmpty && restarted.selectedSkill == nil)
    #expect(factoryCalls.withLock { $0 } == 1)
}

@Test func offlineSkillCacheRejectsUncachedAndChangedDocuments() async throws {
    let root = try snapshotRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let policy = NetworkAccess(initialState: .unsatisfied)
    let store = SkillStore(localRoot: root.appendingPathComponent("NoDeviceReads"), network: policy)
    await #expect(throws: SyncedResourceFailure.self) {
        try await store.entries(.cachedCloud(Data("never loaded".utf8)))
    }
    #expect(
        !FileManager.default.fileExists(atPath: root.appendingPathComponent("NoDeviceReads").path))
    let bookmark = Data("cached skill folder".utf8)
    let cache = SyncedResourceCache(root: root.appendingPathComponent(".synced-skills"))
    let oldData = Data("---\nname: saved-skill\ndescription: Cached.\n---\nOld instructions.".utf8)
    let changedData = Data(
        "---\nname: saved-skill\ndescription: Cached.\n---\nChanged instructions.".utf8)
    let old = try SkillDocument.decode(oldData, directoryName: "saved-skill")
    let changed = try SkillDocument.decode(changedData, directoryName: "saved-skill")
    let listing = ["documents": ["saved-skill": changedData], "errors": [:]]
    try cache.write(JSONEncoder().encode(listing), name: "listing", bookmark: bookmark)
    try cache.write(
        Data("Stale resource".utf8), name: "resource:saved-skill:\(old.fingerprint):reference.txt",
        bookmark: bookmark)
    await #expect(throws: SkillFailure.self) {
        try await store.resource("reference.txt", skill: old, source: .cachedCloud(bookmark))
    }
    await #expect(throws: SyncedResourceFailure.self) {
        try await store.resource("reference.txt", skill: changed, source: .cachedCloud(bookmark))
    }
    for path in ["scripts/run.swift", "../secret.txt"] {
        await #expect(throws: SkillFailure.self) {
            try await store.resource(path, skill: changed, source: .cachedCloud(bookmark))
        }
    }
}

/// Models a synchronous provider operation that ignores Task cancellation until released.
private final class ProviderActorBlock: @unchecked Sendable {
    let entered = Mutex(false)
    private let condition = NSCondition()
    private var released = false
    func hold() {
        condition.lock()
        entered.withLock { $0 = true }
        while !released { condition.wait() }
        condition.unlock()
    }
    func release() {
        condition.lock(); released = true; condition.broadcast(); condition.unlock()
    }
}

extension SkillStore {
    fileprivate func holdProviderActor(_ gate: ProviderActorBlock) { gate.hold() }
}
extension QuickActionStore {
    fileprivate func holdProviderActor(_ gate: ProviderActorBlock) { gate.hold() }
}

@MainActor private func waitForSnapshotCondition(_ condition: () -> Bool) async throws -> Bool {
    for _ in 0..<1_000 {
        if condition() { return true }
        try await Task.sleep(for: .milliseconds(10))
    }
    return false
}

@Test @MainActor func cachedStoresDoNotWaitForUncancellableProviderActors() async throws {
    let root = try snapshotRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let bookmark = Data("synthetic blocked provider grant".utf8)
    let policy = NetworkAccess(initialState: .unsatisfied)
    let cloud = ConversationCloudSync(network: policy)
    cloud.restore(enabled: true, bookmark: bookmark, base: nil)
    let skillData = Data(
        "---\nname: cached-skill\ndescription: Cached.\n---\nOffline instructions.".utf8)
    let skillCache = root.appendingPathComponent("SkillSnapshots")
    try SyncedResourceCache(root: skillCache).write(
        JSONEncoder().encode(SkillStore.Listing(documents: ["cached-skill": skillData])),
        name: "listing", bookmark: bookmark)
    try SyncedResourceCache(root: root.appendingPathComponent("CloudSnapshots")).write(
        SharedSettings(selectedSkill: "cached-skill").encoded(), name: "settings",
        bookmark: bookmark)
    let store = SkillStore(
        localRoot: root.appendingPathComponent("OffSkills"), network: policy, cacheRoot: skillCache)
    let gate = ProviderActorBlock()
    defer { gate.release() }
    let blocked = Task.detached { await store.holdProviderActor(gate) }
    try #require(await waitForSnapshotCondition { gate.entered.withLock { $0 } })
    let tools = ToolWorkspace(
        store: store, configuration: root.appendingPathComponent("servers.json"), network: policy)
    var prepared = false
    let preparation = Task {
        try await tools.prepare(using: cloud); prepared = true
    }
    let preparedBeforeRelease = try await waitForSnapshotCondition { prepared }
    gate.release()
    await blocked.value
    try await preparation.value
    #expect(preparedBeforeRelease && tools.selectedSkill?.name == "cached-skill")

    let state = root.appendingPathComponent("ActionState")
    let action = QuickAction(id: "cached", label: "Cached", order: 0, prompt: "Offline action")
    try SyncedResourceCache(root: state.appendingPathComponent("CloudSnapshots")).write(
        QuickActionConfiguration(actions: [action]).encoded(), name: "actions", bookmark: bookmark)
    let actionStore = QuickActionStore(
        localRoot: root.appendingPathComponent("OffActions"), stateRoot: state, network: policy)
    let actionGate = ProviderActorBlock()
    defer { actionGate.release() }
    let actionBlocked = Task.detached { await actionStore.holdProviderActor(actionGate) }
    try #require(await waitForSnapshotCondition { actionGate.entered.withLock { $0 } })
    let actions = QuickActionsModel(storage: actionStore)
    actions.reload(using: cloud)
    let loadedBeforeRelease = try await waitForSnapshotCondition {
        !actions.loading && actions.actions == [action]
    }
    actionGate.release()
    await actionBlocked.value
    await actions.waitUntilIdle()
    #expect(loadedBeforeRelease && actions.error == nil)
}

@Test func transientSkillReadErrorsRetainCacheButConfirmedChangesInvalidateIt() throws {
    let bytes = Data("---\nname: saved-skill\ndescription: Cached.\n---\nOriginal.".utf8)
    let original = try SkillDocument.decode(bytes, directoryName: "saved-skill")
    let previous = SkillStore.Listing(documents: ["saved-skill": bytes])
    var transient = SkillStore.Listing()
    let online = transient.record(
        .failure(CocoaError(.fileReadUnknown)), name: "saved-skill", previous: previous)
    #expect(online.document == nil && online.error != nil)
    #expect(try transient.entries().first?.document == original)
    var ioFailure = SkillStore.Listing()
    _ = ioFailure.record(
        .failure(SkillStore.readFailure(EIO)), name: "saved-skill", previous: previous)
    #expect(try ioFailure.entries().first?.document == original)
    for code in [ENOENT, ENOTDIR, ELOOP] {
        var invalidated = SkillStore.Listing()
        _ = invalidated.record(
            .failure(SkillStore.readFailure(code)), name: "saved-skill", previous: previous)
        #expect(try invalidated.entries().first?.document == nil)
    }
    for failure in [CocoaError(.fileReadNoSuchFile), CocoaError(.fileNoSuchFile)] {
        var deleted = SkillStore.Listing()
        _ = deleted.record(.failure(failure), name: "saved-skill", previous: previous)
        #expect(try deleted.entries().first?.document == nil && deleted.documents.isEmpty)
    }
    for text in [
        "Invalid changed instructions",
        "---\nname: [unterminated YAML\n---\nChanged instructions.",
        "---\nname: saved-skill\n---\nMissing required description.",
    ] {
        var malformed = SkillStore.Listing()
        _ = malformed.record(.success(Data(text.utf8)), name: "saved-skill", previous: previous)
        #expect(try malformed.entries().first?.document == nil && malformed.documents.isEmpty)
    }
    var changed = SkillStore.Listing()
    let replacement = Data(
        "---\nname: saved-skill\ndescription: Cached.\n---\nNew instructions.".utf8)
    _ = changed.record(.success(replacement), name: "saved-skill", previous: previous)
    #expect(try changed.entries().first?.document?.fingerprint != original.fingerprint)
    #expect(try SkillStore.Listing().entries().isEmpty)  // Removed directories are not retained.
}

@Test func corruptGeneratedSkillCacheCanBeRebuiltFromSuccessfulSourceReads() async throws {
    let root = try snapshotRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let bookmark = Data("synthetic corrupt cache grant".utf8)
    let cacheRoot = root.appendingPathComponent("Cache")
    let cache = SyncedResourceCache(root: cacheRoot)
    let store = SkillStore(
        localRoot: root.appendingPathComponent("OffSkills"), cacheRoot: cacheRoot)
    let malformed = Data("---\nname: [invalid YAML\n---\nChanged.".utf8)
    for data in [
        Data("invalid JSON".utf8),
        try JSONEncoder().encode(SkillStore.Listing(documents: ["saved-skill": malformed])),
    ] {
        try cache.write(data, name: "listing", bookmark: bookmark)
        #expect(try store.previousListingForRefresh(bookmark).documents.isEmpty)
        await #expect(throws: (any Error).self) { try await store.entries(.cachedCloud(bookmark)) }
        var fresh = SkillStore.Listing()
        let bytes = Data(
            "---\nname: saved-skill\ndescription: Fresh.\n---\nValid source data.".utf8)
        let result = fresh.record(
            .success(bytes), name: "saved-skill",
            previous: try store.previousListingForRefresh(bookmark))
        #expect(result.error == nil)
        try cache.write(JSONEncoder().encode(fresh), name: "listing", bookmark: bookmark)
        #expect(
            try await store.entries(.cachedCloud(bookmark)).first?.document?.instructions
                == "Valid source data.")
    }
}

@Test func confirmedResourceDeletionInvalidatesItsCachedCopyWithoutDiscardingOtherFiles()
    async throws
{
    let root = try snapshotRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let bookmark = Data("synthetic resource grant".utf8)
    let cacheRoot = root.appendingPathComponent("Cache")
    let cache = SyncedResourceCache(root: cacheRoot)
    let store = SkillStore(
        localRoot: root.appendingPathComponent("OffSkills"), cacheRoot: cacheRoot)
    let bytes = Data("---\nname: saved-skill\ndescription: Saved.\n---\nValid instructions.".utf8)
    let skill = try SkillDocument.decode(bytes, directoryName: "saved-skill")
    try cache.write(
        JSONEncoder().encode(SkillStore.Listing(documents: ["saved-skill": bytes])),
        name: "listing", bookmark: bookmark)
    for path in ["removed.txt", "retained.txt"] {
        try cache.write(
            Data(path.utf8), name: "resource:saved-skill:\(skill.fingerprint):\(path)",
            bookmark: bookmark)
    }
    try store.invalidateResource(
        "removed.txt", skill: skill, bookmark: bookmark, after: CocoaError(.fileReadUnknown))
    #expect(
        try await store.resource("removed.txt", skill: skill, source: .cachedCloud(bookmark))
            == "removed.txt")
    try store.invalidateResource(
        "removed.txt", skill: skill, bookmark: bookmark, after: CocoaError(.fileReadNoSuchFile))
    await #expect(throws: SyncedResourceFailure.self) {
        try await store.resource("removed.txt", skill: skill, source: .cachedCloud(bookmark))
    }
    #expect(
        try await store.resource("retained.txt", skill: skill, source: .cachedCloud(bookmark))
            == "retained.txt")
    try store.invalidateResource(
        "retained.txt", skill: skill, bookmark: bookmark, after: SkillFailure.unsupportedResource)
    await #expect(throws: SyncedResourceFailure.self) {
        try await store.resource("retained.txt", skill: skill, source: .cachedCloud(bookmark))
    }
}

@Test func resourceInstructionObservationsUpdateOrInvalidateFutureOfflineSkills() async throws {
    let root = try snapshotRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let bookmark = Data("synthetic instruction observation".utf8)
    let cacheRoot = root.appendingPathComponent("Cache")
    let store = SkillStore(
        localRoot: root.appendingPathComponent("OffSkills"), cacheRoot: cacheRoot)
    let oldBytes = Data("---\nname: saved-skill\ndescription: Saved.\n---\nOld instructions.".utf8)
    let old = try await store.observeSkill(
        .success(oldBytes), name: "saved-skill", bookmark: bookmark)
    let newBytes = Data(
        "---\nname: saved-skill\ndescription: Saved.\n---\nChanged instructions.".utf8)
    let changed = try await store.observeSkill(
        .success(newBytes), name: "saved-skill", bookmark: bookmark)
    #expect(old.fingerprint != changed.fingerprint)
    #expect(try await store.entries(.cachedCloud(bookmark)).first?.document == changed)
    await #expect(throws: SkillFailure.self) {
        try await store.resource("reference.txt", skill: old, source: .cachedCloud(bookmark))
    }
    let invalid = Data("---\nname: [invalid YAML\n---\nBroken replacement.".utf8)
    await #expect(throws: (any Error).self) {
        try await store.observeSkill(.success(invalid), name: "saved-skill", bookmark: bookmark)
    }
    #expect(try await store.entries(.cachedCloud(bookmark)).first?.document == nil)
    _ = try await store.observeSkill(.success(newBytes), name: "saved-skill", bookmark: bookmark)
    await #expect(throws: CocoaError.self) {
        try await store.observeSkill(
            .failure(CocoaError(.fileReadNoSuchFile)), name: "saved-skill", bookmark: bookmark)
    }
    #expect(try await store.entries(.cachedCloud(bookmark)).first?.document == nil)
}

@Test func confirmedSkillsDirectoryReplacementInvalidatesOnlyThatFolderSnapshot() async throws {
    let root = try snapshotRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SkillStore(
        localRoot: root.appendingPathComponent("OffSkills"),
        cacheRoot: root.appendingPathComponent("Cache"))
    let bookmark = Data("synthetic removed Skills directory".utf8)
    let other = Data("different folder".utf8)
    let bytes = Data("---\nname: saved-skill\ndescription: Saved.\n---\nValid instructions.".utf8)
    _ = try await store.observeSkill(.success(bytes), name: "saved-skill", bookmark: bookmark)
    _ = try await store.observeSkill(.success(bytes), name: "saved-skill", bookmark: other)
    try store.observeSkillsDirectoryFailure(EIO, bookmark: bookmark)
    #expect(try await store.entries(.cachedCloud(bookmark)).first?.document != nil)
    for code in [ENOENT, ENOTDIR, ELOOP] {
        _ = try await store.observeSkill(.success(bytes), name: "saved-skill", bookmark: bookmark)
        try store.observeSkillsDirectoryFailure(code, bookmark: bookmark)
        #expect(try await store.entries(.cachedCloud(bookmark)).isEmpty)
        #expect(try await store.entries(.cachedCloud(other)).first?.document != nil)
    }
}
