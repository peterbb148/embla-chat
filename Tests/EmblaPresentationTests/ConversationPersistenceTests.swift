import Foundation
import Testing
@testable import EmblaCore
@testable import EmblaPresentation

private func savedFixture() -> ConversationArchive {
    ConversationArchive(
        sequence: 1,
        snapshot: ConversationSnapshot(
            conversationID: UUID(),
            messages: [
                ChatMessage(role: .user, text: "Original requirement"),
                ChatMessage(role: .assistant, text: "Earlier answer"),
                ChatMessage(role: .user, text: "Continue"),
                ChatMessage(role: .assistant, text: "Partial reply", state: .streaming),
            ],
            compaction: CompactionState(summary: "Original requirement", summarizedMessageCount: 2)),
        draft: "Unsent local draft")
}

@Test func chatArchiveRoundTripPreservesStableIDsSummaryAndLocalOnlyDefault() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let original = savedFixture()
    try await ConversationStore(root: root).save(original)
    let reopened = try await ConversationStore(root: root).load()
    #expect(reopened == original)
    #expect(reopened?.cloudEnabled == false)
    #expect(reopened?.cloudFolderBookmark == nil)
    let values = try root.resourceValues(forKeys: [.isExcludedFromBackupKey])
    #expect(values.isExcludedFromBackup == true)
    let cloudBytes = try JSONEncoder().encode(original.snapshot)
    #expect(!String(decoding: cloudBytes, as: UTF8.self).contains("Unsent local draft"))
}

@Test func restorationMarksStreamingAsInterruptedWithoutLosingPartialOutput() {
    let original = savedFixture()
    let restored = original.recoveringInterruptedResponses()
    #expect(restored.snapshot.messages.last?.state == .interrupted)
    #expect(restored.snapshot.messages.last?.text == "Partial reply")
    #expect(restored.snapshot.messages.map(\.id) == original.snapshot.messages.map(\.id))
    #expect(restored.snapshot.compaction == original.snapshot.compaction)
    #expect(restored.sequence == original.sequence + 1)
    #expect(restored.recoveringInterruptedResponses() == restored)
}

@Test func delayedSaveCannotResurrectTheChatAfterNewChat() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ConversationStore(root: root)
    let older = savedFixture()
    try await store.save(older)
    let reset = ConversationArchive(
        sequence: 2,
        snapshot: ConversationSnapshot(conversationID: UUID(), messages: [], compaction: .init()))
    try await store.save(reset)
    await #expect(throws: ConversationStorageError.self) { try await store.save(older) }
    #expect(try await store.load() == reset)
}

@Test func corruptOrIncompatibleArchiveIsNeverReplacedWithAnEmptyChat() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ConversationStore(root: root)
    #expect(try await store.load() == nil)
    var archive = savedFixture()
    archive.snapshot.compaction.summarizedMessageCount = 100
    await #expect(throws: ConversationStorageError.self) { try await store.save(archive) }
    archive = savedFixture()
    archive.snapshot.formatVersion = 2
    await #expect(throws: ConversationStorageError.self) { try await store.save(archive) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let corrupt = Data("not JSON".utf8)
    let file = root.appendingPathComponent("active-chat.json")
    try corrupt.write(to: file)
    await #expect(throws: DecodingError.self) { try await store.load() }
    #expect(try Data(contentsOf: file) == corrupt)
}

@Test func localSaveFailureDoesNotReportSuccessOrReplaceExistingData() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let existing = Data("A file occupies the required directory".utf8)
    try existing.write(to: root)
    await #expect(throws: (any Error).self) {
        try await ConversationStore(root: root).save(savedFixture())
    }
    #expect(try Data(contentsOf: root) == existing)
}
