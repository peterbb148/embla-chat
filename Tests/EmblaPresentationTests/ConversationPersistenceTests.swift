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

@Test func historyRoundTripRecoversEveryChatAndRejectsDuplicateIdentities() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var archive = savedFixture()
    let earlier = savedFixture()
    archive.history = [SavedConversation(snapshot: earlier.snapshot, draft: "Earlier local draft")]
    let store = ConversationStore(root: root)
    try await store.save(archive)
    let reopened = try #require(try await store.load()).recoveringInterruptedResponses()
    #expect(reopened.snapshot.messages.last?.state == .interrupted)
    #expect(reopened.history?.first?.snapshot.messages.last?.state == .interrupted)
    #expect(reopened.history?.first?.draft == "Earlier local draft")
    #expect(reopened.history?.first?.snapshot.compaction == earlier.snapshot.compaction)
    let portable = String(decoding: try archive.library.encodedDocument(), as: UTF8.self)
    #expect(!portable.contains("Earlier local draft") && !portable.contains(archive.draft))
    archive.history = [SavedConversation(snapshot: archive.snapshot)]
    archive.sequence += 1
    await #expect(throws: ConversationStorageError.self) { try await store.save(archive) }
    #expect(try await store.load()?.history?.first?.snapshot == earlier.snapshot)
}

@Test func legacySingleChatCloudDocumentMigratesWithoutDroppingItsContext() throws {
    let legacy = savedFixture().snapshot
    let bytes = try legacy.encodedDocument()
    let migrated = try JSONDecoder().decode(ConversationLibrary.self, from: bytes)
    #expect(migrated.formatVersion == 2 && migrated.chats == [legacy])
    let roundTrip = try JSONDecoder().decode(
        ConversationLibrary.self, from: migrated.encodedDocument())
    #expect(roundTrip == migrated)
    // A malformed library must never be retried as a legacy single chat.
    let invalid = Data("{\"formatVersion\":2,\"chats\":false}".utf8)
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(ConversationLibrary.self, from: invalid)
    }
}
