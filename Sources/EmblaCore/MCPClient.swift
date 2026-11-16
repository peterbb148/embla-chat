import Foundation

/// Explicit endpoint configuration. No executable command or credential is stored here.
public struct MCPServer: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var endpoint: URL
    public var enabledTools: Set<String>
    /// Short, stable catalog identifier; matching is exact, never inferred from a model reply.
    public var modelID: String { "mcp_" + id.uuidString.prefix(8).lowercased() }

    public init(id: UUID = UUID(), name: String, endpoint: URL, enabledTools: Set<String> = []) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.enabledTools = enabledTools
    }

    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let host = endpoint.host, !host.isEmpty, endpoint.user == nil,
            endpoint.password == nil, endpoint.fragment == nil, endpoint.query == nil,
            endpoint.scheme == "https"
                || (endpoint.scheme == "http"
                    && ["127.0.0.1", "localhost", "[::1]"].contains(host))
        else { throw MCPFailure.endpoint }
    }
}

/// Tool descriptions and schemas are untrusted server data, never authorization.
public struct MCPTool: Sendable, Equatable, Identifiable {
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
    private let session: URLSession
    private static let limit = 131_072

    public init(server: MCPServer, bearerToken: String? = nil) throws {
        try server.validate()
        if let bearerToken, !bearerToken.utf8.allSatisfy({ (33...126).contains($0) }) {
            throw MCPFailure.credential
        }
        endpoint = server.endpoint
        token = bearerToken?.isEmpty == false ? bearerToken : nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        session = URLSession(
            configuration: configuration, delegate: MCPNoRedirect(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

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
        guard result["isError"] != .bool(true) else { throw MCPFailure.toolError(result) }
        guard result["content"] != nil || result["structuredContent"] != nil else {
            throw MCPFailure.invalidResponse
        }
        return result
    }

    private func request(
        _ method: String, params: [String: ToolJSON] = [:], headers: [String: String] = [:]
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
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse else { throw MCPFailure.invalidResponse }
        if response.statusCode == 401 || response.statusCode == 403 {
            throw MCPFailure.authentication
        }
        guard response.statusCode == 200 else { throw MCPFailure.http(response.statusCode) }
        let type = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if type.hasPrefix("application/json") {
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < Self.limit else { throw MCPFailure.limit }
                data.append(byte)
            }
            return try Self.result(data, id: id)
        }
        guard type.hasPrefix("text/event-stream") else { throw MCPFailure.invalidResponse }
        var line = Data()
        var event: [String] = []
        var size = 0
        for try await byte in bytes {
            try Task.checkCancellation()
            size += 1
            guard size <= Self.limit else { throw MCPFailure.limit }
            if byte != 10 { line.append(byte); continue }
            let text = String(decoding: line, as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            line.removeAll(keepingCapacity: true)
            if text.isEmpty {
                if !event.isEmpty {
                    let data = Data(event.joined(separator: "\n").utf8)
                    let message = try JSONDecoder().decode(ToolJSON.self, from: data)
                    if message["id"] != nil { return try Self.result(data, id: id) }
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

    private static func result(_ data: Data, id: String) throws -> ToolJSON {
        let message = try JSONDecoder().decode(ToolJSON.self, from: data)
        guard message["jsonrpc"] == .string("2.0"), message["id"] == .string(id) else {
            throw MCPFailure.invalidResponse
        }
        if let error = message["error"] {
            throw MCPFailure.rpc(error["code"] ?? .null)
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

private final class MCPNoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) { completionHandler(nil) }
}

struct MCPParameterHeader: Sendable, Equatable {
    let name: String
    let path: [String]
    let type: String

    static func parse(_ schema: ToolJSON) throws -> [Self] {
        var result: [Self] = []
        func walk(_ value: ToolJSON, path: [String]?, schemaNode: Bool) throws {
            if case .array(let values) = value {
                for value in values { try walk(value, path: nil, schemaNode: false) }
            }
            guard let object = value.object else { return }
            if let marker = object["x-mcp-header"] {
                guard let name = marker.string, !name.isEmpty,
                    name.utf8.allSatisfy({
                        (48...57).contains($0) || (65...90).contains($0)
                            || (97...122).contains($0) || "!#$%&'*+-.^_`|~".utf8.contains($0)
                    }), let path, !path.isEmpty, schemaNode,
                    let type = object["type"]?.string,
                    ["integer", "string", "boolean"].contains(type),
                    !result.contains(where: { $0.name.lowercased() == name.lowercased() })
                else { throw MCPFailure.invalidHeaders }
                result.append(Self(name: name, path: path, type: type))
            }
            for (key, child) in object where key != "x-mcp-header" {
                if key == "properties", schemaNode, let properties = child.object {
                    for (name, property) in properties {
                        try walk(property, path: path.map { $0 + [name] }, schemaNode: true)
                    }
                } else {
                    try walk(child, path: nil, schemaNode: false)
                }
            }
        }
        try walk(schema, path: [], schemaNode: true)
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
            guard number.isFinite, number.rounded() == number,
                abs(number) <= 9_007_199_254_740_991
            else { throw MCPFailure.invalidHeaders }
            return String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), number)
        default: throw MCPFailure.invalidHeaders
        }
    }
}

public enum MCPFailure: Error, LocalizedError, Sendable {
    case endpoint, credential, authentication, toolsUnavailable, invalidResponse, invalidHeaders,
        limit
    case http(Int), rpc(ToolJSON), toolError(ToolJSON)

    public var errorDescription: String? {
        switch self {
        case .endpoint:
            return
                "Use an HTTPS MCP endpoint without credentials, query or fragment. HTTP is allowed only on loopback for local testing."
        case .credential: return "The bearer credential contains invalid header characters."
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
        case .http(let code):
            return "The MCP server returned HTTP \(code). No result was substituted."
        case .rpc(let code):
            return "The MCP server returned a protocol error (\((try? code.text()) ?? "unknown"))."
        case .toolError:
            return
                "The MCP tool reported an execution error. Its returned details are retained in the transcript."
        }
    }
}
