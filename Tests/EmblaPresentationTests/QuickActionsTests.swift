import Foundation
import Testing

@testable import EmblaPresentation

@Test func actionConfigurationValidatesOrderingIDsAndUnsupportedData() throws {
    let config = QuickActionConfiguration(actions: [
        QuickAction(id: "later", label: "Later", order: 20, prompt: "Later prompt"),
        QuickAction(
            id: "hidden", label: "Hidden", order: 0, enabled: false, prompt: "Hidden prompt"),
        QuickAction(id: "first", label: "First", order: 10, prompt: "  Exact prompt\n"),
        QuickAction(id: "skill", label: "Skill", order: 30, type: .skill, skill: "my-skill"),
    ])
    let decoded = try QuickActionConfiguration.decode(config.encoded())
    #expect(decoded.visibleActions.map(\.id) == ["first", "later", "skill"])
    #expect(decoded.visibleActions.first?.prompt == "  Exact prompt\n")
    let duplicate = QuickActionConfiguration(actions: [config.actions[0], config.actions[0]])
    #expect(throws: QuickActionError.self) { try duplicate.validate() }
    var newer = config
    newer.formatVersion = 2
    #expect(throws: QuickActionError.self) { try newer.validate() }
    let missing = QuickActionConfiguration(actions: [
        QuickAction(id: "no-prompt", label: "No prompt", order: 0)
    ])
    #expect(throws: QuickActionError.self) { try missing.validate() }
    let bad = Data(
        "{\"formatVersion\":1,\"actions\":[{\"id\":\"x\",\"label\":\"X\",\"order\":0,\"enabled\":true,\"type\":\"unknown\"}]}"
            .utf8)
    #expect(throws: QuickActionError.self) { try QuickActionConfiguration.decode(bad) }
}

@Test func deviceActionsAreEditableAndMissingOrCorruptFilesNeverBecomeDefaults() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let local = root.appendingPathComponent("Documents/Actions")
    let state = root.appendingPathComponent("PrivateState")
    let store = QuickActionStore(localRoot: local, stateRoot: state)
    #expect(try await store.read(.device) == .starter)
    #expect(
        try local.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    let file = local.appendingPathComponent("actions.json")
    let edited = QuickActionConfiguration(actions: [
        QuickAction(id: "custom", label: "My copied action", order: 1, prompt: "Copied prompt")
    ])
    try edited.encoded().write(to: file, options: .atomic)
    #expect(try await store.read(.device) == edited)
    let invalid = Data("User's invalid configuration".utf8)
    try invalid.write(to: file)
    await #expect(throws: QuickActionError.self) { try await store.read(.device) }
    await #expect(throws: QuickActionError.self) { try await store.createStarter(.device) }
    #expect(try Data(contentsOf: file) == invalid)
    try FileManager.default.removeItem(at: file)
    await #expect(throws: QuickActionError.self) { try await store.read(.device) }
    #expect(!FileManager.default.fileExists(atPath: file.path))
    try await store.createStarter(.device)
    #expect(try await store.read(.device) == .starter)
}

@Test func preexistingInvalidConfigurationIsNotOverwrittenDuringFirstInitialization() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let local = root.appendingPathComponent("Actions")
    try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
    let file = local.appendingPathComponent("actions.json")
    let invalid = Data("Preserve my file".utf8)
    try invalid.write(to: file)
    let store = QuickActionStore(localRoot: local, stateRoot: root.appendingPathComponent("State"))
    await #expect(throws: QuickActionError.self) { try await store.read(.device) }
    #expect(try Data(contentsOf: file) == invalid)
}

