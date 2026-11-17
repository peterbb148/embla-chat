import Foundation
import Testing

import EmblaCore
@testable import EmblaPresentation

private struct SettingsFileFixture: SharedSettingsStoring {
    let file: URL
    var identity: String { file.path }
    func read() throws -> SharedSettingsRead { try CoordinatedSettingsFile.read(file) }
    func write(
        _ value: SharedSettings, replacing: SharedSettingsRead, resolve: Bool,
        access: SettingsAccessLease
    ) throws {
        try CoordinatedSettingsFile.write(
            value, at: file, replacing: replacing, resolve: resolve, access: access)
    }
}

private final class SettingsCredentialFixture: MCPCredentialStoring, @unchecked Sendable {
    var token: String? = "synthetic-key"
    func read(_ id: MCPCredentialID) -> String? { token }
    func write(_ value: String, id: MCPCredentialID) { token = value }
    func deleteEndpoint(_ id: MCPCredentialID) { token = nil }
    func deleteAll(_ id: UUID) { token = nil }
}

private func settingsRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func settingsDocument(_ name: String = "Synthetic server") -> SharedSettings {
    let server = MCPServer(
        name: name, endpoint: URL(string: "https://example.invalid/mcp")!,
        enabledTools: ["search"], enableToolsOnFirstDiscovery: false)
    return SharedSettings(servers: [SharedServer(server, token: "synthetic-test-key")])
}

@Test func sharedSettingsValidateEndpointBoundKeysAndCanonicalPermissions() throws {
    var doc = settingsDocument()
    let data = try doc.encoded()
    #expect(try JSONDecoder().decode(SharedSettings.self, from: data) == doc)
    #expect(!String(decoding: data, as: UTF8.self).contains("lastDiscoveredTools"))
    doc.servers[0].endpoint = URL(string: "https://other.invalid/mcp")!
    #expect(throws: SharedSettingsError.self) { try doc.encoded() }
    doc = settingsDocument()
    doc.servers[0].credential?.bearerToken = "invalid\nheader"
    #expect(throws: SharedSettingsError.self) { try doc.encoded() }
    doc = settingsDocument()
    doc.servers.append(doc.servers[0])
    #expect(throws: SharedSettingsError.self) { try doc.encoded() }
    doc = settingsDocument()
    doc.formatVersion = 99
    #expect(throws: SharedSettingsError.self) { try doc.encoded() }
}

@Test @MainActor func sharedSettingsMigrationAndSecondInstallationRetainCredentialsAndPermissions()
    async throws
{
    let root = try settingsRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SettingsFileFixture(file: root.appendingPathComponent("settings.json"))
    let first = SharedSettingsSession(
        storage: store, receipt: root.appendingPathComponent("first.json"))
    var original = settingsDocument()
    original.selectedSkill = "concise-writing"
    #expect(try await first.refresh(local: original) == original)
    let second = SharedSettingsSession(
        storage: store, receipt: root.appendingPathComponent("second.json"))
    #expect(try await second.refresh(local: SharedSettings()) == original)
    var changed = original
    changed.servers[0].credential?.bearerToken = "replacement-synthetic-key"
    changed.servers[0].enabledTools = []
    try await first.commit(changed, replacing: await first.current!)
    #expect(try await second.refresh(local: SharedSettings()) == changed)
    changed.servers = []
    try await second.commit(changed, replacing: await second.current!)
    #expect(try await first.refresh(local: original) == changed)
    let receipt = try String(contentsOf: first.receipt, encoding: .utf8)
    #expect(!receipt.contains("synthetic-key") && !receipt.contains("bearerToken"))
}

