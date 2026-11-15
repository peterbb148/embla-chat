import Foundation
import Testing
@testable import EmblaCore
@testable import EmblaPresentation

private func cloudFileSnapshot(_ text: String) -> ConversationSnapshot {
    ConversationSnapshot(
        conversationID: UUID(), messages: [ChatMessage(role: .user, text: text)], compaction: .init())
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
