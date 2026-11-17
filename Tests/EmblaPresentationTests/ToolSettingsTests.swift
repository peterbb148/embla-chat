import Foundation
import Testing

import EmblaCore
@testable import EmblaPresentation

private final class MemoryCredentialFixture: MCPCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [MCPCredentialID: String] = [:]
    func read(_ id: MCPCredentialID) -> String? { lock.withLock { values[id] } }
    func write(_ value: String, id: MCPCredentialID) { lock.withLock { values[id] = value } }
    func deleteEndpoint(_ id: MCPCredentialID) { lock.withLock { values[id] = nil } }
    func deleteAll(_ serverID: UUID) {
        lock.withLock { values = values.filter { $0.key.serverID != serverID } }
    }
}

@Test @MainActor func failedEndpointSaveCannotReplaceThePreviousEndpointsCredential() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }
    let file = root.appendingPathComponent("servers.json")
    let vault = MemoryCredentialFixture()
    let workspace = ToolWorkspace(configuration: file, credentials: vault)
    let old = MCPServer(
        name: "Synthetic previous endpoint",
        endpoint: URL(string: "https://old.example.invalid/mcp")!,
        enabledTools: ["existing"])
    try await workspace.saveServer(old, newToken: "fixture-old")
    let original = try Data(contentsOf: file)
    var replacement = old
    replacement.endpoint = URL(string: "https://new.example.invalid/mcp")!
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
    await #expect(throws: (any Error).self) {
        try await workspace.saveServer(replacement, newToken: "fixture-new")
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    let retained = try Data(contentsOf: file)
    #expect(workspace.servers == [old] && retained == original)
    #expect(vault.read(MCPCredentialID(server: old)) == "fixture-old")
    #expect(vault.read(MCPCredentialID(server: replacement)) == "fixture-new")
    #expect(MCPCredentialID(server: old) != MCPCredentialID(server: replacement))
}

@Test @MainActor func staleEnabledToolsCanBeRevokedWithoutDiscoveryOrDeletingTheServer()
    async throws
{
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("servers.json")
    let server = MCPServer(
        name: "Saved synthetic server", endpoint: URL(string: "https://example.invalid/mcp")!,
        enabledTools: ["removed_tool"])
    try JSONEncoder().encode([server]).write(to: file)
    let reopened = ToolWorkspace(configuration: file, credentials: MemoryCredentialFixture())
    #expect(reopened.visibleToolNames(for: server.id) == ["removed_tool"])
    try await reopened.setEnabled(false, tool: "removed_tool", serverID: server.id)
    #expect(reopened.servers.first?.enabledTools.isEmpty == true)
    #expect(reopened.visibleToolNames(for: server.id).isEmpty)
    #expect(try reopened.remoteTools().isEmpty)
    await #expect(throws: SkillFailure.self) {
        try await reopened.setEnabled(true, tool: "removed_tool", serverID: server.id)
    }
    #expect(ToolWorkspace(configuration: file).servers.first?.enabledTools.isEmpty == true)
}

@Test @MainActor func corruptMCPSettingsCannotBecomeAnEmptyToolFreeConfiguration() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("servers.json")
    let original = Data("Corrupt synthetic MCP settings".utf8)
    try original.write(to: file)
    let workspace = ToolWorkspace(configuration: file)
    #expect(workspace.error != nil)
    #expect(throws: SkillFailure.self) { try workspace.remoteTools() }
    await #expect(throws: SkillFailure.self) {
        try await workspace.prepare(
            using: ConversationCloudSync(network: .init(initialState: .satisfied)))
    }
    #expect(try Data(contentsOf: file) == original)
}

@Test @MainActor func registeredEnabledToolsRestoreWithoutConnectingAtStartup() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("servers.json")
    let server = MCPServer(
        name: "Saved synthetic server", endpoint: URL(string: "https://example.invalid/mcp")!,
        enabledTools: ["get_current_time"])
    try JSONEncoder().encode([server]).write(to: file)
    let reopened = ToolWorkspace(configuration: file)
    #expect(reopened.error == nil && reopened.servers == [server])
    #expect(reopened.connecting == nil && reopened.discovered.isEmpty)
}

@Test @MainActor func cancellingSkillReloadBeforeUnapprovedCloudSourceClearsLoading() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = ToolWorkspace(store: SkillStore(localRoot: root))
    let cloud = ConversationCloudSync(network: .init(initialState: .satisfied))
    workspace.reloadSkills(using: cloud)
    #expect(workspace.loadingSkills)
    cloud.restore(enabled: true, bookmark: nil, base: nil, consentVersion: 0)
    workspace.reloadSkills(using: cloud)
    await workspace.waitUntilIdle()
    #expect(!workspace.loadingSkills && workspace.skills.isEmpty && workspace.selectedSkill == nil)
    #expect(workspace.error != nil && workspace.skillSourceKey == nil)
}

