import Darwin
import Foundation
import Testing

import EmblaCore
@testable import EmblaPresentation

private let sampleSkill = """
    ---
    name: sample-skill
    description: >-
      Demonstrate portable
      skill instructions.
    compatibility: Text-only use on iPhone
    metadata:
      author: Synthetic test
    allowed-tools: read_skill_file
    ---
    Begin answers with BLUE PENGUIN. Read references/fact.txt when a fact is needed.
    """

@Test func standardSkillMetadataSupportsYAMLAndRejectsInvalidCopiedSkills() throws {
    let skill = try SkillDocument.decode(Data(sampleSkill.utf8), directoryName: "sample-skill")
    #expect(skill.description == "Demonstrate portable skill instructions.")
    #expect(skill.instructions.contains("BLUE PENGUIN"))
    for bad in [
        sampleSkill.replacingOccurrences(of: "name: sample-skill", with: "name: Wrong"),
        sampleSkill.replacingOccurrences(
            of: "name: sample-skill", with: "name: sample-skill\nname: other"),
        "No frontmatter",
    ] {
        #expect(throws: (any Error).self) {
            try SkillDocument.decode(Data(bad.utf8), directoryName: "sample-skill")
        }
    }
}

@Test func skillFilesAreReadOnDemandAndCannotEscapeOrExecuteScripts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("Skills/sample-skill")
    try FileManager.default.createDirectory(
        at: folder.appendingPathComponent("references"), withIntermediateDirectories: true)
    try Data(sampleSkill.utf8).write(to: folder.appendingPathComponent("SKILL.md"))
    try Data("Synthetic supporting fact".utf8).write(
        to: folder.appendingPathComponent("references/fact.txt"))
    let store = SkillStore(localRoot: root.appendingPathComponent("Skills"))
    let skill = try #require(try await store.entries(.device).first?.document)
    #expect(
        try await store.resource("references/fact.txt", skill: skill, source: .device)
            == "Synthetic supporting fact")
    for path in ["../outside.txt", "/tmp/file", "scripts/run.py"] {
        await #expect(throws: (any Error).self) {
            try await store.resource(path, skill: skill, source: .device)
        }
    }
    try FileManager.default.createSymbolicLink(
        at: folder.appendingPathComponent("references/link.txt"),
        withDestinationURL: folder.appendingPathComponent("references/fact.txt"))
    await #expect(throws: SkillFailure.self) {
        try await store.resource("references/link.txt", skill: skill, source: .device)
    }
    try Data(sampleSkill.replacingOccurrences(of: "BLUE PENGUIN", with: "RED FOX").utf8)
        .write(to: folder.appendingPathComponent("SKILL.md"))
    await #expect(throws: SkillFailure.self) {
        try await store.resource("references/fact.txt", skill: skill, source: .device)
    }
}

@Test @MainActor func skillsNeverReadDeviceFilesAsASubstituteForUnapprovedCloudAccess() async throws
{
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = ToolWorkspace(store: SkillStore(localRoot: root))
    let cloud = ConversationCloudSync(network: .init(initialState: .satisfied))
    cloud.restore(enabled: true, bookmark: nil, base: nil, consentVersion: 0)
    workspace.reloadSkills(using: cloud)
    await workspace.waitUntilIdle()
    #expect(workspace.skills.isEmpty && workspace.selectedSkill == nil)
    #expect(workspace.error != nil)
    #expect(!FileManager.default.fileExists(atPath: root.path))
}

@Test func selectedSkillAndToolCatalogAreCountedAlongsideProjectMemoryWithoutExtraSystemRoles()
    throws
{
    let context = ContextCompaction().context(
        transcript: [.init(role: .user, content: "Question")],
        state: .init(), projectMemory: "Project fact",
        instructions: "Selected skill and exact tool schema")
    #expect(context.filter { $0.role == .system }.count == 1)
    #expect(context.first?.content.contains("Selected skill and exact tool schema") == true)
    #expect(context.first?.content.contains("Project fact") == true)
}

@Test func symlinkedSkillsRootCannotExposeFilesOutsideTheSelectedStorage() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let outside = root.appendingPathComponent("Outside")
    let skill = outside.appendingPathComponent("sample-skill")
    try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
    try Data(sampleSkill.utf8).write(to: skill.appendingPathComponent("SKILL.md"))
    let link = root.appendingPathComponent("EmblaChat/Skills")
    try FileManager.default.createDirectory(
        at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    #expect(throws: SkillFailure.self) {
        let descriptor = try SkillStore.openDirectory(link.path)
        close(descriptor)
    }
    let store = SkillStore(localRoot: link)
    await #expect(throws: (any Error).self) { try await store.entries(.device) }
    let document = try SkillDocument.decode(Data(sampleSkill.utf8), directoryName: "sample-skill")
    await #expect(throws: (any Error).self) {
        try await store.resource("SKILL.md", skill: document, source: .device)
    }
}

@Test(arguments: [false, true])
func replacingSkillDirectoriesWithLinksCannotRedirectPinnedReads(_ replaceChild: Bool) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let skills = root.appendingPathComponent("Skills")
    let child = skills.appendingPathComponent("sample-skill")
    let outside = root.appendingPathComponent("Outside/sample-skill")
    for directory in [child, outside] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    try Data("inside selected tree".utf8).write(to: child.appendingPathComponent("fact.txt"))
    try Data("outside selected tree".utf8).write(to: outside.appendingPathComponent("fact.txt"))
    let descriptor = try SkillStore.openDirectory(skills.path)
    defer { close(descriptor) }
    if replaceChild {
        try FileManager.default.moveItem(
            at: child, to: root.appendingPathComponent("OriginalSkill"))
        try FileManager.default.createSymbolicLink(at: child, withDestinationURL: outside)
        #expect(throws: SkillFailure.self) {
            try SkillStore.readRelativeFile(["sample-skill", "fact.txt"], descriptor: descriptor)
        }
    } else {
        try FileManager.default.moveItem(
            at: skills, to: root.appendingPathComponent("OriginalSkills"))
        try FileManager.default.createSymbolicLink(
            at: skills, withDestinationURL: outside.deletingLastPathComponent())
        let data = try SkillStore.readRelativeFile(
            ["sample-skill", "fact.txt"], descriptor: descriptor)
        #expect(String(decoding: data, as: UTF8.self) == "inside selected tree")
    }
}
