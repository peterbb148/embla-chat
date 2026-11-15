import EmblaCore
import Foundation
import Testing

@testable import EmblaPresentation

@MainActor
private func projectModel(root: URL) async throws -> LocalInferenceModel {
    let model = LocalInferenceModel(
        repository: nil, manifest: try ModelManifest.bundled(),
        session: InferenceSession { _, _ in throw InferenceError.modelNotDownloaded },
        chatStore: ConversationStore(root: root))
    model.check()
    await model.waitUntilIdle()
    return model
}

@Test @MainActor
func explicitProjectMemoryKeepsAttributionAndEditsAcrossRestart() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = ChatMessage(role: .user, text: "Synthetic source: use BLUE PENGUIN.")
    let chat = ConversationSnapshot(conversationID: UUID(), messages: [source], compaction: .init())
    try await ConversationStore(root: root).save(ConversationArchive(sequence: 1, snapshot: chat))
    let model = try await projectModel(root: root)
    let projectID = try await model.createProject(name: "Planning")
    try await model.moveChat(chat.conversationID, to: projectID)
    #expect(model.projects.first?.memory.isEmpty == true)  // Assignment never extracts facts.
    try await model.saveProjectMemory(
        projectID: projectID, text: "Use BLUE PENGUIN.",
        sourceChatID: chat.conversationID, sourceMessageID: source.id)
    let entry = try #require(model.projects.first?.memory.first)
    #expect(entry.sourceConversationID == chat.conversationID && entry.sourceMessageID == source.id)
    try await model.editProjectMemory(
        projectID: projectID, entryID: entry.id, text: "  Use RED FOX now.\n")
    try await model.renameProject(projectID, name: "Revised planning")
    let reopened = try await projectModel(root: root)
    let restored = try #require(reopened.activeProject?.memory.first)
    #expect(restored.id == entry.id && restored.sourceMessageID == source.id)
    #expect(
        restored.text == "  Use RED FOX now.\n" && reopened.activeProject?.name == "Revised planning")
    #expect(!reopened.cloud.enabled)
    try await reopened.removeProjectMemory(projectID: projectID)
    #expect(reopened.activeProject?.memory.isEmpty == true)
    #expect(reopened.messages == chat.messages)
    #expect(try await ConversationStore(root: root).load()?.projects?.first?.memory.isEmpty == true)
}

@Test @MainActor
func failedProjectSavePreservesVisibleAndDurableMemory() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let backup = root.appendingPathExtension("backup")
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: backup)
    }
    let model = try await projectModel(root: root)
    let projectID = try await model.createProject(name: "Keep this project")
    let before = model.projects
    try FileManager.default.moveItem(at: root, to: backup)
    try Data("Blocked storage fixture".utf8).write(to: root)
    await #expect(throws: (any Error).self) {
        try await model.renameProject(projectID, name: "Must not appear")
    }
    #expect(model.projects == before && !model.busy && model.storageError != nil)
    #expect(try await ConversationStore(root: backup).load()?.projects == before)
}

@Test @MainActor
func projectAssignmentKeepsIndependentDraftsAndDoesNotTransferSavedNotes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = ChatMessage(role: .user, text: "Synthetic retained fact")
    let first = ConversationSnapshot(
        conversationID: UUID(), messages: [source], compaction: .init())
    try await ConversationStore(root: root).save(
        ConversationArchive(sequence: 1, snapshot: first, draft: "Original local draft"))
    let model = try await projectModel(root: root)
    let a = try await model.createProject(name: "A")
    let b = try await model.createProject(name: "B")
    try await model.moveChat(first.conversationID, to: a)
    try await model.saveProjectMemory(
        projectID: a, text: "Synthetic retained fact",
        sourceChatID: first.conversationID, sourceMessageID: source.id)
    model.newChat(in: a)
    await model.waitUntilIdle()
    let second = model.conversationID
    model.prompt = "Second draft"
    try await model.moveChat(first.conversationID, to: b)
    #expect(model.projects.first(where: { $0.id == a })?.memory.count == 1)
    #expect(model.projects.first(where: { $0.id == b })?.memory.isEmpty == true)
    model.selectChat(first.conversationID)
    await model.waitUntilIdle()
    #expect(model.activeProjectID == b && model.prompt == "Original local draft")
    #expect(model.history.first(where: { $0.id == second })?.draft == "Second draft")
    await #expect(throws: ProjectError.self) {
        try await model.saveProjectMemory(
            projectID: a, text: "Wrong destination",
            sourceChatID: first.conversationID, sourceMessageID: source.id)
    }
}

@Test func projectLibraryRejectsBrokenAttributionAndMigratesVersionTwo() throws {
    let source = ChatMessage(role: .user, text: "Synthetic source")
    let project = ChatProject(
        name: "Project",
        memory: [
            ProjectMemoryEntry(
                text: "A note", sourceConversationID: UUID(), sourceMessageID: source.id)
        ])
    let chat = ConversationSnapshot(
        conversationID: UUID(), messages: [source], compaction: .init(),
        projectID: project.id)
    #expect(throws: ConversationStorageError.self) {
        try ConversationLibrary(chats: [chat], projects: [project]).validate()
    }
    var legacy = ConversationSnapshot(
        conversationID: UUID(), messages: [source], compaction: .init())
    legacy.projectID = nil
    let chatJSON = String(decoding: try legacy.encodedDocument(), as: UTF8.self)
    let old = Data("{\"formatVersion\":2,\"chats\":[\(chatJSON)]}".utf8)
    let migrated = try JSONDecoder().decode(ConversationLibrary.self, from: old)
    #expect(migrated.formatVersion == 3 && migrated.projects.isEmpty && migrated.chats == [legacy])
}

@Test @MainActor
func cancelledProjectEditDoesNotCommitChanges() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try await projectModel(root: root)
    let original = try await ConversationStore(root: root).load()
    let edit = Task { try await model.createProject(name: "Cancelled project") }
    edit.cancel()
    await #expect(throws: CancellationError.self) { try await edit.value }
    #expect(model.projects.isEmpty && !model.busy)
    #expect(try await ConversationStore(root: root).load() == original)
}
