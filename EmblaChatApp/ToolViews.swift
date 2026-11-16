import EmblaCore
import EmblaPresentation
import SwiftUI

struct SkillsView: View {
    let model: LocalInferenceModel
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                Text(
                    model.cloud.enabled
                        ? "Selected iCloud EmblaChat / Skills"
                        : "On My iPhone / Embla Chat / Skills"
                )
                .font(.callout).textSelection(.enabled)
                Text(
                    "Copy standard skill folders here, then reload. Selecting a skill applies its instructions; scripts cannot run on iPhone. Supporting text files are read on demand while the skill is selected."
                )
                .font(.callout).foregroundStyle(.secondary)
                Button("Reload skills") { model.tools.reloadSkills(using: model.cloud) }
                    .disabled(model.tools.loadingSkills || model.busy)
                if model.tools.loadingSkills { ProgressView("Loading skills…") }
                if let error = error ?? model.tools.error {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            Section("Selected skill") {
                Text(model.tools.selectedSkill?.name ?? "None")
                    .accessibilityIdentifier("selected-skill")
                Button("Use no skill") {
                    model.tools.clearSkill()
                    model.toolConfigurationChanged()
                }.disabled(model.busy)
            }
            Section("Available skills") {
                if model.tools.skills.isEmpty {
                    Text("No skills found. Add Skills/<skill-name>/SKILL.md in Files.")
                }
                ForEach(model.tools.skills) { entry in
                    if let skill = entry.document {
                        NavigationLink(skill.name) {
                            Form {
                                Section("Description") { Text(skill.description) }
                                if let compatibility = skill.compatibility {
                                    Section("Compatibility requirements") {
                                        Text(compatibility)
                                        Text(
                                            "Check these requirements before selecting. Copied files do not install dependencies or authorize servers."
                                        )
                                        .foregroundStyle(.secondary)
                                    }
                                }
                                if let allowed = skill.allowedTools {
                                    Section("Declared tools") {
                                        Text(allowed)
                                        Text(
                                            "This metadata does not grant permissions. "
                                                + "Register MCP servers separately; enabled "
                                                + "tools can run automatically."
                                        )
                                        .foregroundStyle(.secondary)
                                    }
                                }
                                Section("Instructions") {
                                    Text(skill.instructions).textSelection(.enabled)
                                }
                                Button("Use this skill") {
                                    do {
                                        try model.tools.selectSkill(
                                            skill.name, using: model.cloud)
                                        model.toolConfigurationChanged()
                                        dismiss()
                                    } catch { self.error = error.localizedDescription }
                                }.disabled(model.busy)
                            }.navigationTitle(skill.name)
                        }
                    } else {
                        VStack(alignment: .leading) {
                            Text(entry.id)
                            Text(entry.error ?? "Invalid skill").font(.caption).foregroundStyle(
                                .red)
                        }
                    }
                }
            }
        }
        .navigationTitle("Skills")
    }
}

struct MCPSettingsView: View {
    let model: LocalInferenceModel
    @State private var newServer: MCPServer?

