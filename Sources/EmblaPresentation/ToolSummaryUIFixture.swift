#if DEBUG
import Foundation

import EmblaCore
import EmblaRuntime

extension LocalInferenceModel {
    /// Explicit, isolated saved-history fixture; never substitutes a generation backend.
    public static func toolSummaryUIFixture(
        id: UUID, network: NetworkAccess, includeMCPSettings: Bool = false,
        tallToolResult: Bool = false, transcriptScroll: Bool = false
    ) throws
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
            if tallToolResult {
                result.text += String(repeating: "\nSynthetic tool response evidence line.", count: 100)
            }
            result.toolName = "synthetic_lookup"
            result.toolResultSummary = "The source reports BLUE PENGUIN (https://example.com/fact)."
            var messages = [ChatMessage(role: .user, text: "Synthetic tool-summary UI fixture.")]
            if !transcriptScroll {
                messages.append(result)
                messages.append(
                    ChatMessage(role: .assistant, text: "BLUE PENGUIN — https://example.com/fact"))
            }
            let archive = ConversationArchive(
                sequence: 1,
                snapshot: ConversationSnapshot(
                    conversationID: UUID(), messages: messages, compaction: .init()))
            try archive.validate()
            try JSONEncoder().encode(archive).write(to: file, options: .atomic)
        }
        let manifest = try ModelManifest.bundled()
        let configuration = root.appendingPathComponent("servers.json")
        if includeMCPSettings && !FileManager.default.fileExists(atPath: configuration.path) {
            var server = MCPServer(
                name: "Synthetic search server", endpoint: URL(string: "https://example.invalid/mcp")!,
                enabledTools: ["search", "research"], enableToolsOnFirstDiscovery: false)
            server.lastDiscoveredTools = try ["search", "research"].map {
                try MCPTool(
                    name: $0, description: "Synthetic \($0) catalogue description.",
                    inputSchema: .object(["type": .string("object"), "properties": .object([:])]))
            }
            try JSONEncoder().encode([server]).write(to: configuration, options: .atomic)
        }
        let tools = ToolWorkspace(configuration: configuration, network: network)
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
