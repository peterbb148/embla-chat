import Foundation
import Observation

import EmblaCore

/// Opaque editor baseline: no raw credential is exposed to the view.
public struct MCPServerEditBaseline: Equatable, Sendable {
    fileprivate let serverID: UUID
    fileprivate let source: String?
    fileprivate let fingerprint: String?
}

/// MCP configuration follows the explicit global storage choice; discovery remains device-local.
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
    public private(set) var settingsError: String?
    public private(set) var settingsChoices: [String] = []
    public private(set) var settingsStatus = "Settings are stored on this device."
    public private(set) var settingsLoading = false
    public var settingsWriting: Bool {
        settingsWriteID != nil && settingsWriteSource == settingsSourceKey
    }
    private var settingsWriteID: UUID?
    private var settingsWriteSource: String?
    @ObservationIgnored private var settingsRequestID = UUID()
    @ObservationIgnored private var sharedDocument: SharedSettings?
    @ObservationIgnored private var settingsChoiceDocuments: [SharedSettings] = []
    @ObservationIgnored private var shared: SharedSettingsSession?
    @ObservationIgnored private var sharedAccess: SettingsAccessLease?
    @ObservationIgnored private var settingsFactory: (Data) -> any SharedSettingsStoring = {
        SharedSettingsFile(bookmark: $0)
    }
    @ObservationIgnored private var sharedRequested = false
    @ObservationIgnored private var settingsSourceKey: String?
    @ObservationIgnored private var currentSourceKey: (() -> String)?
    @ObservationIgnored private var preferredSkill: String?
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
            setupError = error.localizedDescription
            self.error = error.localizedDescription
        }
    }

    /// Internal fixtures must opt into their own storage; they never read real device settings.
    init(
        store: SkillStore? = nil, configuration: URL? = nil,
        credentials: any MCPCredentialStoring = MCPCredentials(),
        settingsFactory: @escaping (Data) -> any SharedSettingsStoring = {
            SharedSettingsFile(bookmark: $0)
        }
    ) {
        self.credentials = credentials
        self.settingsFactory = settingsFactory
        self.store = store
        self.configuration = configuration
        do { try readConfiguration() } catch {
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
        selectedSkill = nil
        skills = []
        skillSourceKey = nil
        revision = UUID()
        skillRequestID = UUID()
        let current = skillRequestID
        let key = QuickActionsModel.sourceKey(for: cloud)
        loadingSkills = true
        skillTask = Task {
            defer { if skillRequestID == current { loadingSkills = false; skillTask = nil } }
            do {
                await reloadSettings(using: cloud)
                try Task.checkCancellation()
                guard skillRequestID == current, QuickActionsModel.sourceKey(for: cloud) == key
                else { return }
                try requireSettingsReady()
                guard let store else { return }
                let entries = try await store.entries(source(cloud))
                try Task.checkCancellation()
                guard skillRequestID == current, QuickActionsModel.sourceKey(for: cloud) == key
                else { return }
                skills = entries
                skillSourceKey = key
                if let name = preferredSkill {
                    guard let skill = entries.first(where: { $0.id == name })?.document else {
                        throw SkillFailure.invalid(
                            "The saved selected skill is unavailable or invalid.")
                    }
                    selectedSkill = skill
                }
                revision = UUID()
            } catch {
                guard skillRequestID == current, !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }

    public func selectSkill(_ name: String?, using cloud: ConversationCloudSync) async throws {
        guard
            name == nil
                || (!loadingSkills && skillSourceKey == QuickActionsModel.sourceKey(for: cloud))
        else {
            throw SkillFailure.changed
        }
        try requireSettingsReady()
        let selectionRevision = revision
        let sourceKey = QuickActionsModel.sourceKey(for: cloud)
        let document: SkillDocument?
        if let name {
            guard let skill = skills.first(where: { $0.id == name })?.document else {
                throw SkillFailure.invalid("The selected skill is unavailable or invalid.")
            }
            document = skill
        } else {
            document = nil
        }
        try await savePreferredSkill(name)
        guard QuickActionsModel.sourceKey(for: cloud) == sourceKey,
            revision == selectionRevision
        else { throw SharedSettingsError.changed }
        selectedSkill = document
        revision = UUID()
    }

    public func clearSkill() { selectedSkill = nil; revision = UUID() }

    /// Re-reads the exact selected file before any generation can consume its instructions.
    func validateSkill(using cloud: ConversationCloudSync) async throws -> SkillDocument? {
        try validateSelectedPreference()
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
    func prepare(using cloud: ConversationCloudSync, serverIDs: Set<UUID>? = nil) async throws {
        if settingsSourceKey != nil {
            reloadSkills(using: cloud)
            await skillTask?.value
        }
        try requireSettingsReady()
        if let setupError {
            throw SkillFailure.invalid("MCP settings are unreadable: " + setupError)
        }
        // Send owns cancellable discovery now; a Settings task must not publish over it.
        if let connectTask {
            connectTask.cancel()
            self.connectTask = nil
            connectRequestID = UUID()
            connecting = nil
        }
        var expected = revision
        _ = try await validateSkill(using: cloud)
        guard revision == expected else { throw SkillFailure.changed }
        for server in servers
        where
            (!server.enabledTools.isEmpty || server.enableToolsOnFirstDiscovery)
            && clients[server.id] == nil
        {
            if let serverIDs, !serverIDs.contains(server.id) { continue }
            try Task.checkCancellation()
            let client = try MCPClient(
                server: server, bearerToken: token(for: server))
            let result = try await client.discover()
            try Task.checkCancellation()
            guard revision == expected else { throw SkillFailure.changed }
            if try await acceptDiscoveredTools(result.tools, serverID: server.id) {
                revision = UUID()
                expected = revision
            }
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

    public func saveServer(
        _ input: MCPServer, newToken: String? = nil,
        expected: MCPServerEditBaseline? = nil
    ) async throws {
        try requireSettingsReady()
        var server = input
        if let expected, try captureServerEdit(server.id) != expected {
            throw SharedSettingsError.staleEditor
        }
        if expected != nil, let current = servers.first(where: { $0.id == server.id }) {
            server.enabledTools = current.enabledTools
        }
        try server.validate()
        if sharedRequested {
            var updated = servers
            var value = server
            if let previous = servers.first(where: { $0.id == server.id }) {
                if previous.endpoint != server.endpoint {
                    value.enabledTools = []
                    value.enableToolsOnFirstDiscovery = false
                } else {
                    value.enableToolsOnFirstDiscovery = previous.enableToolsOnFirstDiscovery
                    value.lastDiscoveredTools = newToken == nil ? previous.lastDiscoveredTools : nil
                }
            } else {
                value.lastDiscoveredTools = nil
            }
            if let index = updated.firstIndex(where: { $0.id == value.id }) {
                updated[index] = value
            } else {
                updated.append(value)
            }
            try await commitShared(updated, tokenOverride: newToken.map { (value.id, $0) })
            return
        }
        guard let configuration else {
            throw SkillFailure.invalid("MCP settings storage is unavailable.")
        }
        var updated = servers
        clients[server.id] = nil
        discovered[server.id] = nil
        revision = UUID()
        let previous = servers.first(where: { $0.id == server.id })
        // A registration form cannot supply schemas; only validated discovery may publish them.
        server.lastDiscoveredTools = nil
        if let previous {
            if previous.endpoint != server.endpoint {
                server.enabledTools = []
                server.enableToolsOnFirstDiscovery = false
            } else {
                server.enableToolsOnFirstDiscovery = previous.enableToolsOnFirstDiscovery
                if newToken == nil { server.lastDiscoveredTools = previous.lastDiscoveredTools }
            }
        }
        if let newToken {
            if previous?.endpoint == server.endpoint {
                try invalidatePlanningMetadata(server.id)
            }
            try credentials.write(newToken, id: MCPCredentialID(server: server))
        }
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

    public func removeServer(_ id: UUID) async throws {
        try requireSettingsReady()
        if sharedRequested {
            try await commitShared(servers.filter { $0.id != id })
            return
        }
        guard let configuration else {
            throw SkillFailure.invalid("MCP settings storage is unavailable.")
        }
        try invalidatePlanningMetadata(id)
        try credentials.deleteAll(id)
        if connecting == id {
            connectTask?.cancel()
            connectRequestID = UUID()
            connectTask = nil
            connecting = nil
        }
        let updated = servers.filter { $0.id != id }
        try JSONEncoder().encode(updated).write(to: configuration, options: .atomic)
        servers = updated
        clients[id] = nil
        discovered[id] = nil
        revision = UUID()
    }

    public func clearCredential(_ id: UUID) async throws {
        try requireSettingsReady()
        if sharedRequested {
            try await commitShared(servers, removeToken: id)
            return
        }
        try invalidatePlanningMetadata(id)
        try credentials.deleteAll(id)
    }

    /// Invalidation must be durable before a credential can change, including failure paths.
    private func invalidatePlanningMetadata(_ id: UUID) throws {
        guard let configuration, let index = servers.firstIndex(where: { $0.id == id }) else {
            throw SkillFailure.changed
        }
        var updated = servers
        updated[index].lastDiscoveredTools = nil
        try JSONEncoder().encode(updated).write(to: configuration, options: .atomic)
        servers = updated
        clients[id] = nil
        discovered[id] = nil
        revision = UUID()
    }

    public func discover(_ id: UUID) {
        do { try requireSettingsReady() } catch { self.error = error.localizedDescription; return }
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
                    server: server, bearerToken: token(for: server))
                let result = try await client.discover()
                try Task.checkCancellation()
                guard revision == current else { throw SkillFailure.changed }
                _ = try await acceptDiscoveredTools(result.tools, serverID: id)
                clients[id] = client
                warnings = result.warnings
                revision = UUID()
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }

    /// Commit the initial grant before publishing schemas. Later discovery preserves user choices.
    @discardableResult
    func acceptDiscoveredTools(_ tools: [MCPTool], serverID: UUID) async throws -> Bool {
        guard let index = servers.firstIndex(where: { $0.id == serverID }) else {
            throw SkillFailure.changed
        }
        let initial = servers[index].enableToolsOnFirstDiscovery
        guard let configuration else { throw SkillFailure.unavailable }
        var updated = servers
        updated[index].lastDiscoveredTools = tools
        try updated[index].validate()
        if initial {
            updated[index].enabledTools = Set(tools.map(\.name))
            updated[index].enableToolsOnFirstDiscovery = false
        }
        try requireSettingsReady()
        if sharedRequested {
            if initial { try await commitShared(updated) }
            servers = updated
            try saveCatalog()
        } else {
            try JSONEncoder().encode(updated).write(to: configuration, options: .atomic)
            servers = updated
        }
        discovered[serverID] = tools
        return initial
    }

    public func setEnabled(_ enabled: Bool, tool: String, serverID: UUID) async throws {
        try requireSettingsReady()
        guard let configuration,
            let index = servers.firstIndex(where: { $0.id == serverID })
        else { throw SkillFailure.changed }
        if enabled {
            guard discovered[serverID]?.contains(where: { $0.name == tool }) == true else {
                throw SkillFailure.changed
            }
        }
        var updated = servers
        updated[index].enableToolsOnFirstDiscovery = false
        if enabled {
            updated[index].enabledTools.insert(tool)
        } else {
            updated[index].enabledTools.remove(tool)
        }
        if sharedRequested {
            try await commitShared(updated)
        } else {
            try JSONEncoder().encode(updated).write(to: configuration, options: .atomic)
            servers = updated
        }
        revision = UUID()
    }

    public func visibleToolNames(for serverID: UUID) -> [String] {
        let saved = servers.first(where: { $0.id == serverID })?.enabledTools ?? []
        return saved.union(Set((discovered[serverID] ?? []).map(\.name))).sorted()
    }

    public func pause() {
        sharedAccess?.revoke()
        shared = nil
        sharedAccess = nil
        settingsRequestID = UUID()
        settingsLoading = false
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

    /// Older settings need an explicit connection once before local planning can use metadata.
    func preparePlanningMetadata(using cloud: ConversationCloudSync) async throws {
        if settingsSourceKey != nil {
            reloadSkills(using: cloud)
            await skillTask?.value
        }
        try requireSettingsReady()
        let missing = Set(
            servers.filter {
                (!$0.enabledTools.isEmpty || $0.enableToolsOnFirstDiscovery)
                    && $0.lastDiscoveredTools == nil
            }.map(\.id))
        if !missing.isEmpty {
            try await prepare(using: cloud, serverIDs: missing)
        }
        _ = try remoteTools()
    }

    /// Local planning uses validated saved metadata; live calls still require successful prepare.
    func remoteTools() throws -> [ModelToolSpecification] {
        try requireSettingsReady()
        if let setupError {
            throw SkillFailure.invalid("MCP settings are unreadable: " + setupError)
        }
        var result: [ModelToolSpecification] = []
        guard Set(servers.map(\.modelID)).count == servers.count else {
            throw SkillFailure.invalid(
                "MCP catalog identifiers collide. Remove and re-add one server.")
        }
        for server in servers
        where
            !server.enabledTools.isEmpty || server.enableToolsOnFirstDiscovery
        {
            guard !server.enableToolsOnFirstDiscovery, let tools = server.lastDiscoveredTools,
                server.enabledTools.isSubset(of: Set(tools.map(\.name)))
            else {
                throw SkillFailure.invalid(
                    "Tool schemas for '\(server.name)' are unavailable. Retry count to reconnect; "
                        + "missing enabled tools require configuration changes."
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

extension ToolWorkspace {
    /// Source changes invalidate clients before any new folder or credential can be used.
    public func reloadSettings(using cloud: ConversationCloudSync) async {
        cloud.settingsScopeWillChange = { [weak self] in self?.revokeSettingsAccess() }
        currentSourceKey = { [weak cloud] in
            cloud.map { QuickActionsModel.sourceKey(for: $0) } ?? "unavailable"
        }
        let key = QuickActionsModel.sourceKey(for: cloud)
        let request = UUID()
        settingsRequestID = request
        settingsLoading = true
        defer { if settingsRequestID == request { settingsLoading = false } }
        let changed = settingsSourceKey != key
        if changed {
            invalidateConnections()
            sharedAccess?.revoke()
            shared = nil
            sharedAccess = nil
            sharedDocument = nil
            servers = []
            preferredSkill = nil
            settingsChoices = []
            settingsChoiceDocuments = []
        }
        sharedRequested = cloud.enabled
        settingsSourceKey = key
        do {
            guard let configuration else { throw SharedSettingsError.unavailable }
            if cloud.enabled {
                guard let bookmark = cloud.authorizedFolderBookmark,
                    !cloud.requiresScopeConsent
                else { throw SharedSettingsError.unavailable }
                if shared == nil {
                    let access = SettingsAccessLease()
                    sharedAccess = access
                    shared = SharedSettingsSession(
                        storage: settingsFactory(bookmark),
                        receipt: configuration.deletingLastPathComponent()
                            .appendingPathComponent("shared-migration.json"), access: access)
                }
                guard let shared else { throw SharedSettingsError.unavailable }
                let document = try await shared.refresh(local: localSettings())
                guard settingsRequestID == request,
                    QuickActionsModel.sourceKey(for: cloud) == key, !Task.isCancelled
                else { return }
                sharedDocument = document
                try applyShared(document)
                settingsStatus =
                    "Settings/settings.json is available. iCloud Drive handles transfer."
            } else {
                let previous = servers
                try readConfiguration()
                preferredSkill = try localPreferredSkill()
                for server in previous {
                    if servers.first(where: { $0.id == server.id })?.endpoint != server.endpoint {
                        clients[server.id] = nil
                        discovered[server.id] = nil
                    }
                }
                setupError = nil
                settingsStatus = "Settings are stored on this device."
            }
            settingsChoices = []
            settingsChoiceDocuments = []
            settingsError = nil
        } catch {
            let choices = await shared?.choices ?? []
            guard settingsRequestID == request,
                QuickActionsModel.sourceKey(for: cloud) == key, !Task.isCancelled
            else { return }
            settingsError = error.localizedDescription
            settingsStatus = "Settings need attention."
            settingsChoiceDocuments = choices
            settingsChoices =
                choices.enumerated().map { index, value in
                    let source =
                        index == 0
                        ? "Retained settings"
                        : index == 1 ? "Shared settings" : "iCloud version \(index - 1)"
                    return "Use \(source) (\(value.servers.count) servers)"
                }
        }
    }

    public func resolveSettings(_ index: Int) async {
        let key = settingsSourceKey
        let request = settingsRequestID
        do {
            guard settingsSourceKey == currentSourceKey?(), let shared,
                sharedRequested
            else { throw SharedSettingsError.unavailable }
            guard !settingsLoading, !settingsWriting else { throw SharedSettingsError.unavailable }
            guard settingsChoiceDocuments.indices.contains(index) else {
                throw SharedSettingsError.changed
            }
            let writeID = UUID()
            settingsWriteID = writeID
            settingsWriteSource = key
            defer { if settingsWriteID == writeID { settingsWriteID = nil } }
            let document = try await shared.resolve(index, expected: settingsChoiceDocuments[index])
            guard settingsSourceKey == key, currentSourceKey?() == key,
                settingsRequestID == request, !Task.isCancelled
            else {
                throw SharedSettingsError.changed
            }
            sharedDocument = document
            try applyShared(document)
            settingsChoices = []
            settingsError = nil
            settingsStatus = "Settings saved. iCloud Drive handles transfer."
            settingsChoiceDocuments = []
        } catch {
            guard settingsSourceKey == key, currentSourceKey?() == key,
                settingsRequestID == request, !Task.isCancelled
            else { return }
            settingsError = error.localizedDescription
        }
    }

    func validateSelectedPreference() throws {
        try requireSettingsReady()
        if let preferredSkill, selectedSkill?.name != preferredSkill {
            throw SkillFailure.invalid(
                "The saved selected skill is unavailable. Reload skills or choose None.")
        }
    }

    private func revokeSettingsAccess() {
        sharedAccess?.revoke()
        sharedAccess = nil
        shared = nil
        settingsRequestID = UUID()
        settingsLoading = false
    }

    private func invalidateConnections() {
        connectTask?.cancel()
        connectRequestID = UUID()
        connectTask = nil
        connecting = nil
        clients = [:]
        discovered = [:]
        revision = UUID()
    }

    private func requireSettingsReady() throws {
        if settingsLoading || settingsWriting { throw SharedSettingsError.unavailable }
        if let setupError {
            throw SkillFailure.invalid("MCP settings are unreadable: " + setupError)
        }
        if let currentSourceKey, currentSourceKey() != settingsSourceKey {
            throw SharedSettingsError.unavailable
        }
        if let settingsError { throw SkillFailure.invalid(settingsError) }
        if sharedRequested {
            guard shared != nil, let sharedAccess, sharedDocument != nil,
                settingsChoices.isEmpty
            else { throw SharedSettingsError.unavailable }
            try sharedAccess.check()
        }
    }

    private func localPreferredSkill() throws -> String? {
        guard let configuration else { throw SharedSettingsError.unavailable }
        let file = configuration.deletingLastPathComponent().appendingPathComponent("skill.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(String?.self, from: Data(contentsOf: file))
    }

    private func localSettings() throws -> SharedSettings {
        guard let configuration else { throw SharedSettingsError.unavailable }
        let local: [MCPServer]
        if FileManager.default.fileExists(atPath: configuration.path) {
            local = try JSONDecoder().decode(
                [MCPServer].self, from: Data(contentsOf: configuration))
        } else {
            local = []
        }
        let value = try SharedSettings(
            servers: local.map {
                SharedServer($0, token: try credentials.read(MCPCredentialID(server: $0)))
            }, selectedSkill: localPreferredSkill())
        try value.validate()
        return value
    }

    /// Only form-edited fields and authentication participate; live permission toggles are preserved.
    public func captureServerEdit(_ id: UUID) throws -> MCPServerEditBaseline {
        try requireSettingsReady()
        let fingerprint: String?
        if let server = servers.first(where: { $0.id == id }) {
            var snapshot = SharedServer(server, token: try token(for: server))
            snapshot.enabledTools = []
            snapshot.enableToolsOnFirstDiscovery = false
            fingerprint = try SharedSettings(servers: [snapshot]).fingerprint
        } else {
            fingerprint = nil
        }
        return MCPServerEditBaseline(
            serverID: id, source: settingsSourceKey,
            fingerprint: fingerprint)
    }

    func token(for server: MCPServer) throws -> String? {
        try requireSettingsReady()
        if sharedRequested {
            guard let value = sharedDocument?.servers.first(where: { $0.id == server.id }),
                value.endpoint == server.endpoint
            else { throw SharedSettingsError.changed }
            return value.credential?.bearerToken
        }
        return try credentials.read(MCPCredentialID(server: server))
    }

    private func savePreferredSkill(_ name: String?) async throws {
        if sharedRequested {
            guard var value = sharedDocument else { throw SharedSettingsError.unavailable }
            value.selectedSkill = name
            guard let shared, let expected = sharedDocument else {
                throw SharedSettingsError.unavailable
            }
            let key = settingsSourceKey
            let request = settingsRequestID
            let expectedRevision = revision
            let writeID = UUID()
            settingsWriteID = writeID
            settingsWriteSource = settingsSourceKey
            defer { if settingsWriteID == writeID { settingsWriteID = nil } }
            try await shared.commit(value, replacing: expected)
            guard settingsSourceKey == key, currentSourceKey?() == key,
                settingsRequestID == request, revision == expectedRevision, !Task.isCancelled
            else {
                throw SharedSettingsError.changed
            }
            sharedDocument = value
            try saveCatalog()
        } else {
            guard let configuration else { throw SharedSettingsError.unavailable }
            try JSONEncoder().encode(name).write(
                to: configuration.deletingLastPathComponent()
                    .appendingPathComponent("skill.json"), options: .atomic)
        }
        preferredSkill = name
    }

    private func commitShared(
        _ registrations: [MCPServer],
        tokenOverride: (UUID, String)? = nil, removeToken: UUID? = nil
    ) async throws {
        guard let shared, let current = sharedDocument else {
            throw SharedSettingsError.unavailable
        }
        var value = current
        value.servers = registrations.map { server in
            let old = current.servers.first { $0.id == server.id && $0.endpoint == server.endpoint }
            let token =
                removeToken == server.id
                ? nil
                : tokenOverride?.0 == server.id ? tokenOverride?.1 : old?.credential?.bearerToken
            return SharedServer(server, token: token)
        }
        let key = settingsSourceKey
        let expectedRevision = revision
        let request = settingsRequestID
        let writeID = UUID()
        settingsWriteID = writeID
        settingsWriteSource = settingsSourceKey
        defer { if settingsWriteID == writeID { settingsWriteID = nil } }
        try await shared.commit(value, replacing: current)
        guard settingsSourceKey == key, currentSourceKey?() == key,
            revision == expectedRevision, settingsRequestID == request, !Task.isCancelled
        else { throw SharedSettingsError.changed }
        sharedDocument = value
        for server in servers {
            let changed = value.servers.first { $0.id == server.id }
            let old = current.servers.first { $0.id == server.id }
            if changed == nil || changed?.endpoint != old?.endpoint
                || changed?.credential != old?.credential
            {
                clients[server.id] = nil
                discovered[server.id] = nil
            }
        }
        servers = registrations.map { server in
            var server = server
            let before = current.servers.first { $0.id == server.id }
            let after = value.servers.first { $0.id == server.id }
            if before?.credential != after?.credential || before?.endpoint != after?.endpoint {
                server.lastDiscoveredTools = nil
            }
            return server
        }
        revision = UUID()
        try saveCatalog()
    }

    private struct CatalogCache: Codable {
        var connections: [String: String]
        var servers: [MCPServer]
    }

    private var catalogFile: URL? {
        configuration?.deletingLastPathComponent().appendingPathComponent("shared-catalog.json")
    }

    private func applyShared(_ value: SharedSettings) throws {
        let previous = servers
        let cache: CatalogCache?
        if let file = catalogFile, FileManager.default.fileExists(atPath: file.path) {
            cache = try JSONDecoder().decode(CatalogCache.self, from: Data(contentsOf: file))
        } else {
            cache = nil
        }
        var next = value.servers.map(\.registration)
        for index in next.indices {
            let source = value.servers[index]
            if try cache?.connections[source.id.uuidString] == source.connectionFingerprint {
                next[index].lastDiscoveredTools =
                    cache?.servers.first {
                        $0.id == source.id && $0.endpoint == source.endpoint
                    }?.lastDiscoveredTools
            }
        }
        for server in previous {
            let source = value.servers.first { $0.id == server.id }
            let sameConnection =
                try source.map {
                    try cache?.connections[$0.id.uuidString] == $0.connectionFingerprint
                } ?? false
            if !sameConnection {
                clients[server.id] = nil
                discovered[server.id] = nil
                if connecting == server.id {
                    connectTask?.cancel()
                    connectRequestID = UUID()
                    connecting = nil
                }
            }
        }
        if previous != next || preferredSkill != value.selectedSkill {
            servers = next
            preferredSkill = value.selectedSkill
            selectedSkill = nil
            revision = UUID()
        }
        try saveCatalog()
    }

    private func saveCatalog() throws {
        guard let file = catalogFile, let current = sharedDocument else { return }
        let connections = try Dictionary(
            uniqueKeysWithValues: current.servers.map {
                ($0.id.uuidString, try $0.connectionFingerprint)
            })
        let cache = CatalogCache(connections: connections, servers: servers)
        try JSONEncoder().encode(cache).write(to: file, options: .atomic)
    }
}
