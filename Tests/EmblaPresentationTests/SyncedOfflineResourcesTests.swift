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
    policy.updatePath(.satisfied)
    policy.activateRequests(after: policy.snapshot.revision)
    cloud.connectivityChanged()
    await restarted.reloadSettings(using: cloud)
    #expect(factoryCalls.withLock { $0 } == 1 && provider.reads.withLock { $0 } == 2)
    // The shared preference still selects the original skill, not the session-only None.
    #expect(provider.document.selectedSkill == "saved-skill")
    policy.updatePath(.unsatisfied)
    cloud.restore(enabled: true, bookmark: Data("different authorized folder".utf8), base: nil)
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