@Test @MainActor func concurrentSettingsWritesAndMigrationNeverSilentlyOverwrite() async throws {
    let root = try settingsRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SettingsFileFixture(file: root.appendingPathComponent("settings.json"))
    let first = SharedSettingsSession(
        storage: store, receipt: root.appendingPathComponent("first.json"))
    let second = SharedSettingsSession(
        storage: store, receipt: root.appendingPathComponent("second.json"))
    let original = settingsDocument()
    _ = try await first.refresh(local: original)
    _ = try await second.refresh(local: SharedSettings())
    var changed = original
    changed.servers[0].name = "First edit"
    try await first.commit(changed, replacing: await first.current!)
    var stale = original
    stale.servers[0].name = "Stale edit"
    await #expect(throws: SharedSettingsError.self) {
        try await second.commit(stale, replacing: await second.current!)
    }
    #expect(try store.read().current == changed)
    let migration = SharedSettingsSession(
        storage: store, receipt: root.appendingPathComponent("third.json"))
    let different = settingsDocument("Unmigrated device")
    await #expect(throws: SharedSettingsError.self) {
        try await migration.refresh(local: different)
    }
    #expect(await migration.choices == [different, changed])
    #expect(try await migration.resolve(1, expected: await migration.choices[1]) == changed)
    #expect(try await migration.refresh(local: different) == changed)
    // An Off-profile edit is not ignored on re-enable.
    var editedOff = different
    editedOff.servers[0].name = "Changed while Off"
    await #expect(throws: SharedSettingsError.self) {
        try await migration.refresh(local: editedOff)
    }
    #expect(await migration.choices.first == editedOff)
}

@Test @MainActor func deletedOrInvalidSharedSettingsRequireAnExplicitDecision() async throws {
    let root = try settingsRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SettingsFileFixture(file: root.appendingPathComponent("settings.json"))
    let session = SharedSettingsSession(
        storage: store, receipt: root.appendingPathComponent("receipt.json"))
    let original = settingsDocument()
    _ = try await session.refresh(local: original)
    try FileManager.default.removeItem(at: store.file)
    await #expect(throws: SharedSettingsError.self) { try await session.refresh(local: original) }
    #expect(!FileManager.default.fileExists(atPath: store.file.path))
    #expect(try await session.resolve(1, expected: await session.choices[1]).servers.isEmpty)
    try Data("broken JSON".utf8).write(to: store.file)
    await #expect(throws: (any Error).self) { try await session.refresh(local: original) }
    #expect(try Data(contentsOf: store.file) == Data("broken JSON".utf8))
}

@Test @MainActor func workspaceFollowsCloudScopeAndNeverUsesDeviceKeysForSharedServers()
    async throws
{
    let root = try settingsRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let localFile = root.appendingPathComponent("servers.json")
    let sharedFile = SettingsFileFixture(file: root.appendingPathComponent("settings.json"))
    let vault = SettingsCredentialFixture()
    let workspace = ToolWorkspace(
        configuration: localFile, credentials: vault,
        settingsFactory: { _ in sharedFile })
    let local = MCPServer(name: "Local", endpoint: URL(string: "https://example.invalid/local")!)
    try await workspace.saveServer(local)
    let cloud = ConversationCloudSync(network: .init(initialState: .satisfied))
    await workspace.reloadSettings(using: cloud)
    #expect(!FileManager.default.fileExists(atPath: sharedFile.file.path))
    cloud.restore(enabled: true, bookmark: Data("synthetic grant".utf8), base: nil)
    // The source guard blocks operations until the selected profile is loaded.
    await #expect(throws: SharedSettingsError.self) { try await workspace.saveServer(local) }
    await workspace.reloadSettings(using: cloud)
    #expect(workspace.settingsError == nil)
    #expect(
        try sharedFile.read().current?.servers.first?.credential?.bearerToken == "synthetic-key")
    try await workspace.clearCredential(local.id)
    #expect(try workspace.token(for: local) == nil)  // no fallback to device Keychain
    #expect(vault.token == "synthetic-key")
    cloud.restore(enabled: false, bookmark: nil, base: nil)
    await workspace.reloadSettings(using: cloud)
    #expect(workspace.servers == [local])
    #expect(try workspace.token(for: local) == "synthetic-key")
    // Corrupt cloud files must not be touched/read with the switch Off.
    try Data("bad JSON".utf8).write(to: sharedFile.file)
    await workspace.reloadSettings(using: cloud)
    #expect(workspace.settingsError == nil)
    cloud.restore(
        enabled: true, bookmark: Data("synthetic grant".utf8), base: nil, consentVersion: 1)
    await workspace.reloadSettings(using: cloud)
    #expect(workspace.settingsError != nil && workspace.servers.isEmpty)
    #expect(try Data(contentsOf: sharedFile.file) == Data("bad JSON".utf8))
}

