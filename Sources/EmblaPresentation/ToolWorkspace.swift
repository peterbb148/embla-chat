import Foundation
import Observation

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
    @ObservationIgnored private var setupError: String?
    @ObservationIgnored private let credentials: any MCPCredentialStoring
    @ObservationIgnored private var skillTask: Task<Void, Never>?
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var clients: [UUID: MCPClient] = [:]
    @ObservationIgnored private var skillRequestID = UUID()
    @ObservationIgnored private var connectRequestID = UUID()

    public init() {
        credentials = MCPCredentials()
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
            try readConfiguration()
        } catch {
            configuration = nil
            setupError = error.localizedDescription
            self.error = error.localizedDescription
        }
    }

    /// Internal fixtures must opt into their own storage; they never read real device settings.
    init(
        store: SkillStore? = nil, configuration: URL? = nil,
        credentials: any MCPCredentialStoring = MCPCredentials()
    ) {
        self.credentials = credentials
        self.store = store
        self.configuration = configuration
        do { try readConfiguration() } catch {
            self.configuration = nil
            setupError = error.localizedDescription
            self.error = error.localizedDescription
        }
    }

    private func readConfiguration() throws {
        guard let configuration, FileManager.default.fileExists(atPath: configuration.path) else {
            return
        }
        let loaded = try JSONDecoder().decode(
            [MCPServer].self, from: Data(contentsOf: configuration))
        guard Set(loaded.map(\.id)).count == loaded.count else {
            throw SkillFailure.invalid("Duplicate MCP server IDs in local settings.")
        }
        for server in loaded { try server.validate() }
        servers = loaded
    }

    public func reloadSkills(using cloud: ConversationCloudSync) {
        skillTask?.cancel()
        skillTask = nil
        loadingSkills = false
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
        if let setupError {
            throw SkillFailure.invalid("MCP settings are unreadable: " + setupError)
        }
        let expected = revision
        _ = try await validateSkill(using: cloud)
        guard revision == expected else { throw SkillFailure.changed }
        for server in servers where !server.enabledTools.isEmpty && clients[server.id] == nil {
            try Task.checkCancellation()
            let client = try MCPClient(
                server: server, bearerToken: credentials.read(MCPCredentialID(server: server)))
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
        let previous = servers.first(where: { $0.id == server.id })
        if let previous, previous.endpoint != server.endpoint { server.enabledTools = [] }
        if let newToken { try credentials.write(newToken, id: MCPCredentialID(server: server)) }
        if let index = updated.firstIndex(where: { $0.id == server.id }) {
            updated[index] = server
        } else {
            updated.append(server)
        }
        try JSONEncoder().encode(updated).write(to: configuration, options: .atomic)
        servers = updated
        if let previous, previous.endpoint != server.endpoint {
            try credentials.deleteEndpoint(MCPCredentialID(server: previous))
        }
        clients[server.id] = nil
        discovered[server.id] = nil
        revision = UUID()
    }

    public func removeServer(_ id: UUID) throws {
        guard let configuration else {
            throw SkillFailure.invalid("MCP settings storage is unavailable.")
        }
        try credentials.deleteAll(id)
        let updated = servers.filter { $0.id != id }
        try JSONEncoder().encode(updated).write(to: configuration, options: .atomic)
        servers = updated
        clients[id] = nil
        discovered[id] = nil
        revision = UUID()
    }

    public func clearCredential(_ id: UUID) throws {
        try credentials.deleteAll(id)
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
                let client = try MCPClient(
                    server: server, bearerToken: credentials.read(MCPCredentialID(server: server)))
                let result = try await client.discover()
                try Task.checkCancellation()
                guard revision == current else { throw SkillFailure.changed }
                discovered[id] = result.tools
                clients[id] = client
                warnings = result.warnings
                revision = UUID()
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }

    public func setEnabled(_ enabled: Bool, tool: String, serverID: UUID) throws {
        guard let configuration,
            let index = servers.firstIndex(where: { $0.id == serverID })
        else { throw SkillFailure.changed }
        if enabled {
            guard discovered[serverID]?.contains(where: { $0.name == tool }) == true else {
                throw SkillFailure.changed
            }
        }
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

    public func visibleToolNames(for serverID: UUID) -> [String] {
        let saved = servers.first(where: { $0.id == serverID })?.enabledTools ?? []
        return saved.union(Set((discovered[serverID] ?? []).map(\.name))).sorted()
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

    /// Enabled tools need discovered schemas (reconnected on Send); credentials never enter context.
    func remoteTools() throws -> [ModelToolSpecification] {
        if let setupError {
            throw SkillFailure.invalid("MCP settings are unreadable: " + setupError)
        }
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
