import CryptoKit
import Foundation
import Testing

@testable import EmblaCore
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

@Test func replacedLocalActionsDirectoryIsExcludedFromBackupOnReload() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let local = root.appendingPathComponent("Actions")
    let store = QuickActionStore(localRoot: local, stateRoot: root.appendingPathComponent("State"))
    _ = try await store.read(.device)
    try FileManager.default.removeItem(at: local)
    try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
    var replacement = local
    var values = URLResourceValues()
    values.isExcludedFromBackup = false
    try replacement.setResourceValues(values)
    let file = local.appendingPathComponent("actions.json")
    try QuickActionConfiguration.starter.encoded().write(to: file)
    #expect(try await store.read(.device) == .starter)
    #expect(
        try local.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    try FileManager.default.removeItem(at: file)
    await #expect(throws: QuickActionError.self) { try await store.read(.device) }
    #expect(!FileManager.default.fileExists(atPath: file.path))
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

@Test func immediateActionFlagIsBackwardCompatibleAndRequiresAConfiguredPrompt() throws {
    let legacy = """
        {"formatVersion":1,"actions":[{"id":"old","label":"Old","order":0,
        "enabled":true,"type":"prompt","prompt":"Legacy prompt"}]}
        """
    #expect(try QuickActionConfiguration.decode(Data(legacy.utf8)).actions[0].autoSend == false)
    for value in ["\"true\"", "null", "1"] {
        let bad = legacy.replacingOccurrences(
            of: "\"prompt\":\"Legacy prompt\"",
            with: "\"prompt\":\"Legacy prompt\",\"autoSend\":\(value)")
        #expect(throws: QuickActionError.self) {
            try QuickActionConfiguration.decode(Data(bad.utf8))
        }
    }
    for action in [
        QuickAction(id: "blank", label: "Blank", order: 0, prompt: " \n", autoSend: true),
        QuickAction(
            id: "skill", label: "Skill", order: 0, type: .skill,
            skill: "example-skill", autoSend: true),
    ] {
        #expect(throws: QuickActionError.self) {
            try QuickActionConfiguration(actions: [action]).validate()
        }
    }
}

/// Only the unit-test initializer supplies this backend; app constructors always use Embla Metal.
private final class ActionSubmissionBackend: InferenceBackend, @unchecked Sendable {
    let contextSize = 8_192
    private let lock = NSLock()
    private var count = 0
    private var contexts: [[ConversationMessage]] = []
    let hold: Bool
    var calls: Int { lock.withLock { count } }
    var encoded: [[ConversationMessage]] { lock.withLock { contexts } }
    init(hold: Bool) { self.hold = hold }
    func reset() {}
    func encode(_ messages: [ConversationMessage]) throws -> [Int] {
        lock.withLock { contexts.append(messages) }
        return [1]
    }
    func generate(
        prompt: [Int], options: GenerationOptions,
        emit: @escaping @Sendable (GenerationDelta) -> Bool
    ) throws -> GenerationMetrics {
        lock.withLock { count += 1 }
        if hold {
            while emit(.reasoning("Synthetic action wait")) { Thread.sleep(forTimeInterval: 0.01) }
        } else {
            _ = emit(.answer("Synthetic action answer"))
        }
        return GenerationMetrics(
            finishReason: "stop", promptTokens: 1, completionTokens: 1,
            promptMilliseconds: 1, decodeMilliseconds: 1)
    }
}

private actor ActionFailingStore: ConversationStoring {
    func load() -> ConversationArchive? { nil }
    func save(_ archive: ConversationArchive) throws { throw CocoaError(.fileWriteOutOfSpace) }
}

@MainActor private struct ActionSubmissionFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let data = Data("Synthetic action model fixture".utf8)
    let manifest: ModelManifest
    let backend: ActionSubmissionBackend
    let model: LocalInferenceModel
    let store: ConversationStore

    init(ready: Bool = true, hold: Bool = false, failStorage: Bool = false) async throws {
        manifest = ModelManifest(
            repository: "test/actions", revision: "fixture",
            files: [
                .init(
                    path: "config.json", sizeBytes: Int64(data.count),
                    sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
            ])
        let skill = root.appendingPathComponent("Skills/example-skill")
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try Data(
            "---\nname: example-skill\ndescription: Synthetic action skill\n---\nSKILL_FIXTURE_INSTRUCTIONS"
                .utf8
        )
        .write(to: skill.appendingPathComponent("SKILL.md"))
        backend = ActionSubmissionBackend(hold: hold)
        let backend = backend
        store = ConversationStore(root: root.appendingPathComponent("Chats"))
        model = LocalInferenceModel(
            repository: ModelRepository(
                root: root.appendingPathComponent("Model"), manifest: manifest),
            manifest: manifest, session: InferenceSession { _, _ in backend },
            chatStore: failStorage ? ActionFailingStore() : store,
            tools: ToolWorkspace(
                store: SkillStore(localRoot: root.appendingPathComponent("Skills")),
                configuration: root.appendingPathComponent("servers.json")))
        if ready { try install() }
        model.check(); await model.waitUntilIdle()
        model.tools.reloadSkills(using: model.cloud); await model.tools.waitUntilIdle()
    }

    func install() throws {
        let directory = root.appendingPathComponent("Model/fixture")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("config.json"))
    }

    func finish() async {
        model.enteredBackground()
        await model.waitUntilIdle()
        await model.waitForScheduledPersistence()
    }

    func clean() { model.stop(); try? FileManager.default.removeItem(at: root) }
}