private final class FailingSettingsFixture: SharedSettingsStoring, @unchecked Sendable {
    var identity = "synthetic failure store"
    var document = settingsDocument()
    var rejectWrites = false
    func read() -> SharedSettingsRead { SharedSettingsRead(current: document) }
    func write(
        _ value: SharedSettings, replacing: SharedSettingsRead, resolve: Bool,
        access: SettingsAccessLease
    ) throws {
        try access.check()
        if rejectWrites { throw CocoaError(.fileWriteOutOfSpace) }
        guard replacing.current == document else { throw SharedSettingsError.changed }
        document = value
    }
}

@Test @MainActor func failedSharedCredentialSaveKeepsThePreviouslyUsableConfiguration() async throws
{
    let root = try settingsRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let provider = FailingSettingsFixture()
    let vault = SettingsCredentialFixture()
    vault.token = nil
    let workspace = ToolWorkspace(
        configuration: root.appendingPathComponent("servers.json"),
        credentials: vault, settingsFactory: { _ in provider })
    let cloud = ConversationCloudSync(network: .init(initialState: .satisfied))
    cloud.restore(enabled: true, bookmark: Data("synthetic grant".utf8), base: nil)
    await workspace.reloadSettings(using: cloud)
    let server = try #require(workspace.servers.first)
    provider.rejectWrites = true
    await #expect(throws: CocoaError.self) {
        try await workspace.saveServer(server, newToken: "replacement")
    }
    #expect(try workspace.token(for: server) == "synthetic-test-key")
    await #expect(throws: CocoaError.self) { try await workspace.clearCredential(server.id) }
    #expect(try workspace.token(for: server) == "synthetic-test-key")
    #expect(provider.document.servers.count == 1)
    provider.rejectWrites = false
    var replacement = server
    replacement.endpoint = URL(string: "https://replacement.invalid/mcp")!
    try await workspace.saveServer(replacement, newToken: "new-endpoint-key")
    #expect(provider.document.servers[0].enabledTools.isEmpty)
    #expect(!provider.document.servers[0].enableToolsOnFirstDiscovery)
    #expect(provider.document.servers[0].credential?.endpoint == replacement.endpoint)
    #expect(try workspace.token(for: replacement) == "new-endpoint-key")
    #expect(throws: SharedSettingsError.self) { try workspace.token(for: server) }
}

