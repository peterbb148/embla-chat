import Foundation
import Observation
import Security

import EmblaCore

/// Device-only MCP configuration and explicit skill selection. No server is enabled by default.
@MainActor @Observable
public final class ToolWorkspace {
    public private(set) var skills: [SkillEntry] = []
    public private(set) var selectedSkill: SkillDocument?
    public private(set) var servers: [MCPServer] = []
    public private(set) var discovered: [UUID: [MCPTool]] = [:]
    public private(set) var warnings: [String] = []
    public private(set) var error: String?
    public private(set) var loadingSkills = false
    public private(set) var connecting: UUID?
    public private(set) var revision = UUID()
    public private(set) var skillSourceKey: String?
    @ObservationIgnored private var store: SkillStore?
    @ObservationIgnored private var configuration: URL?
    @ObservationIgnored private var skillTask: Task<Void, Never>?
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var clients: [UUID: MCPClient] = [:]
    @ObservationIgnored private var skillRequestID = UUID()
    @ObservationIgnored private var connectRequestID = UUID()

    public init() {
        do {
            let files = FileManager.default
            let documents = try files.url(
                for: .documentDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
            var support = try files.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            ).appendingPathComponent("EmblaChat/ToolSettings")
            try files.createDirectory(at: support, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try support.setResourceValues(values)
            store = SkillStore(localRoot: documents.appendingPathComponent("Skills"))
            configuration = support.appendingPathComponent("servers.json")
            if let configuration, files.fileExists(atPath: configuration.path) {
                let loaded = try JSONDecoder().decode(
                    [MCPServer].self,
                    from: Data(contentsOf: configuration))
                guard Set(loaded.map(\.id)).count == loaded.count else {
                    throw SkillFailure.invalid("Duplicate MCP server IDs in local settings.")
                }
                for server in loaded { try server.validate() }
                servers = loaded
            }
        } catch {
            configuration = nil
            self.error = error.localizedDescription
        }
    }

    /// Internal fixtures must opt into their own storage; they never read real device settings.
    init(store: SkillStore? = nil, configuration: URL? = nil) {
        self.store = store
        self.configuration = configuration
    }

    public func reloadSkills(using cloud: ConversationCloudSync) {
        skillTask?.cancel()
        selectedSkill = nil
        skills = []
        skillSourceKey = nil
        revision = UUID()
        skillRequestID = UUID()
        let current = skillRequestID
        let key = QuickActionsModel.sourceKey(for: cloud)
        guard let store else { return }
        do {
            let source = try source(cloud)
            loadingSkills = true
            skillTask = Task {
                defer { if skillRequestID == current { loadingSkills = false; skillTask = nil } }
                do {
                    let entries = try await store.entries(source)
                    try Task.checkCancellation()
                    guard skillRequestID == current, QuickActionsModel.sourceKey(for: cloud) == key
                    else { return }
                    skills = entries
                    skillSourceKey = key
                } catch {
                    guard skillRequestID == current, !Task.isCancelled else { return }
                    self.error = error.localizedDescription
                }
            }
        } catch { self.error = error.localizedDescription }
    }

    public func selectSkill(_ name: String?, using cloud: ConversationCloudSync) throws {
        guard !loadingSkills, skillSourceKey == QuickActionsModel.sourceKey(for: cloud) else {
            throw SkillFailure.changed
        }
        if let name {
            guard let skill = skills.first(where: { $0.id == name })?.document else {
                throw SkillFailure.invalid("The selected skill is unavailable or invalid.")
            }
            selectedSkill = skill
        } else {
            selectedSkill = nil
        }
        revision = UUID()
    }

    public func clearSkill() { selectedSkill = nil; revision = UUID() }

    /// Re-reads the exact selected file before any generation can consume its instructions.
    func validateSkill(using cloud: ConversationCloudSync) async throws -> SkillDocument? {
        guard let selectedSkill else { return nil }
        guard let store, skillSourceKey == QuickActionsModel.sourceKey(for: cloud) else {
            throw SkillFailure.changed
        }
        let entries = try await store.entries(try source(cloud))
        guard self.selectedSkill == selectedSkill,
            skillSourceKey == QuickActionsModel.sourceKey(for: cloud),
            entries.first(where: { $0.id == selectedSkill.name })?.document == selectedSkill
        else {
            throw SkillFailure.changed
        }
        return selectedSkill
    }

    /// User registration/enabling authorizes reconnecting for a submitted message, not at startup.
    func prepare(using cloud: ConversationCloudSync) async throws {
        let expected = revision
        _ = try await validateSkill(using: cloud)
        guard revision == expected else { throw SkillFailure.changed }
        for server in servers where !server.enabledTools.isEmpty && clients[server.id] == nil {
            try Task.checkCancellation()
            let client = try MCPClient(server: server, bearerToken: MCPCredentials.read(server.id))
            let result = try await client.discover()
            try Task.checkCancellation()
            guard revision == expected else { throw SkillFailure.changed }
            discovered[server.id] = result.tools
            clients[server.id] = client
            warnings = result.warnings
        }
    }

    func readResource(_ path: String, skill: SkillDocument, using cloud: ConversationCloudSync)
        async throws -> String
    {
        guard let store, selectedSkill == skill,
            skillSourceKey == QuickActionsModel.sourceKey(for: cloud)
        else { throw SkillFailure.changed }
        return try await store.resource(path, skill: skill, source: source(cloud))
    }

    private func source(_ cloud: ConversationCloudSync) throws -> QuickActionSource {
        guard cloud.enabled else { return .device }
        guard !cloud.requiresScopeConsent, let bookmark = cloud.authorizedFolderBookmark else {
            throw SkillFailure.unavailable
        }
        return .cloud(bookmark)
    }

    public func saveServer(_ server: MCPServer, newToken: String? = nil) throws {
        try server.validate()
        guard let configuration else {
            throw SkillFailure.invalid("MCP settings storage is unavailable.")
        }
        var updated = servers
        var server = server
        clients[server.id] = nil
        discovered[server.id] = nil
        revision = UUID()
        if let old = servers.first(where: { $0.id == server.id }), old.endpoint != server.endpoint {
            server.enabledTools = []
            try MCPCredentials.delete(server.id)
        }
        if let newToken { try MCPCredentials.write(newToken, id: server.id) }
        if let index = updated.firstIndex(where: { $0.id == server.id }) {
            updated[index] = server
        } else {
            updated.append(server)
        }
        try JSONEncoder().encode(updated).write(to: configuration, options: .atomic)
        servers = updated
        clients[server.id] = nil
        discovered[server.id] = nil
        revision = UUID()
    }

    public func removeServer(_ id: UUID) throws {
        guard let configuration else {
            throw SkillFailure.invalid("MCP settings storage is unavailable.")
        }
        try MCPCredentials.delete(id)
        let updated = servers.filter { $0.id != id }
        try JSONEncoder().encode(updated).write(to: configuration, options: .atomic)
        servers = updated
        clients[id] = nil
        discovered[id] = nil
        revision = UUID()
    }

    public func clearCredential(_ id: UUID) throws {
        try MCPCredentials.delete(id)
        clients[id] = nil
        discovered[id] = nil
        revision = UUID()
    }

    public func discover(_ id: UUID) {
        connectTask?.cancel()
        guard let server = servers.first(where: { $0.id == id }) else { return }
        clients[id] = nil
        discovered[id] = nil
        revision = UUID()
        connectRequestID = UUID()
        let request = connectRequestID
        connecting = id
        error = nil
        let current = revision
        connectTask = Task {
            defer { if connectRequestID == request { connecting = nil; connectTask = nil } }
            do {
                let client = try MCPClient(server: server, bearerToken: MCPCredentials.read(id))
                let result = try await client.discover()
                try Task.checkCancellation()
                guard revision == current else { throw SkillFailure.changed }
                discovered[id] = result.tools
                clients[id] = client
                warnings = result.warnings
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }

    public func setEnabled(_ enabled: Bool, tool: String, serverID: UUID) throws {
        guard let configuration,
            let index = servers.firstIndex(where: { $0.id == serverID }),
            discovered[serverID]?.contains(where: { $0.name == tool }) == true
        else { throw SkillFailure.changed }
        var updated = servers
        if enabled {
            updated[index].enabledTools.insert(tool)
        } else {
            updated[index].enabledTools.remove(tool)
        }
        try JSONEncoder().encode(updated).write(to: configuration, options: .atomic)
        servers = updated
        revision = UUID()
    }

    public func pause() {
        skillTask?.cancel(); connectTask?.cancel()
        skillRequestID = UUID(); connectRequestID = UUID()
        selectedSkill = nil
        skills = []
        skillSourceKey = nil
        loadingSkills = false
        connecting = nil
        clients = [:]
        discovered = [:]
        revision = UUID()
    }

    /// Enabled tools require fresh explicit connection after launch; credentials never enter context.
    func remoteTools() throws -> [ModelToolSpecification] {
        var result: [ModelToolSpecification] = []
        guard Set(servers.map(\.modelID)).count == servers.count else {
            throw SkillFailure.invalid(
                "MCP catalog identifiers collide. Remove and re-add one server.")
        }
        for server in servers where !server.enabledTools.isEmpty {
            guard let tools = discovered[server.id], clients[server.id] != nil,
                server.enabledTools.isSubset(of: Set(tools.map(\.name)))
            else {
                throw SkillFailure.invalid(
                    "Tool schemas for '\(server.name)' are unavailable. Send to reconnect or connect in Settings; missing enabled tools require configuration changes."
                )
            }
            result += tools.filter { server.enabledTools.contains($0.name) }.map {
                ModelToolSpecification(
                    server: server.modelID, name: $0.name,
                    description: $0.description, inputSchema: $0.inputSchema)
            }
        }
        return result
    }

    func remoteCall(serverID: UUID, name: String, arguments: [String: ToolJSON]) async throws
        -> ToolJSON
    {
        guard let server = servers.first(where: { $0.id == serverID }),
            server.enabledTools.contains(name), let client = clients[serverID],
            let tool = discovered[serverID]?.first(where: { $0.name == name })
        else {
            throw SkillFailure.changed
        }
        return try await client.call(tool, arguments: arguments)
    }

    func waitUntilIdle() async {
        await skillTask?.value
        await connectTask?.value
    }
}

/// Non-synchronizing Keychain entries remain on this device and never enter copied files/chat data.
enum MCPCredentials {
    private static func query(_ id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dk.peterbb148.embla-chat.mcp",
            kSecAttrAccount as String: id.uuidString,
            kSecAttrSynchronizable as String: false,
        ]
    }

    static func read(_ id: UUID) throws -> String? {
        var query = query(id)
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
            let value = String(data: data, encoding: .utf8)
        else { throw MCPFailure.credential }
        return value
    }

    static func write(_ value: String, id: UUID) throws {
        guard !value.isEmpty, value.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw MCPFailure.credential
        }
        let base = query(id)
        let updates = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(base as CFDictionary, updates as CFDictionary)
        if status == errSecItemNotFound {
            var item = base
            item[kSecValueData as String] = Data(value.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw MCPFailure.credential
            }
        } else if status != errSecSuccess {
            throw MCPFailure.credential
        }
    }

    static func delete(_ id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MCPFailure.credential
        }
    }
}
