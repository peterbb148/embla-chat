import Foundation
import Testing

import EmblaCore
@testable import EmblaPresentation

private struct SettingsFileFixture: SharedSettingsStoring {
    let file: URL
    var identity: String { file.path }
    func read() throws -> SharedSettingsRead { try CoordinatedSettingsFile.read(file) }
    func write(_ value: SharedSettings, replacing: SharedSettingsRead, resolve: Bool) throws {
        try CoordinatedSettingsFile.write(value, at: file, replacing: replacing, resolve: resolve)
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
    throws
{
    let root = try settingsRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SettingsFileFixture(file: root.appendingPathComponent("settings.json"))
    let first = SharedSettingsSession(
        storage: store, receipt: root.appendingPathComponent("first.json"))
    var original = settingsDocument()
    original.selectedSkill = "concise-writing"
    #expect(try first.refresh(local: original) == original)
    let second = SharedSettingsSession(
        storage: store, receipt: root.appendingPathComponent("second.json"))
    #expect(try second.refresh(local: SharedSettings()) == original)
    var changed = original
    changed.servers[0].credential?.bearerToken = "replacement-synthetic-key"
    changed.servers[0].enabledTools = []
    try first.commit(changed)
    #expect(try second.refresh(local: SharedSettings()) == changed)
    changed.servers = []
    try second.commit(changed)
    #expect(try first.refresh(local: original) == changed)
    let receipt = try String(contentsOf: first.receipt, encoding: .utf8)
    #expect(!receipt.contains("synthetic-key") && !receipt.contains("bearerToken"))
}

@Test @MainActor func concurrentSettingsWritesAndMigrationNeverSilentlyOverwrite() throws {
    let root = try settingsRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SettingsFileFixture(file: root.appendingPathComponent("settings.json"))
    let first = SharedSettingsSession(
        storage: store, receipt: root.appendingPathComponent("first.json"))
    let second = SharedSettingsSession(
        storage: store, receipt: root.appendingPathComponent("second.json"))
    let original = settingsDocument()
    _ = try first.refresh(local: original)
    _ = try second.refresh(local: SharedSettings())
    var changed = original
    changed.servers[0].name = "First edit"
    try first.commit(changed)
    var stale = original
    stale.servers[0].name = "Stale edit"
    #expect(throws: SharedSettingsError.self) { try second.commit(stale) }
    #expect(try store.read().current == changed)
    let migration = SharedSettingsSession(
        storage: store, receipt: root.appendingPathComponent("third.json"))
    let different = settingsDocument("Unmigrated device")
    #expect(throws: SharedSettingsError.self) { try migration.refresh(local: different) }
    #expect(migration.choices == [different, changed])
    #expect(try migration.resolve(1) == changed)
    #expect(try migration.refresh(local: different) == changed)
    // An Off-profile edit is not ignored on re-enable.
    var editedOff = different
    editedOff.servers[0].name = "Changed while Off"
    #expect(throws: SharedSettingsError.self) { try migration.refresh(local: editedOff) }
    #expect(migration.choices.first == editedOff)
}

@Test @MainActor func deletedOrInvalidSharedSettingsRequireAnExplicitDecision() throws {
    let root = try settingsRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SettingsFileFixture(file: root.appendingPathComponent("settings.json"))
    let session = SharedSettingsSession(
        storage: store, receipt: root.appendingPathComponent("receipt.json"))
    let original = settingsDocument()
    _ = try session.refresh(local: original)
    try FileManager.default.removeItem(at: store.file)
    #expect(throws: SharedSettingsError.self) { try session.refresh(local: original) }
    #expect(!FileManager.default.fileExists(atPath: store.file.path))
    #expect(try session.resolve(1).servers.isEmpty)
    try Data("broken JSON".utf8).write(to: store.file)
    #expect(throws: (any Error).self) { try session.refresh(local: original) }
    #expect(try Data(contentsOf: store.file) == Data("broken JSON".utf8))
}

@Test @MainActor func workspaceFollowsCloudScopeAndNeverUsesDeviceKeysForSharedServers() throws {
    let root = try settingsRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let localFile = root.appendingPathComponent("servers.json")
    let sharedFile = SettingsFileFixture(file: root.appendingPathComponent("settings.json"))
    let vault = SettingsCredentialFixture()
    let workspace = ToolWorkspace(
        configuration: localFile, credentials: vault,
        settingsFactory: { _ in sharedFile })
    let local = MCPServer(name: "Local", endpoint: URL(string: "https://example.invalid/local")!)
    try workspace.saveServer(local)
    let cloud = ConversationCloudSync()
    workspace.reloadSettings(using: cloud)
    #expect(!FileManager.default.fileExists(atPath: sharedFile.file.path))
    cloud.restore(enabled: true, bookmark: Data("synthetic grant".utf8), base: nil)
    // The source guard blocks operations until the selected profile is loaded.
    #expect(throws: SharedSettingsError.self) { try workspace.saveServer(local) }
    workspace.reloadSettings(using: cloud)
    #expect(workspace.settingsError == nil)
    #expect(
        try sharedFile.read().current?.servers.first?.credential?.bearerToken == "synthetic-key")
    try workspace.clearCredential(local.id)
    #expect(try workspace.token(for: local) == nil)  // no fallback to device Keychain
    #expect(vault.token == "synthetic-key")
    cloud.restore(enabled: false, bookmark: nil, base: nil)
    workspace.reloadSettings(using: cloud)
    #expect(workspace.servers == [local])
    #expect(try workspace.token(for: local) == "synthetic-key")
    // Corrupt cloud files must not be touched/read with the switch Off.
    try Data("bad JSON".utf8).write(to: sharedFile.file)
    workspace.reloadSettings(using: cloud)
    #expect(workspace.settingsError == nil)
    cloud.restore(
        enabled: true, bookmark: Data("synthetic grant".utf8), base: nil, consentVersion: 1)
    workspace.reloadSettings(using: cloud)
    #expect(workspace.settingsError != nil && workspace.servers.isEmpty)
    #expect(try Data(contentsOf: sharedFile.file) == Data("bad JSON".utf8))
}

private final class FailingSettingsFixture: SharedSettingsStoring {
    var identity = "synthetic failure store"
    var document = settingsDocument()
    var rejectWrites = false
    func read() -> SharedSettingsRead { SharedSettingsRead(current: document) }
    func write(_ value: SharedSettings, replacing: SharedSettingsRead, resolve: Bool) throws {
        if rejectWrites { throw CocoaError(.fileWriteOutOfSpace) }
        guard replacing.current == document else { throw SharedSettingsError.changed }
        document = value
    }
}

@Test @MainActor func failedSharedCredentialSaveKeepsThePreviouslyUsableConfiguration() throws {
    let root = try settingsRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let provider = FailingSettingsFixture()
    let vault = SettingsCredentialFixture()
    vault.token = nil
    let workspace = ToolWorkspace(
        configuration: root.appendingPathComponent("servers.json"),
        credentials: vault, settingsFactory: { _ in provider })
    let cloud = ConversationCloudSync()
    cloud.restore(enabled: true, bookmark: Data("synthetic grant".utf8), base: nil)
    workspace.reloadSettings(using: cloud)
    let server = try #require(workspace.servers.first)
    provider.rejectWrites = true
    #expect(throws: CocoaError.self) { try workspace.saveServer(server, newToken: "replacement") }
    #expect(try workspace.token(for: server) == "synthetic-test-key")
    #expect(throws: CocoaError.self) { try workspace.clearCredential(server.id) }
    #expect(try workspace.token(for: server) == "synthetic-test-key")
    #expect(provider.document.servers.count == 1)
    provider.rejectWrites = false
    var replacement = server
    replacement.endpoint = URL(string: "https://replacement.invalid/mcp")!
    try workspace.saveServer(replacement, newToken: "new-endpoint-key")
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
        try first.saveServer(server, newToken: "synthetic-key")
        let cloud = ConversationCloudSync()
        cloud.restore(enabled: true, bookmark: Data("synthetic grant".utf8), base: nil)
        first.reloadSettings(using: cloud)
        first.discover(server.id); await first.waitUntilIdle()
        #expect(first.error == nil)
        #expect(first.servers.first?.enabledTools == ["echo"])
        let secondVault = SettingsCredentialFixture()
        secondVault.token = "wrong-local-key-must-not-be-used"
        let second = ToolWorkspace(
            configuration: secondRoot.appendingPathComponent("servers.json"),
            credentials: secondVault, settingsFactory: { _ in file })
        second.reloadSettings(using: cloud)
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
        // A restart can plan from schemas locally, with no live connection.
        let restarted = ToolWorkspace(
            configuration: secondRoot.appendingPathComponent("servers.json"),
            credentials: secondVault, settingsFactory: { _ in file })
        restarted.reloadSettings(using: cloud)
        #expect(try restarted.remoteTools().count == 1)
        #expect(restarted.discovered.isEmpty)
        try first.clearCredential(server.id)
        second.reloadSettings(using: cloud)
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
    let cloud = ConversationCloudSync()
    let first = ToolWorkspace(store: SkillStore(localRoot: skills), configuration: file)
    first.reloadSkills(using: cloud); await first.waitUntilIdle()
    try first.selectSkill("test-skill", using: cloud)
    let second = ToolWorkspace(store: SkillStore(localRoot: skills), configuration: file)
    second.reloadSkills(using: cloud); await second.waitUntilIdle()
    #expect(second.selectedSkill?.name == "test-skill")
    try second.selectSkill(nil, using: cloud)
    let third = ToolWorkspace(store: SkillStore(localRoot: skills), configuration: file)
    third.reloadSkills(using: cloud); await third.waitUntilIdle()
    #expect(third.selectedSkill == nil)
    try third.selectSkill("test-skill", using: cloud)
    try FileManager.default.removeItem(at: folder)
    third.reloadSkills(using: cloud); await third.waitUntilIdle()
    #expect(throws: SkillFailure.self) { try third.instructions(using: cloud) }
    // An unavailable selected file can be explicitly deselected, never silently omitted.
    try third.selectSkill(nil, using: cloud)
    #expect(try third.instructions(using: cloud).isEmpty)
}