#if os(macOS)
    @Test @MainActor func sharedCredentialAuthenticatesRealHTTPFromASecondInstallation()
        async throws
    {
        let root = try settingsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let process = Process()
        let pipe = Pipe()
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/mcp_server.py")
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script.path]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        let port = try #require(
            Int(
                String(
                    decoding: pipe.fileHandleForReading.availableData,
                    as: UTF8.self
                ).trimmingCharacters(in: .whitespacesAndNewlines)))
        let file = SettingsFileFixture(file: root.appendingPathComponent("settings.json"))
        let firstRoot = root.appendingPathComponent("first")
        let secondRoot = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        let first = ToolWorkspace(
            configuration: firstRoot.appendingPathComponent("servers.json"),
            credentials: SettingsCredentialFixture(), settingsFactory: { _ in file })
        let server = MCPServer(
            name: "Synthetic authenticated server",
            endpoint: URL(string: "http://127.0.0.1:\(port)/bearer")!)
        try await first.saveServer(server, newToken: "synthetic-key")
        let cloud = ConversationCloudSync(network: .init(initialState: .satisfied))
        cloud.restore(enabled: true, bookmark: Data("synthetic grant".utf8), base: nil)
        await first.reloadSettings(using: cloud)
        first.discover(server.id); await first.waitUntilIdle()
        #expect(first.error == nil)
        #expect(first.servers.first?.enabledTools == ["echo"])
        try await first.setEnabled(false, tool: "echo", serverID: server.id)
        #expect(first.visibleToolNames(for: server.id) == ["echo"])
        try await first.setEnabled(true, tool: "echo", serverID: server.id)
        #expect(first.discovered[server.id]?.count == 1)
        let slow = MCPServer(
            name: "Synthetic pending discovery",
            endpoint: URL(string: "http://127.0.0.1:\(port)/slow")!)
        try await first.saveServer(slow, newToken: "synthetic-key")
        first.discover(slow.id)
        let statsURL = URL(string: "http://127.0.0.1:\(port)/request-counts")!
        var started = false
        for _ in 0..<100 {
            let (data, _) = try await URLSession.shared.data(from: statsURL)
            let counts = try JSONDecoder().decode([String: [String: Int]].self, from: data)
            if counts["/slow"]?["server/discover"] == 1 { started = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(started)
        try await first.clearCredential(slow.id)
        await first.waitUntilIdle()
        #expect(first.connecting == nil)
        let (countsData, _) = try await URLSession.shared.data(from: statsURL)
        let counts = try JSONDecoder().decode([String: [String: Int]].self, from: countsData)
        #expect(counts["/slow"]?["tools/list"] == nil)
        try await first.removeServer(slow.id)
        let secondVault = SettingsCredentialFixture()
        secondVault.token = "wrong-local-key-must-not-be-used"
        let second = ToolWorkspace(
            configuration: secondRoot.appendingPathComponent("servers.json"),
            credentials: secondVault, settingsFactory: { _ in file })
        await second.reloadSettings(using: cloud)
        second.discover(server.id); await second.waitUntilIdle()
        #expect(second.error == nil)
        let result = try await second.remoteCall(
            serverID: server.id, name: "echo",
            arguments: ["text": .string("Shared key worked")])
        #expect(
            result["content"]
                == .array([
                    .object([
                        "type": .string("text"),
                        "text": .string("Shared key worked"),
                    ])
                ]))
        let cancelledCall = Task {
            try await second.remoteCall(
                serverID: server.id, name: "echo",
                arguments: ["text": .string("Cancelled before dispatch")])
        }
        cancelledCall.cancel()
        await #expect(throws: CancellationError.self) { try await cancelledCall.value }
        let beforeOff = second.revision
        cloud.persist = {}
        cloud.disable()
        #expect(second.revision != beforeOff && second.discovered.isEmpty)
        await #expect(throws: SharedSettingsError.self) {
            try await second.remoteCall(
                serverID: server.id, name: "echo",
                arguments: ["text": .string("Must not leave the Off profile")])
        }
        cloud.restore(enabled: true, bookmark: Data("synthetic grant".utf8), base: nil)
        await first.reloadSettings(using: cloud)
        await second.reloadSettings(using: cloud)
        // A restart can plan from schemas locally, with no live connection.
        let restarted = ToolWorkspace(
            configuration: secondRoot.appendingPathComponent("servers.json"),
            credentials: secondVault, settingsFactory: { _ in file })
        await restarted.reloadSettings(using: cloud)
        #expect(try restarted.remoteTools().count == 1)
        #expect(restarted.discovered.isEmpty)
        try await first.clearCredential(server.id)
        await second.reloadSettings(using: cloud)
        second.discover(server.id); await second.waitUntilIdle()
        #expect(second.error != nil)  // actual 401, never the device key or a guessed success
        #expect(second.discovered.isEmpty)
    }
#endif

@Test @MainActor func selectedSkillPreferenceSurvivesRestartAndNoneIsDurable() async throws {
    let root = try settingsRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let skills = root.appendingPathComponent("Skills")
    let folder = skills.appendingPathComponent("test-skill")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("---\nname: test-skill\ndescription: Synthetic settings test\n---\nBe concise.".utf8)
        .write(to: folder.appendingPathComponent("SKILL.md"))
    let file = root.appendingPathComponent("servers.json")
    let cloud = ConversationCloudSync(network: .init(initialState: .satisfied))
    let first = ToolWorkspace(store: SkillStore(localRoot: skills), configuration: file)
    first.reloadSkills(using: cloud); await first.waitUntilIdle()
    try await first.selectSkill("test-skill", using: cloud)
    let second = ToolWorkspace(store: SkillStore(localRoot: skills), configuration: file)
    second.reloadSkills(using: cloud)
    let loadingRevision = second.revision
    await second.waitUntilIdle()
    #expect(second.revision != loadingRevision)
    #expect(second.selectedSkill?.name == "test-skill")
    try await second.selectSkill(nil, using: cloud)
    let third = ToolWorkspace(store: SkillStore(localRoot: skills), configuration: file)
    third.reloadSkills(using: cloud); await third.waitUntilIdle()
    #expect(third.selectedSkill == nil)
    try await third.selectSkill("test-skill", using: cloud)
    try FileManager.default.removeItem(at: folder)
    third.reloadSkills(using: cloud); await third.waitUntilIdle()
    #expect(throws: SkillFailure.self) { try third.instructions(using: cloud) }
    // An unavailable selected file can be explicitly deselected, never silently omitted.
    try await third.selectSkill(nil, using: cloud)
    #expect(try third.instructions(using: cloud).isEmpty)
}

