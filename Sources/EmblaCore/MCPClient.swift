import Foundation

/// Explicit endpoint configuration. No executable command or credential is stored here.
public struct MCPServer: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var endpoint: URL
    public var enabledTools: Set<String>
    /// New registrations grant their first discovered catalog once; saved choices then persist.
    public var enableToolsOnFirstDiscovery: Bool
    /// Last validated discovery, used for local context planning, never as a live connection.
    public var lastDiscoveredTools: [MCPTool]?
    /// Short, stable catalog identifier; matching is exact, never inferred from a model reply.
    public var modelID: String { "mcp_" + id.uuidString.prefix(8).lowercased() }

    public init(
        id: UUID = UUID(), name: String, endpoint: URL, enabledTools: Set<String> = [],
        enableToolsOnFirstDiscovery: Bool = true
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.enabledTools = enabledTools
        self.enableToolsOnFirstDiscovery = enableToolsOnFirstDiscovery
        lastDiscoveredTools = nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, endpoint, enabledTools, enableToolsOnFirstDiscovery, lastDiscoveredTools
    }

    /// Existing installations retain their exact saved permissions rather than granting new ones.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        endpoint = try values.decode(URL.self, forKey: .endpoint)
        enabledTools = try values.decode(Set<String>.self, forKey: .enabledTools)
        enableToolsOnFirstDiscovery =
            try values.decodeIfPresent(Bool.self, forKey: .enableToolsOnFirstDiscovery) ?? false
        lastDiscoveredTools =
            try values.decodeIfPresent([MCPTool].self, forKey: .lastDiscoveredTools)
        try validate()
    }

    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let host = endpoint.host, !host.isEmpty, endpoint.user == nil,
            endpoint.password == nil, endpoint.fragment == nil, endpoint.query == nil,
            endpoint.scheme == "https"
                || (endpoint.scheme == "http"
                    && ["127.0.0.1", "localhost", "[::1]"].contains(host))
        else { throw MCPFailure.endpoint }
        if let tools = lastDiscoveredTools {
            guard tools.count <= 64, Set(tools.map(\.name)).count == tools.count else {
                throw MCPFailure.invalidResponse
            }
        }
    }
}

/// Tool descriptions and schemas are untrusted server data, never authorization.
public struct MCPTool: Codable, Sendable, Equatable, Identifiable {
    public let name: String
    public let description: String
    public let inputSchema: ToolJSON
    public var id: String { name }
    let headers: [MCPParameterHeader]

    public init(name: String, description: String, inputSchema: ToolJSON) throws {
        guard !name.isEmpty, name.utf8.count <= 512, inputSchema.object != nil else {
            throw MCPFailure.invalidResponse
        }
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        headers = try MCPParameterHeader.parse(inputSchema)
    }

    private enum CodingKeys: String, CodingKey { case name, description, inputSchema }

    /// Reapply wire-schema validation to stored metadata, including parameter headers.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            name: values.decode(String.self, forKey: .name),
            description: values.decode(String.self, forKey: .description),
            inputSchema: values.decode(ToolJSON.self, forKey: .inputSchema))
    }
}

public struct MCPDiscovery: Sendable {
    public let tools: [MCPTool]
    public let warnings: [String]
}

