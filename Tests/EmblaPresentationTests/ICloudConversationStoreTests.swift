import Foundation
import Testing
@testable import EmblaCore
@testable import EmblaPresentation

private func cloudFileSnapshot(_ text: String) -> ConversationSnapshot {
    ConversationSnapshot(
        conversationID: UUID(), messages: [ChatMessage(role: .user, text: text)], compaction: .init())
}

@Test func sharedCloudRootSeparatesChatsAndPreservesPortableSkills() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let skill = root.appendingPathComponent("Skills/test-skill", isDirectory: true)
    try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
    let instructions = Data("---\nname: test-skill\ndescription: Storage fixture\n---\n".utf8)
    try instructions.write(to: skill.appendingPathComponent("SKILL.md"))
    let file = try CloudStorageLayout.prepare(in: root)
    #expect(file == root.appendingPathComponent("Chats/ActiveChat.json"))
    let snapshot = cloudFileSnapshot("chat stored separately from skills")
    try CoordinatedConversationFile.write(
        snapshot, at: file, replacing: CoordinatedConversationFile.read(at: file))
    #expect(try CloudStorageLayout.prepare(in: root) == file)
    #expect(try CoordinatedConversationFile.read(at: file).current == snapshot)
    #expect(try Data(contentsOf: skill.appendingPathComponent("SKILL.md")) == instructions)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("ActiveChat.json").path))
}

@Test func unexpectedConflictFingerprintSetCannotOverwriteCoordinatedFile() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = try CloudStorageLayout.prepare(in: root)
    let original = cloudFileSnapshot("current document")
    try CoordinatedConversationFile.write(original, at: file, replacing: .init())
    let expected = CloudConversationRead(
        current: original, conflicts: [cloudFileSnapshot("no longer current conflict set")])
    #expect(throws: CloudConversationError.self) {
        try CoordinatedConversationFile.write(
            cloudFileSnapshot("unsafe choice"), at: file, replacing: expected,
            resolvingConflicts: true)
    }
    #expect(try CoordinatedConversationFile.read(at: file).current == original)
}

/// These exercise coordinated local files, not authentication or iCloud transfer.
@Test func coordinatedDocumentRoundTripDoesNotClaimCloudUpload() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("ActiveChat.json")
    let initial = try CoordinatedConversationFile.read(at: file)
    #expect(initial.current == nil)
    let snapshot = cloudFileSnapshot("Shared chat")
    try CoordinatedConversationFile.write(snapshot, at: file, replacing: initial)
    let read = try CoordinatedConversationFile.read(at: file)
    #expect(read.current == snapshot)
    #expect(!read.uploaded)
}

@Test func staleCoordinatedWriteCannotReplaceAnotherDevicesChat() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("ActiveChat.json")
    let initial = CloudConversationRead()
    try CoordinatedConversationFile.write(cloudFileSnapshot("first"), at: file, replacing: initial)
    let staleRead = try CoordinatedConversationFile.read(at: file)
    let newer = cloudFileSnapshot("newer device version")
    try CoordinatedConversationFile.write(newer, at: file, replacing: staleRead)
    #expect(throws: CloudConversationError.self) {
        try CoordinatedConversationFile.write(
            cloudFileSnapshot("outdated overwrite"), at: file, replacing: staleRead)
    }
    #expect(try CoordinatedConversationFile.read(at: file).current == newer)
}

@Test func changedContentIsDetectedEvenWhenRevisionIDWasNotUpdated() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("ActiveChat.json")
    let original = cloudFileSnapshot("original")
    try CoordinatedConversationFile.write(original, at: file, replacing: .init())
    let staleRead = try CoordinatedConversationFile.read(at: file)
    var externalEdit = original
    externalEdit.messages[0].text = "edited by another client"
    try externalEdit.encodedDocument().write(to: file, options: .atomic)
    #expect(throws: CloudConversationError.self) {
        try CoordinatedConversationFile.write(original, at: file, replacing: staleRead)
    }
    #expect(try CoordinatedConversationFile.read(at: file).current == externalEdit)
}

@Test func corruptCloudDocumentIsNotTreatedAsAnEmptyDestination() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("ActiveChat.json")
    let corrupt = Data("damaged cloud file".utf8)
    try corrupt.write(to: file)
    #expect(throws: DecodingError.self) { try CoordinatedConversationFile.read(at: file) }
    #expect(throws: DecodingError.self) {
        try CoordinatedConversationFile.write(cloudFileSnapshot("local"), at: file, replacing: .init())
    }
    #expect(try Data(contentsOf: file) == corrupt)
}
