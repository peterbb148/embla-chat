#if DEBUG
import Foundation

import EmblaCore
import EmblaRuntime

extension LocalInferenceModel {
    /// Explicit, isolated saved-history fixture; never substitutes a generation backend.
    public static func toolSummaryUIFixture(id: UUID, network: NetworkAccess) throws
        -> (model: LocalInferenceModel, actions: QuickActionsModel)
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmblaToolSummaryUI/" + id.uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let chatRoot = root.appendingPathComponent("Chats")
        try FileManager.default.createDirectory(at: chatRoot, withIntermediateDirectories: true)
        let file = chatRoot.appendingPathComponent("active-chat.json")
        if !FileManager.default.fileExists(atPath: file.path) {
            var result = ChatMessage(
                role: .assistant,
                text: "Synthetic complete original result: ORIGINAL_RESULT_RETAINED. The codename is BLUE PENGUIN. Source: https://example.com/fact")
            result.toolName = "synthetic_lookup"
            result.toolResultSummary = "The source reports BLUE PENGUIN (https://example.com/fact)."
            let archive = ConversationArchive(
                sequence: 1,
                snapshot: ConversationSnapshot(
                    conversationID: UUID(), messages: [
                        ChatMessage(role: .user, text: "Synthetic tool-summary UI fixture."), result,
                        ChatMessage(role: .assistant, text: "BLUE PENGUIN — https://example.com/fact"),
                    ], compaction: .init()))
            try archive.validate()
            try JSONEncoder().encode(archive).write(to: file, options: .atomic)
        }
        let manifest = try ModelManifest.bundled()
        let tools = ToolWorkspace(configuration: root.appendingPathComponent("servers.json"), network: network)
        let model = LocalInferenceModel(
            repository: ModelRepository(root: root.appendingPathComponent("Model"), manifest: manifest),
            manifest: manifest, session: EmblaRuntime.makeSession(),
            chatStore: ConversationStore(root: chatRoot), tools: tools)
        let actions = QuickActionsModel(storage: QuickActionStore(
            localRoot: root.appendingPathComponent("Actions"),
            stateRoot: root.appendingPathComponent("ActionState"), network: network))
        return (model, actions)
    }
}
#endif