    var body: some View {
        List {
            Section {
                Text(
                    "MCP tools use the network while inference stays on this device. "
                        + "Adding a server enables all its discovered tools and authorizes "
                        + "automatic calls without another confirmation. You can turn "
                        + "individual tools off afterward. The server receives arguments and "
                        + "connection metadata; arguments may include chat-derived information."
                )
                .font(.callout)
                Text(
                    "Supports MCP 2026-07-28 Streamable HTTP, JSON and SSE responses. No subprocesses, legacy transports or browser OAuth sign-in. A server can use no authentication or a manually supplied bearer token, kept in this device’s Keychain."
                )
                .font(.caption).foregroundStyle(.secondary)
                Text(
                    "Tool requests and results are saved in the chat and follow its global iCloud preference."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Section("Add server") {
                NavigationLink("Browse registry") { MCPRegistryView(model: model) }
                Button("Add MCP server") {
                    newServer = MCPServer(
                        name: "", endpoint: URL(string: "https://example.invalid/mcp")!)
                }
                Button("Add Time.Now example") {
                    newServer = MCPServer(
                        name: "Time.Now", endpoint: URL(string: "https://time.now/mcp")!)
                }
            }
            Section("Servers") {
                ForEach(model.tools.servers) { server in
                    NavigationLink(server.name) { MCPServerEditor(model: model, initial: server) }
                }
            }
            if let error = model.tools.error {
                Section("Connection error") {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            if !model.tools.warnings.isEmpty {
                Section("Compatibility warnings") {
                    ForEach(model.tools.warnings, id: \.self) { Text($0) }
                }
            }
        }
        .navigationTitle("MCP Servers")
        .disabled(model.busy)
        .sheet(item: $newServer) { server in
            NavigationStack { MCPServerEditor(model: model, initial: server) }
        }
    }
}

private struct MCPServerEditor: View {
    let model: LocalInferenceModel
    let initial: MCPServer
    var requiresBearerToken = false
    @State private var name = ""
    @State private var endpoint = ""
    @State private var token = ""
    @State private var error: String?
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Server") {
                TextField("Name", text: $name).accessibilityIdentifier("mcp-name")
                TextField("HTTPS MCP endpoint", text: $endpoint)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .keyboardType(.URL).accessibilityIdentifier("mcp-endpoint")
                SecureField(
                    requiresBearerToken ? "Bearer token" : "New bearer token (optional)",
                    text: $token)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Text(
                    "Leave the token blank to keep the saved credential. Settings and tokens stay on this device. Changing the endpoint clears existing tool permissions and the old token."
                )
                .font(.caption).foregroundStyle(.secondary)
                Button("Save server") {
                    do {
                        guard let url = URL(string: endpoint) else { throw MCPFailure.endpoint }
                        let isNew = !model.tools.servers.contains(where: { $0.id == initial.id })
                        if isNew && requiresBearerToken && token.isEmpty {
                            error = "This server requires a bearer token from its provider."
                            return
                        }
                        let current =
                            model.tools.servers.first(where: { $0.id == initial.id }) ?? initial
                        try model.tools.saveServer(
                            MCPServer(
                                id: initial.id, name: name,
                                endpoint: url, enabledTools: current.enabledTools),
                            newToken: token.isEmpty ? nil : token)
                        token = ""
                        error = nil
                        model.toolConfigurationChanged()
                        if isNew { model.tools.discover(initial.id) }
                    } catch { self.error = error.localizedDescription }
                }
                Text("New servers connect after saving and enable all discovered tools.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let saved = model.tools.servers.first(where: { $0.id == initial.id }) {
                Section("Connection and tools") {
                    Text(saved.endpoint.absoluteString).font(.caption).textSelection(.enabled)
                    Button("Connect and discover tools") { model.tools.discover(initial.id) }
                        .disabled(model.tools.connecting != nil)
                    if model.tools.connecting == initial.id { ProgressView("Discovering tools…") }
                    ForEach(model.tools.visibleToolNames(for: initial.id), id: \.self) { toolName in
                        Toggle(
                            isOn: Binding(
                                get: {
                                    model.tools.servers.first(where: { $0.id == initial.id })?
                                        .enabledTools.contains(toolName) == true
                                },
                                set: { enabled in
                                    do {
                                        try model.tools.setEnabled(
                                            enabled, tool: toolName, serverID: initial.id)
                                        model.toolConfigurationChanged()
                                    } catch { self.error = error.localizedDescription }
                                }
                            )
                        ) {
                            VStack(alignment: .leading) {
                                Text(toolName)
                                if let tool = model.tools.discovered[initial.id]?.first(where: {
                                    $0.name == toolName
                                }) {
                                    Text(tool.description).font(.caption).foregroundStyle(
                                        .secondary)
                                } else {
                                    Text(
                                        "Schema unavailable. Disable this saved permission if the tool is no longer needed."
                                    )
                                    .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Text(
                        "All tools are enabled after a new server connects. Turn off any "
                            + "you do not want to use. Saved choices survive reconnects and "
                            + "restarts; enabled tools run without per-call confirmation."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button("Remove saved token", role: .destructive) {
                        do { try model.tools.clearCredential(initial.id) } catch {
                            self.error = error.localizedDescription
                        }
                    }
                    Button("Delete server…", role: .destructive) { confirmDelete = true }
                }
            }
            if let error = error ?? model.tools.error {
                Section { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
        }
        .navigationTitle(name.isEmpty ? "MCP server" : name)
        .disabled(model.busy)
        .onAppear {
            name = initial.name; endpoint = initial.endpoint.absoluteString
        }
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .alert("Delete this MCP server?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                do {
                    try model.tools.removeServer(initial.id); model.toolConfigurationChanged();
                    dismiss()
                } catch { self.error = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes its local settings and Keychain token. Existing chat records remain.")
        }
    }
}

/// Search and pagination share a structured view task; leaving the screen cancels its request.
private struct MCPRegistryView: View {
    let model: LocalInferenceModel
    @State private var client = MCPRegistryClient()
    @State private var request = Request()
    @State private var completedRequest: Request?
    @State private var servers: [MCPRegistryServer] = []
    @State private var nextCursor: String?
    @State private var loading = true
    @State private var error: String?

    private struct Request: Hashable {
        var search = ""
        var cursor: String?
        var attempt = 0
    }

    private var shortSearch: Bool {
        let search = request.search.trimmingCharacters(in: .whitespacesAndNewlines)
        return !search.isEmpty && search.unicodeScalars.count < 3
    }

    var body: some View {
        List {
            Section {
                Link("Official MCP Registry", destination: URL(
                    string: "https://registry.modelcontextprotocol.io")!)
                    .accessibilityIdentifier("registry-source")
                Text(
                    "Only supported remote connections are shown. Listings describe servers; "
                        + "availability and authentication are checked when you add one.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Local packages, URL variables and custom headers are not supported.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Servers") {
                ForEach(servers) { server in
                    NavigationLink {
                        RegistryServerView(model: model, server: server)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(server.displayName)
                            Text(server.name).font(.caption).foregroundStyle(.secondary)
                            if let description = server.description {
                                Text(description).font(.caption).lineLimit(3)
                            }
                        }
                    }
                    .accessibilityIdentifier("registry-" + server.name)
                }
                if shortSearch {
                    Text("Type at least 3 characters to search server names.")
                        .accessibilityIdentifier("registry-search-hint")
                } else if loading { ProgressView("Loading servers…") }
                if !shortSearch, let error {
                    Text(error).foregroundStyle(.red).accessibilityIdentifier("registry-error")
                    Button("Retry") { request.attempt += 1 }
                } else if !shortSearch && !loading && servers.isEmpty {
                    Text(nextCursor == nil
                         ? "No supported remote servers found."
                         : "No supported connections on this page. Load more or search by name.")
                }
                if !shortSearch && nextCursor != nil && error == nil {
                    Button("Load more") { request.cursor = nextCursor }
                        .disabled(loading)
                }
            }
        }
        .navigationTitle("Server registry")
        .searchable(
            text: Binding(
                get: { request.search },
                set: { request = Request(search: $0) }),
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search server names")
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .task(id: request) { [request] in await load(request) }
    }

    @MainActor private func load(_ current: Request) async {
        guard !Task.isCancelled, request == current, completedRequest != current else { return }
        let search = current.search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !search.isEmpty && search.unicodeScalars.count < 3 {
            servers = []; nextCursor = nil; completedRequest = nil
            error = nil; loading = false
            return
        }
        loading = true
        error = nil
        if current.cursor == nil {
            servers = []; nextCursor = nil; completedRequest = nil
        }
        defer { if request == current { loading = false } }
        do {
            if current.cursor == nil && !current.search.isEmpty {
                try await Task.sleep(for: .milliseconds(300))
            }
            let page = try await client.page(
                search: search, cursor: current.cursor)
            try Task.checkCancellation()
            guard request == current else { return }
            if current.cursor != nil {
                let existing = Set(servers.map(\.id))
                guard page.nextCursor != current.cursor,
                    page.servers.allSatisfy({ !existing.contains($0.id) })
                else { throw MCPRegistryFailure.invalidResponse }
                servers += page.servers
            } else {
                servers = page.servers
            }
            nextCursor = page.nextCursor
            completedRequest = current
        } catch {
            guard !Task.isCancelled, request == current else { return }
            self.error = error.localizedDescription
        }
    }
}

private struct RegistryServerView: View {
    let model: LocalInferenceModel
    let server: MCPRegistryServer
    @State private var selection: Selection?

    private struct Selection: Identifiable {
        let server: MCPServer
        let requiresBearerToken: Bool
        var id: UUID { server.id }
    }

    var body: some View {
        List {
            Section {
                Text(server.displayName).font(.headline)
                Text(server.name).font(.caption).textSelection(.enabled)
                LabeledContent("Catalog version", value: server.version)
                if let description = server.description { Text(description) }
                Text("A listing does not verify the remote URL's owner or a working connection.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(server.endpoints.enumerated()), id: \.offset) { _, endpoint in
                Section("Connection") {
                    Text(endpoint.url.absoluteString).textSelection(.enabled)
                    if endpoint.requiresBearerToken {
                        Text("Requires a bearer token obtained from the server provider.")
                    } else {
                        Text("A bearer token can be entered if the server needs one.")
                    }
                    Button("Add server") {
                        selection = Selection(
                            server: MCPServer(name: server.displayName, endpoint: endpoint.url),
                            requiresBearerToken: endpoint.requiresBearerToken)
                    }
                }
            }
        }
        .navigationTitle(server.displayName)
        .sheet(item: $selection) { selection in
            NavigationStack {
                MCPServerEditor(
                    model: model, initial: selection.server,
                    requiresBearerToken: selection.requiresBearerToken)
            }
        }
    }
}