@Test @MainActor func emptyOffProfileAndDeletedCloudStillRequireMigrationChoices() async throws {
    let root = try settingsRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SettingsFileFixture(file: root.appendingPathComponent("settings.json"))
    let receipt = root.appendingPathComponent("receipt.json")
    let original = settingsDocument()
    let first = SharedSettingsSession(storage: store, receipt: receipt)
    _ = try await first.refresh(local: original)
    let reopened = SharedSettingsSession(storage: store, receipt: receipt)
    await #expect(throws: SharedSettingsError.self) {
        try await reopened.refresh(local: SharedSettings())
    }
    #expect(try store.read().current == original)
    _ = try await reopened.resolve(1, expected: await reopened.choices[1])
    try FileManager.default.removeItem(at: store.file)
    let another = SharedSettingsSession(storage: store, receipt: receipt)
    await #expect(throws: SharedSettingsError.self) {
        try await another.refresh(local: original)
    }
    #expect(!FileManager.default.fileExists(atPath: store.file.path))
}

@Test(arguments: ["servers.json", "skill.json"]) @MainActor
func localProfileReloadNeverClearsAnUnreadConfigurationError(fileName: String) async throws {
    let root = try settingsRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("servers.json")
    let workspace = ToolWorkspace(configuration: file, credentials: SettingsCredentialFixture())
    let server = settingsDocument().servers[0].registration
    try await workspace.saveServer(server)
    let cloud = ConversationCloudSync(network: .init(initialState: .satisfied))
    await workspace.reloadSettings(using: cloud)
    let bad = root.appendingPathComponent(fileName)
    let original =
        fileName == "skill.json"
        ? try JSONEncoder().encode(String?.none)
        : try Data(contentsOf: file)
    try Data("Malformed local configuration".utf8).write(to: bad)
    await workspace.reloadSettings(using: cloud)
    #expect(workspace.settingsError != nil)
    await workspace.reloadSettings(using: cloud)
    #expect(workspace.settingsError != nil)
    await #expect(throws: SkillFailure.self) { try await workspace.saveServer(server) }
    #expect(try Data(contentsOf: bad) == Data("Malformed local configuration".utf8))
    try original.write(to: bad)
    await workspace.reloadSettings(using: cloud)
    #expect(workspace.settingsError == nil)
    try await workspace.saveServer(server)
}

private final class BlockedSettingsFixture: SharedSettingsStoring, @unchecked Sendable {
    let identity = "synthetic blocked provider"
    let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var entered = false
    private var onMain = false
    private var written = 0
    private var finished = false
    let missing: Bool
    init(missing: Bool = false) { self.missing = missing }
    var writes: Int { lock.withLock { written } }
    var readFinished: Bool { lock.withLock { finished } }
    var started: Bool { lock.withLock { entered } }
    var usedMainThread: Bool { lock.withLock { onMain } }
    func read() -> SharedSettingsRead {
        lock.withLock {
            entered = true; onMain = Thread.isMainThread
        }
        gate.wait()
        lock.withLock { finished = true }
        return SharedSettingsRead(current: missing ? nil : SharedSettings())
    }
    func write(
        _ value: SharedSettings, replacing: SharedSettingsRead, resolve: Bool,
        access: SettingsAccessLease
    ) throws {
        try access.check()
        lock.withLock { written += 1 }
        throw SharedSettingsError.changed
    }
}

@Test @MainActor func absentSharedSkillCatalogStillAllowsPersistingNone() async throws {
    let root = try settingsRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let provider = FailingSettingsFixture()
    provider.document = SharedSettings(selectedSkill: "missing-skill")
    let workspace = ToolWorkspace(
        store: SkillStore(localRoot: root.appendingPathComponent("Skills")),
        configuration: root.appendingPathComponent("servers.json"),
        credentials: SettingsCredentialFixture(), settingsFactory: { _ in provider })
    let cloud = ConversationCloudSync(network: .init(initialState: .satisfied))
    cloud.restore(enabled: true, bookmark: Data("unresolvable synthetic grant".utf8), base: nil)
    workspace.reloadSkills(using: cloud); await workspace.waitUntilIdle()
    #expect(workspace.skillSourceKey == nil && workspace.error != nil)
    #expect(workspace.settingsError == nil)
    try await workspace.selectSkill(nil, using: cloud)
    #expect(provider.document.selectedSkill == nil)
    #expect(try workspace.instructions(using: cloud).isEmpty)
}

