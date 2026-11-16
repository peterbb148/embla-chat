import Foundation

import EmblaCore

/// Exact call snapshot for an explicitly registered/enabled tool; annotations grant no permissions.
public struct ToolInvocation: Sendable {
    public let server: String
    public let name: String
    public let destination: String
    public let arguments: [String: ToolJSON]
    public let local: Bool

}

extension ToolWorkspace {
    func specifications(using cloud: ConversationCloudSync) throws -> [ModelToolSpecification] {
        var specifications = try remoteTools()
        if selectedSkill != nil {
            guard skillSourceKey == QuickActionsModel.sourceKey(for: cloud) else {
                throw SkillFailure.changed
            }
            specifications.append(
                ModelToolSpecification(
                    server: "skill", name: "read_skill_file",
                    description:
                        "Read a UTF-8 supporting file inside the selected skill by relative path. No scripts or commands can execute.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object(["path": .object(["type": .string("string")])]),
                        "required": .array([.string("path")]), "additionalProperties": .bool(false),
                    ])))
        }
        return specifications
    }

    func instructions(using cloud: ConversationCloudSync) throws -> String {
        let specifications = try specifications(using: cloud)
        var text = ""
        if !specifications.isEmpty {
            text += "\n" + (try ModelToolResponse.instructions(tools: specifications))
        }
        if let selectedSkill { text += "\n\n" + selectedSkill.context }
        return text
    }

    func invocation(server: String, name: String, arguments: [String: ToolJSON]) throws
        -> ToolInvocation
    {
        if server == "skill", name == "read_skill_file", selectedSkill != nil {
            guard Set(arguments.keys) == ["path"], arguments["path"]?.string != nil else {
                throw ToolProtocolError.invalidResponse
            }
            return ToolInvocation(
                server: server, name: name, destination: "Selected skill folder",
                arguments: arguments, local: true)
        }
        guard let configured = servers.first(where: { $0.modelID == server }),
            configured.enabledTools.contains(name),
            discovered[configured.id]?.contains(where: { $0.name == name }) == true
        else { throw ToolProtocolError.invalidResponse }
        return ToolInvocation(
            server: server, name: name, destination: configured.endpoint.absoluteString,
            arguments: arguments, local: false)
    }

    func execute(_ request: ToolInvocation, using cloud: ConversationCloudSync) async throws
        -> ToolJSON
    {
        if request.local {
            guard let selectedSkill, let path = request.arguments["path"]?.string else {
                throw SkillFailure.changed
            }
            return .object([
                "text": .string(try await readResource(path, skill: selectedSkill, using: cloud))
            ])
        }
        guard let server = servers.first(where: { $0.modelID == request.server }),
            server.endpoint.absoluteString == request.destination
        else { throw SkillFailure.changed }
        return try await remoteCall(
            serverID: server.id, name: request.name, arguments: request.arguments)
    }
}