@MainActor private func loadedActionModel(_ action: QuickAction, cloud: ConversationCloudSync) async
    -> QuickActionsModel
{
    let storage = ActionsFixture()
    await storage.changeLocal(QuickActionConfiguration(actions: [action]))
    let actions = QuickActionsModel(storage: storage)
    actions.reload(using: cloud)
    await actions.waitUntilIdle()
    return actions
}

@Test @MainActor func actionReplacementConsentTracksTheExactChatAndDraft() async throws {
    let fixture = try await ActionSubmissionFixture(ready: false)
    defer { fixture.clean() }
    let action = QuickAction(id: "draft", label: "Draft", order: 0, prompt: "Configured prompt")
    let actions = await loadedActionModel(action, cloud: fixture.model.cloud)
    let chatID = fixture.model.conversationID
    fixture.model.prompt = "Original unsent draft"
    guard case .needsConfirmation(let consent) = try await actions.apply(action, to: fixture.model)
    else { Issue.record("Replacing a draft must require consent"); return }
    #expect(fixture.model.prompt == "Original unsent draft" && fixture.model.messages.isEmpty)
    #expect(fixture.backend.calls == 0)  // Cancel is simply not applying the confirmation.
    fixture.model.prompt = "A newer unsent draft"
    await #expect(throws: QuickActionError.self) {
        try await actions.apply(action, to: fixture.model, replacing: consent)
    }
    #expect(fixture.model.prompt == "A newer unsent draft")
    guard case .needsConfirmation(let fresh) = try await actions.apply(action, to: fixture.model)
    else { Issue.record("A fresh draft needs fresh consent"); return }
    #expect(try await actions.apply(action, to: fixture.model, replacing: fresh) == .applied)
    #expect(fixture.model.prompt == "Configured prompt")
    #expect(fixture.model.conversationID == chatID && fixture.model.messages.isEmpty)
    await fixture.model.waitForScheduledPersistence()
    #expect(try await fixture.store.load()?.draft == "Configured prompt")
    fixture.model.newChat(); await fixture.model.waitUntilIdle()
    fixture.model.prompt = "Another chat's draft"
    await #expect(throws: QuickActionError.self) {
        try await actions.apply(action, to: fixture.model, replacing: fresh)
    }
    #expect(fixture.model.prompt == "Another chat's draft")
    await fixture.finish()
}

@Test @MainActor func immediateActionUsesNormalSendOnlyAfterConsentAndRejectsDuplicateTaps()
    async throws
{
    let fixture = try await ActionSubmissionFixture(hold: true)
    defer { fixture.clean() }
    let action = QuickAction(
        id: "send", label: "Send", order: 0,
        prompt: "Explicit configured prompt", autoSend: true)
    let actions = await loadedActionModel(action, cloud: fixture.model.cloud)
    fixture.model.prompt = "Private unsent draft"
    let chatID = fixture.model.conversationID
    guard case .needsConfirmation(let consent) = try await actions.apply(action, to: fixture.model)
    else { Issue.record("Immediate replacement must ask before sending"); return }
    #expect(fixture.model.messages.isEmpty && fixture.backend.calls == 0)
    #expect(fixture.model.prompt == "Private unsent draft")
    #expect(try await actions.apply(action, to: fixture.model, replacing: consent) == .applied)
    await #expect(throws: QuickActionError.self) {
        try await actions.apply(action, to: fixture.model)
    }
    for _ in 0..<1_000 {
        if fixture.backend.calls > 0 { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(fixture.backend.calls == 1 && fixture.model.conversationID == chatID)
    #expect(
        fixture.model.messages.filter { $0.role == .user }.map(\.text)
            == ["Explicit configured prompt"])
    fixture.model.stop(); await fixture.model.waitUntilIdle()
    #expect(
        try await fixture.store.load()?.snapshot.messages.filter { $0.role == .user }.count == 1)
    await fixture.finish()
}