@Test @MainActor func staleEditorCannotRestoreAnOldEndpointOrClearTheNewKeyAndGrants() async throws
{
    let root = try settingsRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let provider = FailingSettingsFixture()
    let workspace = ToolWorkspace(
        configuration: root.appendingPathComponent("servers.json"),
        credentials: SettingsCredentialFixture(), settingsFactory: { _ in provider })
    let cloud = ConversationCloudSync(network: .init(initialState: .satisfied))
    cloud.restore(enabled: true, bookmark: Data("synthetic grant".utf8), base: nil)
    await workspace.reloadSettings(using: cloud)
    var oldForm = try #require(workspace.servers.first)
    let baseline = try workspace.captureServerEdit(oldForm.id)
    provider.document.servers[0].endpoint = URL(string: "https://new-endpoint.invalid/mcp")!
    provider.document.servers[0].credential = SharedCredential(
        endpoint: provider.document.servers[0].endpoint, bearerToken: "new-synthetic-key")
    provider.document.servers[0].enabledTools = ["new_tool"]
    let newer = provider.document
    await workspace.reloadSettings(using: cloud)
    oldForm.name = "Name edited in the stale form"
    await #expect(throws: SharedSettingsError.self) {
        try await workspace.saveServer(oldForm, expected: baseline)
    }
    #expect(provider.document == newer)
    let fresh = try workspace.captureServerEdit(oldForm.id)
    var updated = try #require(workspace.servers.first)
    updated.name = "Fresh name edit"
    try await workspace.saveServer(updated, expected: fresh)
    #expect(provider.document.servers[0].credential?.bearerToken == "new-synthetic-key")
    #expect(provider.document.servers[0].enabledTools == ["new_tool"])
    let permissionsBaseline = try workspace.captureServerEdit(updated.id)
    provider.document.servers[0].enabledTools = ["changed_permission"]
    await workspace.reloadSettings(using: cloud)
    updated.name = "Name edit preserves newer permissions"
    try await workspace.saveServer(updated, expected: permissionsBaseline)
    #expect(provider.document.servers[0].enabledTools == ["changed_permission"])
    cloud.restore(enabled: false, bookmark: nil, base: nil)
    await workspace.reloadSettings(using: cloud)
    await #expect(throws: SharedSettingsError.self) {
        try await workspace.saveServer(updated, expected: fresh)
    }
}

@Test @MainActor func handEditedGrantOrderDoesNotCauseFalseConflictsAfterSkillEdits() async throws {
    let root = try settingsRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SettingsFileFixture(file: root.appendingPathComponent("settings.json"))
    var unordered = settingsDocument()
    unordered.servers[0].enabledTools = ["z", "a"]
    try JSONEncoder().encode(unordered).write(to: store.file)
    let session = SharedSettingsSession(
        storage: store, receipt: root.appendingPathComponent("receipt.json"))
    let loaded = try await session.refresh(local: SharedSettings())
    #expect(loaded.servers[0].enabledTools == ["a", "z"])
    var selected = loaded
    selected.selectedSkill = "example-skill"
    try await session.commit(selected, replacing: loaded)
    var renamed = selected
    renamed.servers[0].name = "Second edit without any intervening external change"
    try await session.commit(renamed, replacing: selected)
    #expect(try store.read().current == renamed)
}

@Test func revokedSettingsAccessCannotCreateACredentialFile() throws {
    let root = try settingsRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("settings.json")
    let access = SettingsAccessLease()
    access.revoke()
    #expect(throws: CancellationError.self) {
        try CoordinatedSettingsFile.write(
            settingsDocument(), at: file, replacing: .init(),
            access: access)
    }
    #expect(!FileManager.default.fileExists(atPath: file.path))
}