/// Typed discovery fixtures exercise persistence/authorization, not a replacement network client.
private func discoveredFixtureTools(_ names: [String]) throws -> [MCPTool] {
    try names.map {
        try MCPTool(
            name: $0, description: "Synthetic discovery fixture.",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])]))
    }
}

@Test @MainActor func initialDiscoveryEnablesAllOnceAndPreservesLaterChoicesAcrossRestart()
    async throws
{
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("servers.json")
    let server = MCPServer(
        name: "New fixture", endpoint: URL(string: "https://example.invalid/mcp")!)
    let workspace = ToolWorkspace(configuration: file, credentials: MemoryCredentialFixture())
    try await workspace.saveServer(server)
    #expect(workspace.servers.first?.enableToolsOnFirstDiscovery == true)
    #expect(workspace.servers.first?.enabledTools.isEmpty == true)
    try await workspace.acceptDiscoveredTools(
        discoveredFixtureTools(["one", "two"]), serverID: server.id)
    #expect(workspace.servers.first?.enabledTools == Set(["one", "two"]))
    #expect(workspace.servers.first?.enableToolsOnFirstDiscovery == false)
    try await workspace.setEnabled(false, tool: "one", serverID: server.id)
    let reopened = ToolWorkspace(configuration: file, credentials: MemoryCredentialFixture())
    try await reopened.acceptDiscoveredTools(
        discoveredFixtureTools(["one", "two", "three"]), serverID: server.id)
    #expect(reopened.servers.first?.enabledTools == Set(["two"]))
    // The editor reconstructs a value with initializer defaults; saving must not reset consent.
    try await reopened.saveServer(
        MCPServer(
            id: server.id, name: "Renamed fixture", endpoint: server.endpoint,
            enabledTools: ["two"]))
    try await reopened.acceptDiscoveredTools(
        discoveredFixtureTools(["one", "two", "three"]), serverID: server.id)
    #expect(reopened.servers.first?.enabledTools == Set(["two"]))
    #expect(reopened.servers.first?.enableToolsOnFirstDiscovery == false)
    #expect(ToolWorkspace(configuration: file).servers.first?.enabledTools == Set(["two"]))
}

@Test @MainActor func legacyRegistrationsAndEndpointEditsNeverGainImplicitPermissions() async throws
{
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("servers.json")
    let id = UUID()
    let legacy: [[String: Any]] = [
        [
            "id": id.uuidString, "name": "Legacy fixture",
            "endpoint": "https://example.invalid/mcp", "enabledTools": ["one"],
        ]
    ]
    try JSONSerialization.data(withJSONObject: legacy).write(to: file)
    let workspace = ToolWorkspace(configuration: file, credentials: MemoryCredentialFixture())
    #expect(workspace.servers.first?.enableToolsOnFirstDiscovery == false)
    try await workspace.acceptDiscoveredTools(discoveredFixtureTools(["one", "two"]), serverID: id)
    #expect(workspace.servers.first?.enabledTools == Set(["one"]))
    try await workspace.saveServer(
        MCPServer(
            id: id, name: "Changed endpoint", endpoint: URL(string: "https://new.invalid/mcp")!,
            enabledTools: ["one"]))
    try await workspace.acceptDiscoveredTools(discoveredFixtureTools(["three"]), serverID: id)
    #expect(workspace.servers.first?.enabledTools.isEmpty == true)
    #expect(workspace.servers.first?.enableToolsOnFirstDiscovery == false)
}

@Test @MainActor func failedInitialGrantDoesNotPublishOrConsumeThePendingDiscovery() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }
    let file = root.appendingPathComponent("servers.json")
    let workspace = ToolWorkspace(configuration: file, credentials: MemoryCredentialFixture())
    let server = MCPServer(
        name: "New fixture", endpoint: URL(string: "https://example.invalid/mcp")!)
    try await workspace.saveServer(server)
    let original = try Data(contentsOf: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
    await #expect(throws: (any Error).self) {
        try await workspace.acceptDiscoveredTools(
            discoveredFixtureTools(["one"]), serverID: server.id)
    }
    #expect(workspace.servers.first?.enableToolsOnFirstDiscovery == true)
    #expect(workspace.servers.first?.enabledTools.isEmpty == true)
    #expect(workspace.discovered[server.id] == nil)
    #expect(try Data(contentsOf: file) == original)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    try await workspace.acceptDiscoveredTools(discoveredFixtureTools(["one"]), serverID: server.id)
    #expect(workspace.servers.first?.enabledTools == Set(["one"]))
    #expect(workspace.servers.first?.enableToolsOnFirstDiscovery == false)
}