@Test @MainActor func unavailableImmediateActionPreservesDraftAndNeverQueuesALaterSend()
    async throws
{
    let fixture = try await ActionSubmissionFixture(ready: false)
    defer { fixture.clean() }
    let action = QuickAction(
        id: "instant", label: "Instant", order: 0,
        prompt: "Configured send", autoSend: true)
    let actions = await loadedActionModel(action, cloud: fixture.model.cloud)
    fixture.model.prompt = "Keep this exact draft"
    await #expect(throws: QuickActionError.self) {
        try await actions.apply(action, to: fixture.model)
    }
    #expect(fixture.model.prompt == "Keep this exact draft" && fixture.model.messages.isEmpty)
    try fixture.install()
    fixture.model.check(); await fixture.model.waitUntilIdle()
    #expect(fixture.model.readyDirectory != nil && fixture.backend.calls == 0)
    #expect(fixture.model.prompt == "Keep this exact draft")
    await fixture.finish()
}

@Test @MainActor func skillActionsValidateBeforeDraftMutationAndCanSubmitExplicitPrompts()
    async throws
{
    let fixture = try await ActionSubmissionFixture()
    defer { fixture.clean() }
    let missing = QuickAction(
        id: "missing", label: "Missing", order: 0, type: .skill,
        prompt: "Configured skill prompt", skill: "missing-skill", autoSend: true)
    let failed = await loadedActionModel(missing, cloud: fixture.model.cloud)
    await #expect(throws: SkillFailure.self) { try await failed.apply(missing, to: fixture.model) }
    #expect(fixture.model.prompt.isEmpty && fixture.model.messages.isEmpty)
    let valid = QuickAction(
        id: "valid", label: "Valid", order: 0, type: .skill,
        prompt: "Explicit skill prompt", skill: "example-skill", autoSend: true)
    let actions = await loadedActionModel(valid, cloud: fixture.model.cloud)
    #expect(try await actions.apply(valid, to: fixture.model) == .applied)
    await fixture.model.waitUntilIdle()
    #expect(fixture.model.error == nil && fixture.backend.calls == 1)
    #expect(fixture.model.tools.selectedSkill?.name == "example-skill")
    #expect(
        fixture.backend.encoded.flatMap { $0 }.contains {
            $0.content.contains("SKILL_FIXTURE_INSTRUCTIONS")
        })
    await fixture.finish()
}

@Test @MainActor func storageFailuresBlockActionsBeforeReplacingOrSendingADraft() async throws {
    let fixture = try await ActionSubmissionFixture(failStorage: true)
    defer { fixture.clean() }
    let action = QuickAction(
        id: "blocked", label: "Blocked", order: 0,
        prompt: "Blocked prompt", autoSend: true)
    let actions = await loadedActionModel(action, cloud: fixture.model.cloud)
    fixture.model.prompt = "Draft survives storage error"
    await fixture.model.waitForScheduledPersistence()
    try #require(fixture.model.storageError != nil)
    await #expect(throws: QuickActionError.self) {
        try await actions.apply(action, to: fixture.model)
    }
    #expect(fixture.model.prompt == "Draft survives storage error")
    #expect(fixture.backend.calls == 0 && fixture.model.messages.isEmpty)
    await fixture.finish()
}

@Test @MainActor func changedOrCancelledActionsNeverMutateTheDraftOrSubmit() async throws {
    let fixture = try await ActionSubmissionFixture()
    defer { fixture.clean() }
    let action = QuickAction(
        id: "instant", label: "Instant", order: 0, prompt: "Configured send", autoSend: true)
    let storage = ActionsFixture()
    await storage.changeLocal(QuickActionConfiguration(actions: [action]))
    let actions = QuickActionsModel(storage: storage)
    actions.reload(using: fixture.model.cloud); await actions.waitUntilIdle()
    fixture.model.prompt = "Unchanged draft"
    guard case .needsConfirmation(let consent) = try await actions.apply(action, to: fixture.model)
    else { Issue.record("Expected draft replacement confirmation"); return }
    await storage.changeLocal(QuickActionConfiguration(actions: []))
    actions.reload(using: fixture.model.cloud); await actions.waitUntilIdle()
    await #expect(throws: QuickActionError.self) {
        try await actions.apply(action, to: fixture.model, replacing: consent)
    }
    await storage.changeLocal(QuickActionConfiguration(actions: [action]))
    actions.reload(using: fixture.model.cloud); await actions.waitUntilIdle()
    let pending = Task { @MainActor in
        withUnsafeCurrentTask { $0?.cancel() }
        return try await actions.apply(action, to: fixture.model, replacing: consent)
    }
    await #expect(throws: CancellationError.self) { try await pending.value }
    #expect(fixture.model.prompt == "Unchanged draft" && fixture.model.messages.isEmpty)
    #expect(fixture.backend.calls == 0 && !actions.applying)
    await fixture.finish()
}