/// Current stateless MCP 2026-07-28, using JSON or request-scoped SSE over HTTP.
/// Older protocol revisions are not silently substituted; no client capabilities are advertised.
public actor MCPClient {
    public static let protocolVersion = "2026-07-28"
    private let endpoint: URL
    private let token: String?
    private let transport: NetworkTransport
    private let network: NetworkAccess
    private static let limit = 131_072

    struct Timeouts: Sendable {
        var discovery: TimeInterval = 60
        var toolCall: TimeInterval = 20 * 60
    }

    private let timeouts: Timeouts

    public init(
        server: MCPServer, bearerToken: String? = nil, network: NetworkAccess = .shared
    ) throws {
        try self.init(server: server, bearerToken: bearerToken, network: network, timeouts: Timeouts())
    }

    /// Internal timing injection keeps real HTTP deadline tests short; production uses fixed caps.
    init(
        server: MCPServer, bearerToken: String? = nil, network: NetworkAccess = .shared,
        timeouts: Timeouts
    ) throws {
        precondition(timeouts.discovery.isFinite && timeouts.discovery > 0)
        precondition(timeouts.toolCall.isFinite && timeouts.toolCall > 0)
        self.timeouts = timeouts
        try server.validate()
        if let bearerToken, !bearerToken.utf8.allSatisfy({ (33...126).contains($0) }) {
            throw MCPFailure.credential
        }
        endpoint = server.endpoint
        self.network = network
        token = bearerToken?.isEmpty == false ? bearerToken : nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = max(timeouts.discovery, timeouts.toolCall)
        configuration.timeoutIntervalForResource = max(timeouts.discovery, timeouts.toolCall)
        transport = NetworkTransport(configuration: configuration)
    }

    public func discover() async throws -> MCPDiscovery {
        let information = try await request("server/discover")
        guard information["capabilities"]?["tools"]?.object != nil else {
            throw MCPFailure.toolsUnavailable
        }
        var tools: [MCPTool] = []
        var warnings: [String] = []
        var seen = Set<String>()
        var cursors = Set<String>()
        var cursor: String?
        repeat {
            var params: [String: ToolJSON] = [:]
            if let cursor { params["cursor"] = .string(cursor) }
            let page = try await request("tools/list", params: params)
            guard case .array(let entries) = page["tools"] else {
                throw MCPFailure.invalidResponse
            }
            for entry in entries {
                guard let name = entry["name"]?.string, seen.insert(name).inserted,
                    let schema = entry["inputSchema"]
                else { throw MCPFailure.invalidResponse }
                do {
                    tools.append(
                        try MCPTool(
                            name: name,
                            description: entry["description"]?.string ?? "", inputSchema: schema))
                } catch MCPFailure.invalidHeaders {
                    warnings.append("Excluded '\(name)': invalid x-mcp-header declaration.")
                }
            }
            guard tools.count <= 64 else { throw MCPFailure.limit }
            cursor = page["nextCursor"]?.string
            if let cursor {
                guard cursors.insert(cursor).inserted, cursors.count <= 16 else {
                    throw MCPFailure.limit
                }
            }
        } while cursor != nil
        return MCPDiscovery(tools: tools, warnings: warnings)
    }

    /// The caller must match this call to its explicitly registered/enabled server and tool.
    public func call(_ tool: MCPTool, arguments: [String: ToolJSON]) async throws -> ToolJSON {
        var headers: [String: String] = [:]
        for header in tool.headers {
            if let value = try header.value(in: .object(arguments)) {
                headers["Mcp-Param-" + header.name] = Self.header(value)
            }
        }
        let result = try await request(
            "tools/call",
            params: [
                "name": .string(tool.name), "arguments": .object(arguments),
            ], headers: headers)
        guard case .array(let content) = result["content"],
            content.allSatisfy(Self.validContent),
            result["isError"] == nil || result["isError"] == .bool(false)
                || result["isError"] == .bool(true)
        else { throw MCPFailure.invalidResponse }
        guard result["isError"] != .bool(true) else { throw MCPFailure.toolError(result) }
        return result
    }

    /// Reject malformed wire content rather than feeding a success-shaped result to the model.
    private static func validContent(_ value: ToolJSON) -> Bool {
        switch value["type"]?.string {
        case "text": return value["text"]?.string != nil
        case "image", "audio":
            return value["data"]?.string != nil && value["mimeType"]?.string != nil
        case "resource_link":
            return value["uri"]?.string != nil && value["name"]?.string != nil
        case "resource":
            return value["resource"]?["uri"]?.string != nil
                && (value["resource"]?["text"]?.string != nil
                    || value["resource"]?["blob"]?.string != nil)
        default: return false
        }
    }

    private func request(
        _ method: String, params: [String: ToolJSON] = [:], headers: [String: String] = [:]
    ) async throws -> ToolJSON {
        let timeout = method == "tools/call" ? timeouts.toolCall : timeouts.discovery
        return try await withThrowingTaskGroup(of: ToolJSON.self) { group in
            group.addTask {
                try await self.performRequest(method, params: params, headers: headers, timeout: timeout)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw MCPFailure.requestTimedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }

    /// The deadline covers headers and the complete JSON/SSE response, including keep-alives.
    private func performRequest(
        _ method: String, params: [String: ToolJSON], headers: [String: String],
        timeout: TimeInterval
    ) async throws -> ToolJSON {
        try Task.checkCancellation()
        let id = UUID().uuidString
        var params = params
        params["_meta"] = .object([
            "io.modelcontextprotocol/protocolVersion": .string(Self.protocolVersion),
            "io.modelcontextprotocol/clientCapabilities": .object([:]),
            "io.modelcontextprotocol/clientInfo": .object([
                "name": .string("EmblaChat"), "version": .string("1"),
            ]),
        ])
        let message = ToolJSON.object([
            "jsonrpc": .string("2.0"), "id": .string(id),
            "method": .string(method), "params": .object(params),
        ])
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.httpBody = try JSONEncoder().encode(message)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(Self.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        request.setValue(method, forHTTPHeaderField: "Mcp-Method")
        if let name = params["name"]?.string {
            request.setValue(Self.header(name), forHTTPHeaderField: "Mcp-Name")
        }
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (bytes, response) = try await transport.response(
            for: request, access: network, limit: Self.limit, overflow: MCPFailure.limit)
        defer { bytes.task.cancel() }
        try bytes.task.check()
        guard let response = response as? HTTPURLResponse else { throw MCPFailure.invalidResponse }
        let type = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if response.statusCode != 200 {
            if type.hasPrefix("application/json") {
                var data = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard data.count < Self.limit else { throw MCPFailure.limit }
                    data.append(byte)
                }
                if let message = try? Self.decode(data),
                    message["jsonrpc"] == .string("2.0"),
                    message["id"] == .string(id) || message["id"] == .null,
                    let error = message["error"], error.object != nil
                {
                    throw MCPFailure.httpRPC(response.statusCode, error)
                }
            }
            if response.statusCode == 401 || response.statusCode == 403 {
                throw MCPFailure.authentication
            }
            throw MCPFailure.http(response.statusCode)
        }
        if type.hasPrefix("application/json") {
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < Self.limit else { throw MCPFailure.limit }
                data.append(byte)
            }
            try bytes.task.check()
            return try Self.result(data, id: id)
        }
        guard type.hasPrefix("text/event-stream") else { throw MCPFailure.invalidResponse }
        var line = Data()
        var event: [String] = []
        var size = 0
        var afterCarriageReturn = false
        var firstLine = true
        for try await byte in bytes {
            try Task.checkCancellation()
            size += 1
            guard size <= Self.limit else { throw MCPFailure.limit }
            if afterCarriageReturn {
                afterCarriageReturn = false
                if byte == 10 { continue }
            }
            if byte != 10 && byte != 13 { line.append(byte); continue }
            afterCarriageReturn = byte == 13
            guard let decoded = String(data: line, encoding: .utf8) else {
                throw MCPFailure.invalidResponse
            }
            var text = decoded
            if firstLine {
                firstLine = false
                if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
            }
            line.removeAll(keepingCapacity: true)
            if text.isEmpty {
                if !event.isEmpty {
                    let data = Data(event.joined(separator: "\n").utf8)
                    let message = try Self.decode(data)
                    if message["id"] != nil {
                        try bytes.task.check()
                        return try Self.result(data, id: id)
                    }
                    guard message["jsonrpc"] == .string("2.0"),
                        message["method"]?.string?.hasPrefix("notifications/") == true
                    else { throw MCPFailure.invalidResponse }
                    event.removeAll(keepingCapacity: true)
                }
            } else if text.hasPrefix("data:") {
                var value = String(text.dropFirst(5))
                if value.hasPrefix(" ") { value.removeFirst() }
                event.append(value)
            }
        }
        throw MCPFailure.invalidResponse
    }

    private static func decode(_ data: Data) throws -> ToolJSON {
        do { return try ToolJSON.decode(data) } catch { throw MCPFailure.invalidResponse }
    }

    private static func result(_ data: Data, id: String) throws -> ToolJSON {
        let message = try Self.decode(data)
        guard message["jsonrpc"] == .string("2.0"), message["id"] == .string(id) else {
            throw MCPFailure.invalidResponse
        }
        if let error = message["error"] {
            guard message["result"] == nil, error["message"]?.string != nil,
                case .integer = error["code"]
            else { throw MCPFailure.invalidResponse }
            throw MCPFailure.rpc(error)
        }
        guard let result = message["result"], result["resultType"] == .string("complete") else {
            throw MCPFailure.invalidResponse
        }
        return result
    }

    /// MCP sentinel encoding also protects header whitespace, control characters and Unicode.
    static func header(_ value: String) -> String {
        let safe = value.utf8.allSatisfy { (32...126).contains($0) || $0 == 9 }
        guard safe, value == value.trimmingCharacters(in: .whitespacesAndNewlines),
            !(value.hasPrefix("=?base64?") && value.hasSuffix("?="))
        else { return "=?base64?" + Data(value.utf8).base64EncodedString() + "?=" }
        return value
    }
}

struct MCPParameterHeader: Sendable, Equatable {
    let name: String
    let path: [String]
    let type: String

    static func parse(_ schema: ToolJSON) throws -> [Self] {
        var result: [Self] = []
        func walk(_ value: ToolJSON, path: [String]?) throws {
            guard let object = value.object else { return }
            if let marker = object["x-mcp-header"] {
                guard let name = marker.string, !name.isEmpty,
                    name.utf8.allSatisfy({
                        (48...57).contains($0) || (65...90).contains($0)
                            || (97...122).contains($0) || "!#$%&'*+-.^_`|~".utf8.contains($0)
                    }), let path, !path.isEmpty,
                    let type = object["type"]?.string,
                    ["integer", "string", "boolean"].contains(type),
                    !result.contains(where: { $0.name.lowercased() == name.lowercased() })
                else { throw MCPFailure.invalidHeaders }
                result.append(Self(name: name, path: path, type: type))
            }
            // Only schema-valued keywords contain annotations. default/const/enum/examples
            // hold instance data, even when that data happens to contain "x-mcp-header".
            for (key, child) in object {
                switch key {
                case "properties":
                    for (name, property) in child.object ?? [:] {
                        try walk(property, path: path.map { $0 + [name] })
                    }
                case "$defs", "definitions", "patternProperties", "dependentSchemas":
                    for schema in child.object?.values ?? Dictionary<String, ToolJSON>().values {
                        try walk(schema, path: nil)
                    }
                case "allOf", "anyOf", "oneOf", "prefixItems":
                    if case .array(let schemas) = child {
                        for schema in schemas { try walk(schema, path: nil) }
                    }
                case "items", "additionalItems", "additionalProperties", "contains",
                    "propertyNames",
                    "not", "if", "then", "else", "unevaluatedItems", "unevaluatedProperties":
                    if case .array(let schemas) = child {
                        for schema in schemas { try walk(schema, path: nil) }
                    } else {
                        try walk(child, path: nil)
                    }
                default: break
                }
            }
        }
        try walk(schema, path: [])
        return result
    }

    func value(in arguments: ToolJSON) throws -> String? {
        var value: ToolJSON? = arguments
        for component in path { value = value?[component] }
        guard let value else { return nil }
        switch (type, value) {
        case ("string", .string(let string)): return string
        case ("boolean", .bool(let bool)): return bool ? "true" : "false"
        case ("integer", .number(let number)):
            var original = number
            var integral = Decimal()
            NSDecimalRound(&integral, &original, 0, .plain)
            guard !number.isNaN, integral == number,
                abs(number) <= Decimal(9_007_199_254_740_991)
            else { throw MCPFailure.invalidHeaders }
            return NSDecimalNumber(decimal: number).stringValue
        case ("integer", .integer(let number)):
            guard (-9_007_199_254_740_991...9_007_199_254_740_991).contains(number) else {
                throw MCPFailure.invalidHeaders
            }
            return String(number)
        case ("integer", .unsignedInteger(let number)):
            guard number <= 9_007_199_254_740_991 else { throw MCPFailure.invalidHeaders }
            return String(number)
        default: throw MCPFailure.invalidHeaders
        }
    }
}

public enum MCPFailure: Error, LocalizedError, Sendable {
    case endpoint, credential, credentialUnavailable, authentication, toolsUnavailable,
        invalidResponse, invalidHeaders,
        limit, requestTimedOut
    case http(Int), rpc(ToolJSON), httpRPC(Int, ToolJSON), toolError(ToolJSON)

    public var errorDescription: String? {
        switch self {
        case .endpoint:
            return
                "Use an HTTPS MCP endpoint without credentials, query or fragment. HTTP is allowed only on loopback for local testing."
        case .credential: return "The bearer credential contains invalid header characters."
        case .credentialUnavailable:
            return
                "The device Keychain could not read or update this server's token. Unlock the device and check its credential in Settings."
        case .authentication:
            return
                "The MCP server requires authorization. Check its token in Settings; browser OAuth sign-in is not supported."
        case .toolsUnavailable: return "The MCP server did not advertise tools."
        case .invalidResponse:
            return
                "The server did not return a valid supported MCP 2026-07-28 response. Check protocol compatibility."
        case .invalidHeaders:
            return "The tool has an invalid MCP parameter-header declaration or value."
        case .limit: return "The server response exceeds the supported size or tool-list limit."
        case .requestTimedOut:
            return "The MCP request exceeded its time limit. Its outcome is unknown; retry explicitly if appropriate."
        case .http(let code):
            return "The MCP server returned HTTP \(code). No result was substituted."
        case .rpc(let code):
            return "The MCP server returned a protocol error (\((try? code.text()) ?? "unknown"))."
        case .httpRPC(let status, let error):
            return
                "The MCP server returned HTTP \(status): \((try? error.text()) ?? "unreadable protocol error")."
        case .toolError:
            return
                "The MCP tool reported an execution error. Its returned details are retained in the transcript."
        }
    }
}