/// Explicit test fixtures; the application's public constructors never select these providers.
private actor ActionsFixture: QuickActionsStoring {
    var local = QuickActionConfiguration(actions: [
        QuickAction(id: "local", label: "Local", order: 0, prompt: "Local prompt")
    ])
    var remote = QuickActionConfiguration(actions: [
        QuickAction(id: "remote", label: "Remote", order: 0, prompt: "Remote prompt")
    ])
    var deviceReads = 0
    var cloudReads = 0
    let failCloud: Bool
    var holdCloud: Bool
    private var gate: CheckedContinuation<Void, Never>?

    init(failCloud: Bool = false, holdCloud: Bool = false) {
        self.failCloud = failCloud
        self.holdCloud = holdCloud
    }
    func read(_ source: QuickActionSource) async throws -> QuickActionConfiguration {
        switch source {
        case .device:
            deviceReads += 1
            return local
        case .cloud:
            cloudReads += 1
            if holdCloud { await withCheckedContinuation { gate = $0 } }
            if failCloud { throw CocoaError(.fileReadNoPermission) }
            return remote  // Deliberately ignores cancellation to exercise stale-result rejection.
        }
    }
    func createStarter(_ source: QuickActionSource) async throws {}
    func releaseCloud() {
        holdCloud = false
        gate?.resume()
        gate = nil
    }
    func changeLocal(_ config: QuickActionConfiguration) { local = config }
    func waitForReads(cloud: Bool) async throws {
        for _ in 0..<1_000 {
            if cloud ? cloudReads > 0 : deviceReads > 0 { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw QuickActionError.changed
    }
}

private actor ActionsCloudFixture: CloudConversationStorage {
    func read() async throws -> CloudConversationRead { .init() }
    func write(
        _ snapshot: ConversationLibrary, replacing: CloudConversationRead,
        resolvingConflicts: Bool
    ) async throws {}
}

private actor ActionConsentGate {
    private var started = false
    private var gate: CheckedContinuation<Void, Never>?
    func wait() async {
        started = true
        await withCheckedContinuation { gate = $0 }
    }
    func release() {
        gate?.resume()
        gate = nil
    }
    func waitForStart() async throws {
        for _ in 0..<1_000 {
            if started { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw QuickActionError.changed
    }
}

@Test @MainActor
func cloudOffUsesOnlyDeviceActionsEvenWithAStoredBookmark() async throws {
    let provider = ActionsFixture()
    let model = QuickActionsModel(storage: provider)
    let cloud = ConversationCloudSync(factory: { _ in ActionsCloudFixture() })
    cloud.restore(enabled: false, bookmark: Data("old grant".utf8), base: nil)
    model.reload(using: cloud)
    await model.waitUntilIdle()
    #expect(model.actions.first?.id == "local" && model.error == nil)
    #expect(await provider.deviceReads == 1)
    #expect(await provider.cloudReads == 0)
}

@Test @MainActor
func actionsWaitForDurableConsentAndNeverUseLocalDataOnCloudFailure() async throws {
    let provider = ActionsFixture(failCloud: true)
    let model = QuickActionsModel(storage: provider)
    let cloud = ConversationCloudSync(factory: { _ in ActionsCloudFixture() })
    let gate = ActionConsentGate()
    cloud.persist = { await gate.wait() }
    let enabling = Task { try await cloud.enable(bookmark: Data("fixture grant".utf8)) }
    try await gate.waitForStart()
    model.reload(using: cloud)
    await model.waitUntilIdle()
    #expect(!cloud.folderAccessReady && model.actions.isEmpty && model.error != nil)
    #expect(await provider.cloudReads == 0)
    #expect(await provider.deviceReads == 0)
    await gate.release()
    try await enabling.value
    model.reload(using: cloud)
    await model.waitUntilIdle()
    #expect(cloud.folderAccessReady && model.actions.isEmpty && model.error != nil)
    #expect(await provider.cloudReads == 1)
    #expect(await provider.deviceReads == 0)
    cloud.persist = {}
    cloud.disable()
    await cloud.waitUntilIdle()
}

@Test @MainActor
func switchingCloudOffRejectsLateRemoteActions() async throws {
    let provider = ActionsFixture(holdCloud: true)
    let model = QuickActionsModel(storage: provider)
    let cloud = ConversationCloudSync(factory: { _ in ActionsCloudFixture() })
    cloud.restore(enabled: true, bookmark: Data("fixture grant".utf8), base: nil)
    model.reload(using: cloud)
    try await provider.waitForReads(cloud: true)
    cloud.persist = {}
    cloud.disable()
    model.reload(using: cloud)
    try await provider.waitForReads(cloud: false)
    await provider.releaseCloud()
    await model.waitUntilIdle()
    await cloud.waitUntilIdle()
    #expect(model.actions.first?.id == "local" && model.error == nil)
    #expect(model.loadedSourceKey == QuickActionsModel.sourceKey(for: cloud))
}

@Test @MainActor
func changedSelectionsAndSkillActionsNeverProduceAReplacementPrompt() async throws {
    let provider = ActionsFixture()
    let model = QuickActionsModel(storage: provider)
    let cloud = ConversationCloudSync()
    model.reload(using: cloud)
    await model.waitUntilIdle()
    let selected = try #require(model.actions.first)
    #expect(try model.prompt(for: selected, using: cloud) == "Local prompt")
    let skill = QuickAction(id: "skill", label: "Skill", order: 0, type: .skill, skill: "my-skill")
    await provider.changeLocal(QuickActionConfiguration(actions: [skill]))
    model.reload(using: cloud)
    await model.waitUntilIdle()
    #expect(throws: QuickActionError.self) { try model.prompt(for: selected, using: cloud) }
    #expect(throws: QuickActionError.self) { try model.prompt(for: skill, using: cloud) }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func changedSourceCompletesTheOldLoadWithoutPublishingStaleCards() async throws {
    let provider = ActionsFixture(holdCloud: true)
    let model = QuickActionsModel(storage: provider)
    let cloud = ConversationCloudSync(factory: { _ in ActionsCloudFixture() })
    cloud.restore(enabled: true, bookmark: Data("fixture grant".utf8), base: nil)
    model.reload(using: cloud)
    try await provider.waitForReads(cloud: true)
    cloud.persist = {}
    cloud.disable()
    await provider.releaseCloud()
    await model.waitUntilIdle()
    await cloud.waitUntilIdle()
    #expect(!model.loading && model.actions.isEmpty && model.loadedSourceKey == nil)
    model.reload(using: cloud)
    await model.waitUntilIdle()
    #expect(model.actions.first?.id == "local")
}