@Test @MainActor func replacementConsentCannotSurviveAnInterveningTurnWithTheSameDraft()
    async throws
{
    let fixture = try await ActionSubmissionFixture()
    defer { fixture.clean() }
    let action = QuickAction(
        id: "instant", label: "Instant", order: 0, prompt: "Configured send", autoSend: true)
    let actions = await loadedActionModel(action, cloud: fixture.model.cloud)
    fixture.model.prompt = "Original draft"
    guard case .needsConfirmation(let consent) = try await actions.apply(action, to: fixture.model)
    else { Issue.record("Expected replacement confirmation"); return }
    fixture.model.run(); await fixture.model.waitUntilIdle()
    fixture.model.prompt = "Original draft"
    await #expect(throws: QuickActionError.self) {
        try await actions.apply(action, to: fixture.model, replacing: consent)
    }
    await fixture.model.waitUntilIdle()
    #expect(fixture.backend.calls == 1)
    #expect(fixture.model.prompt == "Original draft")
    #expect(fixture.model.messages.filter { $0.role == .user }.map(\.text) == ["Original draft"])
    await fixture.finish()
}

@Test @MainActor func editedMessagesWithUnchangedIDsInvalidateReplacementConsent() async throws {
    let fixture = try await ActionSubmissionFixture()
    defer { fixture.clean() }
    fixture.model.prompt = "Original turn"
    fixture.model.run(); await fixture.model.waitUntilIdle()
    let action = QuickAction(
        id: "instant", label: "Instant", order: 0, prompt: "Configured send", autoSend: true)
    let actions = await loadedActionModel(action, cloud: fixture.model.cloud)
    fixture.model.prompt = "Private draft"
    guard case .needsConfirmation(let consent) = try await actions.apply(action, to: fixture.model)
    else { Issue.record("Expected replacement confirmation"); return }
    let original = try #require(fixture.model.cloud.current?()?.snapshot)
    let restore = try #require(fixture.model.cloud.apply)
    var edited = original
    let index = try #require(
        edited.chats.firstIndex {
            $0.conversationID == fixture.model.conversationID
        })
    edited.chats[index].messages[0].text = "Edited text retaining the same message ID"
    try await restore(edited, original.fingerprint())
    fixture.model.prompt = "Private draft"
    #expect(fixture.model.messages.map(\.id) == consent.messages.map(\.id))
    #expect(fixture.model.messages != consent.messages)
    await #expect(throws: QuickActionError.self) {
        try await actions.apply(action, to: fixture.model, replacing: consent)
    }
    await fixture.model.waitUntilIdle()
    #expect(fixture.model.prompt == "Private draft" && fixture.backend.calls == 1)
    #expect(fixture.model.messages[0].text == "Edited text retaining the same message ID")
    await fixture.finish()
}

@Test(arguments: [QuickAction.Kind.prompt, .skill], [false, true]) @MainActor
func staleSkillFilesFailImmediateActionsBeforeDraftReplacement(
    kind: QuickAction.Kind, invalid: Bool
) async throws {
    let fixture = try await ActionSubmissionFixture()
    defer { fixture.clean() }
    if kind == .prompt {
        try await fixture.model.tools.selectSkill("example-skill", using: fixture.model.cloud)
    }
    let action = QuickAction(
        id: "instant", label: "Instant", order: 0, type: kind, prompt: "Configured send",
        skill: kind == .skill ? "example-skill" : nil, autoSend: true)
    let actions = await loadedActionModel(action, cloud: fixture.model.cloud)
    fixture.model.prompt = "Private draft"
    guard case .needsConfirmation(let consent) = try await actions.apply(action, to: fixture.model)
    else { Issue.record("Expected replacement confirmation"); return }
    let file = fixture.root.appendingPathComponent("Skills/example-skill/SKILL.md")
    if invalid {
        try Data("Invalid skill without required frontmatter".utf8).write(to: file)
    } else {
        try FileManager.default.removeItem(at: file)
    }
    await #expect(throws: SkillFailure.self) {
        try await actions.apply(action, to: fixture.model, replacing: consent)
    }
    await fixture.model.waitUntilIdle()
    #expect(fixture.model.prompt == "Private draft" && fixture.model.messages.isEmpty)
    #expect(fixture.backend.calls == 0)
    await fixture.finish()
}