/// Local planning must survive restart without treating metadata as a live connection.
@Test @MainActor func savedToolSchemasRemainUsableForOfflineContextAfterPauseAndRestart()
    async throws
{
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("servers.json")
    let workspace = ToolWorkspace(configuration: file, credentials: MemoryCredentialFixture())
    let server = MCPServer(
        name: "Synthetic planning server",
        endpoint: URL(string: "https://example.invalid/mcp")!)
    try await workspace.saveServer(server)
    try await workspace.acceptDiscoveredTools(
        discoveredFixtureTools(["clock"]), serverID: server.id)
    workspace.pause()
    #expect(try workspace.remoteTools().map(\.name) == ["clock"])
    let reopened = ToolWorkspace(configuration: file, credentials: MemoryCredentialFixture())
    #expect(reopened.discovered.isEmpty && reopened.connecting == nil)
    #expect(try reopened.remoteTools().map(\.name) == ["clock"])
    await #expect(throws: SkillFailure.self) {
        try await reopened.remoteCall(serverID: server.id, name: "clock", arguments: [:])
    }
}

@Test @MainActor func changedCredentialOrEndpointInvalidatesStoredPlanningSchemas() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("servers.json")
    let workspace = ToolWorkspace(configuration: file, credentials: MemoryCredentialFixture())
    let server = MCPServer(
        name: "Synthetic planning server",
        endpoint: URL(string: "https://example.invalid/mcp")!)
    try await workspace.saveServer(server)
    try await workspace.acceptDiscoveredTools(
        discoveredFixtureTools(["clock"]), serverID: server.id)
    try await workspace.saveServer(workspace.servers[0], newToken: "synthetic-new-credential")
    #expect(workspace.servers[0].lastDiscoveredTools == nil)
    #expect(ToolWorkspace(configuration: file).servers[0].lastDiscoveredTools == nil)
    try await workspace.acceptDiscoveredTools(
        discoveredFixtureTools(["clock"]), serverID: server.id)
    try await workspace.clearCredential(server.id)
    #expect(workspace.servers[0].lastDiscoveredTools == nil)
    try await workspace.acceptDiscoveredTools(
        discoveredFixtureTools(["clock"]), serverID: server.id)
    var changed = workspace.servers[0]
    changed.endpoint = URL(string: "https://other.example.invalid/mcp")!
    try await workspace.saveServer(changed)
    #expect(workspace.servers[0].lastDiscoveredTools == nil)
    #expect(workspace.servers[0].enabledTools.isEmpty)
}

@Test @MainActor func corruptStoredSchemasFailClosedInsteadOfLosingEnabledTools() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("servers.json")
    let server = MCPServer(
        name: "Synthetic corrupt catalog",
        endpoint: URL(string: "https://example.invalid/mcp")!, enabledTools: ["clock"])
    var object = try #require(
        JSONSerialization.jsonObject(
            with: JSONEncoder().encode([server])) as? [[String: Any]])
    object[0]["lastDiscoveredTools"] = [
        ["name": "clock", "description": "Invalid saved schema", "inputSchema": false]
    ]
    let corrupt = try JSONSerialization.data(withJSONObject: object)
    try corrupt.write(to: file)
    let workspace = ToolWorkspace(configuration: file, credentials: MemoryCredentialFixture())
    #expect(workspace.error != nil)
    #expect(throws: SkillFailure.self) { try workspace.remoteTools() }
    await #expect(throws: SkillFailure.self) {
        try await workspace.prepare(
            using: ConversationCloudSync(network: .init(initialState: .satisfied)))
    }
    #expect(try Data(contentsOf: file) == corrupt)
}

enum CredentialMutationFixture: String, CaseIterable, Sendable { case replace, clear, removeServer }

@Test(arguments: CredentialMutationFixture.allCases) @MainActor
func failedMetadataInvalidationLeavesTheCredentialAndItsSchemasUnchanged(
    _ mutation: CredentialMutationFixture
) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }
    let file = root.appendingPathComponent("servers.json")
    let vault = MemoryCredentialFixture()
    let workspace = ToolWorkspace(configuration: file, credentials: vault)
    let server = MCPServer(
        name: "Credential-bound synthetic catalog",
        endpoint: URL(string: "https://example.invalid/mcp")!)
    try await workspace.saveServer(server, newToken: "synthetic-original")
    try await workspace.acceptDiscoveredTools(
        discoveredFixtureTools(["clock"]), serverID: server.id)
    let original = try Data(contentsOf: file)
    let originalServer = workspace.servers[0]
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
    await #expect(throws: (any Error).self) {
        switch mutation {
        case .clear: try await workspace.clearCredential(server.id)
        case .removeServer: try await workspace.removeServer(server.id)
        case .replace:
            try await workspace.saveServer(originalServer, newToken: "synthetic-replacement")
        }
    }
    #expect(vault.read(MCPCredentialID(server: server)) == "synthetic-original")
    #expect(workspace.servers[0] == originalServer)
    #expect(try Data(contentsOf: file) == original)
    #expect(try workspace.remoteTools().map(\.name) == ["clock"])
}
