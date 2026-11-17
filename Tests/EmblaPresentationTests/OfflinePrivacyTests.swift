import Foundation
import Testing

import EmblaCore
@testable import EmblaPresentation

@Test @MainActor func offlinePreparationRetainsRegistrationsAndAllowsOnlyDeviceSkillFiles()
    async throws
{
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let skillRoot = root.appendingPathComponent("Skills")
    let folder = skillRoot.appendingPathComponent("offline-writing")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(
        """
        ---
        name: offline-writing
        description: Synthetic local skill.
        ---
        Use the reference file.
        """.utf8
    ).write(to: folder.appendingPathComponent("SKILL.md"))
    try Data("Synthetic device-only reference".utf8).write(
        to: folder.appendingPathComponent("reference.txt"))
    let registration = MCPServer(
        name: "Unreachable fixture", endpoint: URL(string: "https://example.invalid/mcp")!,
        enabledTools: ["get_current_time"])
    let file = root.appendingPathComponent("servers.json")
    let bytes = try JSONEncoder().encode([registration])
    try bytes.write(to: file)
    let policy = NetworkAccess(initialState: .unsatisfied)
    let tools = ToolWorkspace(
        store: SkillStore(localRoot: skillRoot, network: policy), configuration: file,
        network: policy)
    let cloud = ConversationCloudSync(network: policy)
    tools.reloadSkills(using: cloud)
    await tools.waitUntilIdle()
    try await tools.selectSkill("offline-writing", using: cloud)
    try await tools.prepare(using: cloud)
    let specifications = try tools.specifications(using: cloud)
    #expect(specifications.count == 1 && specifications.first?.name == "read_skill_file")
    let invocation = try tools.invocation(
        server: "skill", name: "read_skill_file", arguments: ["path": .string("reference.txt")])
    let result = try await tools.execute(invocation, using: cloud)
    #expect(result == .object(["text": .string("Synthetic device-only reference")]))
    #expect(tools.servers == [registration] && tools.discovered.isEmpty)
    #expect(try Data(contentsOf: file) == bytes)
    #expect(try tools.instructions(using: cloud).contains("Network tools are unavailable"))
    #expect(throws: NetworkAccessFailure.offline) {
        try tools.invocation(server: registration.modelID, name: "get_current_time", arguments: [:])
    }
    policy.updatePath(.satisfied)
    policy.activateRequests(after: policy.snapshot.revision)
    // This already-prepared request never silently gains remote capabilities.
    #expect(try tools.remoteTools(forRequest: true).isEmpty)
    #expect(throws: NetworkAccessFailure.requestPaused) {
        try tools.invocation(server: registration.modelID, name: "get_current_time", arguments: [:])
    }
}

@Test @MainActor func offlineCloudPreservesOnAndDoesNotOpenTheGrantedFolder() async throws {
    let policy = NetworkAccess(initialState: .unsatisfied)
    // Invalid bookmark is intentional: any attempted provider access would fail the test.
    let cloud = ConversationCloudSync(network: policy)
    cloud.restore(enabled: true, bookmark: Data([1, 2, 3]), base: nil, consentVersion: 2)
    cloud.connectivityChanged()
    #expect(cloud.enabled && !cloud.folderAccessReady && cloud.authorizedFolderBookmark == nil)
    let tools = ToolWorkspace(network: policy)
    try await tools.prepare(using: cloud)
    #expect(try tools.specifications(using: cloud).isEmpty)
    #expect(
        try tools.instructions(using: cloud).contains(
            "iCloud skills, actions and settings are paused"))
    cloud.refresh()
    #expect(cloud.enabled && cloud.error == nil)
    #expect(QuickActionsModel.sourceKey(for: cloud).hasPrefix("network-paused:"))
}

@Test func cloudFileBoundariesRejectOfflineBeforeAnyDocumentOrBookmarkAccess() async throws {
    let policy = NetworkAccess(initialState: .unsatisfied)
    let nonexistent = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
    #expect(throws: NetworkAccessFailure.offline) {
        try CoordinatedConversationFile.read(at: nonexistent, network: policy)
    }
    #expect(throws: NetworkAccessFailure.offline) {
        try CoordinatedSettingsFile.read(nonexistent, network: policy)
    }
    #expect(throws: NetworkAccessFailure.offline) {
        try CoordinatedActionFile.create(at: nonexistent, network: policy)
    }
    let lease = SettingsAccessLease(network: policy)
    #expect(throws: NetworkAccessFailure.offline) { try lease.check() }
    let store = SkillStore(localRoot: nonexistent, network: policy)
    await #expect(throws: NetworkAccessFailure.offline) { try await store.entries(.cloud(Data())) }
    #expect(!FileManager.default.fileExists(atPath: nonexistent.path))
}

@Test @MainActor func connectivityChangeDoesNotRevokeADeviceOnlySkillRequest() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let policy = NetworkAccess(initialState: .satisfied)
    let cloud = ConversationCloudSync(network: policy)
    let tools = ToolWorkspace(
        configuration: root.appendingPathComponent("servers.json"), network: policy)
    await tools.refreshSettingsAndSkills(using: cloud)
    let revision = tools.revision
    policy.updatePath(.unsatisfied)
    cloud.connectivityChanged()
    tools.connectivityChanged(using: cloud)
    #expect(tools.revision == revision)
    #expect(!tools.requestHasNetworkDependency)
}

@Test func aPreviouslyGrantedCloudWriteLeaseCannotWriteAfterPathLoss() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("settings.json")
    let original = SharedSettings()
    try original.encoded().write(to: file)
    let before = try CoordinatedSettingsFile.read(file)
    let policy = NetworkAccess(initialState: .satisfied)
    let lease = SettingsAccessLease(network: policy)
    policy.updatePath(.unsatisfied)
    #expect(throws: NetworkAccessFailure.offline) {
        try CoordinatedSettingsFile.write(original, at: file, replacing: before, access: lease)
    }
    #expect(try Data(contentsOf: file) == original.encoded())
}