@Test @MainActor func editorRefreshRecoversFromAnExternalEditWithoutLeavingTheForeground()
    async throws
{
    let root = try settingsRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = SettingsFileFixture(file: root.appendingPathComponent("settings.json"))
    let original = settingsDocument()
    try original.encoded().write(to: file.file)
    let workspace = ToolWorkspace(
        configuration: root.appendingPathComponent("servers.json"),
        credentials: SettingsCredentialFixture(), settingsFactory: { _ in file })
    let cloud = ConversationCloudSync(network: .init(initialState: .satisfied))
    cloud.restore(enabled: true, bookmark: Data("synthetic grant".utf8), base: nil)
    await workspace.refreshSettingsAndSkills(using: cloud)
    let baseline = try workspace.captureServerEdit(original.servers[0].id)
    var form = original.servers[0].registration
    form.name = "Edited locally"
    var external = original
    external.servers[0].endpoint = URL(string: "https://externally-changed.invalid/mcp")!
    external.servers[0].credential = SharedCredential(
        endpoint: external.servers[0].endpoint,
        bearerToken: "synthetic-newer-key")
    try external.encoded().write(to: file.file, options: .atomic)
    // The in-memory baseline still matches, but file coordination rejects the stale save.
    await #expect(throws: SharedSettingsError.self) {
        try await workspace.saveServer(form, expected: baseline)
    }
    await workspace.refreshSettingsAndSkills(using: cloud)
    #expect(!workspace.loadingSkills && workspace.settingsError == nil)
    let fresh = try workspace.captureServerEdit(form.id)
    var refreshed = try #require(workspace.servers.first)
    #expect(refreshed.endpoint == external.servers[0].endpoint)
    refreshed.name = "New edit after explicit refresh"
    try await workspace.saveServer(refreshed, expected: fresh)
    let saved = try #require(try file.read().current?.servers.first)
    #expect(saved.name == refreshed.name && saved.endpoint == external.servers[0].endpoint)
    #expect(saved.credential?.bearerToken == "synthetic-newer-key")
}

// Every test that deliberately blocks a provider belongs here: concurrent blocked reads
// can exhaust a small CI worker's cooperative pool before either driver can signal its read.
@Suite(.serialized)
struct BlockedSettingsProviderTests {
    @Test(arguments: [false, true]) @MainActor
    func stalledSettingsProviderLeavesOffResponsiveAndRejectsItsLateResult(missing: Bool)
        async throws
    {
        let root = try settingsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = BlockedSettingsFixture(missing: missing)
        defer { provider.gate.signal() }
        let workspace = ToolWorkspace(
            configuration: root.appendingPathComponent("servers.json"),
            credentials: SettingsCredentialFixture(), settingsFactory: { _ in provider })
        let local = settingsDocument("Local profile").servers[0].registration
        try await workspace.saveServer(local)
        let cloud = ConversationCloudSync(network: .init(initialState: .satisfied))
        cloud.restore(enabled: true, bookmark: Data("synthetic grant".utf8), base: nil)
        cloud.persist = {}
        let clock = ContinuousClock()
        let start = clock.now
        let pending = Task { await workspace.reloadSettings(using: cloud) }
        while !provider.started && clock.now - start < .seconds(30) {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(provider.started)
        #expect(!provider.usedMainThread)
        #expect(!provider.readFinished)
        cloud.disable()
        provider.gate.signal()
        await pending.value
        #expect(provider.writes == 0)
        await workspace.reloadSettings(using: cloud)
        #expect(workspace.servers == [local] && workspace.settingsError == nil)
        #expect(!workspace.settingsLoading)
    }

    @Test @MainActor func cancellingPreparationReturnsWhileProviderReadRemainsBlocked() async throws
    {
        let root = try settingsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = BlockedSettingsFixture(missing: true)
        defer { provider.gate.signal() }
        let workspace = ToolWorkspace(
            configuration: root.appendingPathComponent("servers.json"),
            credentials: SettingsCredentialFixture(), settingsFactory: { _ in provider })
        let cloud = ConversationCloudSync(network: .init(initialState: .satisfied))
        await workspace.reloadSettings(using: cloud)
        cloud.restore(enabled: true, bookmark: Data("synthetic grant".utf8), base: nil)
        let pending = Task { try await workspace.prepare(using: cloud) }
        let clock = ContinuousClock()
        let start = clock.now
        while !provider.started && clock.now - start < .seconds(30) {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(provider.started)
        pending.cancel()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(!provider.readFinished && provider.writes == 0)
        provider.gate.signal()
        await workspace.waitUntilIdle()
        #expect(provider.writes == 0)
    }
}
