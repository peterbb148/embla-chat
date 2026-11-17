import Foundation

/// A catalog connection the current client can configure without URL variables or custom headers.
public struct MCPRegistryEndpoint: Sendable, Equatable {
    public let url: URL
    public let requiresBearerToken: Bool
}

/// Listing identity belongs to the registry record, not to every publisher sharing its remote URL.
public struct MCPRegistryServer: Sendable, Equatable, Identifiable {
    public let name: String
    public let version: String
    public let title: String?
    public let description: String?
    public let endpoints: [MCPRegistryEndpoint]
    public var id: String { name + "@" + version }
    public var displayName: String { title.flatMap { $0.isEmpty ? nil : $0 } ?? name }
}

public struct MCPRegistryPage: Sendable {
    public let servers: [MCPRegistryServer]
    public let nextCursor: String?
}

/// Anonymous reads from the official catalog, separate from registered-server credentials.
public actor MCPRegistryClient {
    private let transport: NetworkTransport
    private let network: NetworkAccess
    private static let limit = 2_097_152

    public init(network: NetworkAccess = .shared) {
        self.network = network
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        transport = NetworkTransport(configuration: configuration)
    }

    init(session: URLSession, network: NetworkAccess = NetworkAccess(initialState: .satisfied)) {
        transport = NetworkTransport(configuration: session.configuration)
        self.network = network
    }

    /// A nonempty cursor is opaque; keep the same search and version filter on every page.
    public func page(search: String = "", cursor: String? = nil) async throws -> MCPRegistryPage {
        try Task.checkCancellation()
        let request = Self.request(search: search, cursor: cursor)
        let (bytes, response) = try await transport.response(
            for: request, access: network, limit: Self.limit, overflow: MCPRegistryFailure.tooLarge)
        defer { bytes.task.cancel() }
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else {
            throw MCPRegistryFailure.invalidResponse
        }
        guard response.statusCode == 200 else {
            throw MCPRegistryFailure.http(response.statusCode)
        }
        guard response.expectedContentLength <= Self.limit else {
            throw MCPRegistryFailure.tooLarge
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < Self.limit else { throw MCPRegistryFailure.tooLarge }
            data.append(byte)
        }
        try bytes.task.check()
        return try Self.decode(data)
    }

    static func request(search: String, cursor: String?) -> URLRequest {
        var components = URLComponents(
            string: "https://registry.modelcontextprotocol.io/v0.1/servers")!
        var items = [
            URLQueryItem(name: "version", value: "latest"),
            URLQueryItem(name: "limit", value: "20"),
        ]
        if !search.isEmpty { items.append(URLQueryItem(name: "search", value: search)) }
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        components.queryItems = items
        // Form-style server query parsers interpret a literal plus as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func decode(_ data: Data) throws -> MCPRegistryPage {
        let page: RegistryResponse
        do { page = try JSONDecoder().decode(RegistryResponse.self, from: data) } catch {
            throw MCPRegistryFailure.invalidResponse
        }
        var servers: [MCPRegistryServer] = []
        var identities = Set<String>()
        for record in page.servers {
            guard record.metadata.official.status == "active",
                record.metadata.official.isLatest
            else { continue }
            let server = record.server
            guard !server.name.isEmpty, !server.version.isEmpty else {
                throw MCPRegistryFailure.invalidResponse
            }
            let endpoints = (server.remotes ?? []).compactMap { $0.supportedEndpoint }
            guard !endpoints.isEmpty else { continue }
            let listing = MCPRegistryServer(
                name: server.name, version: server.version, title: server.title,
                description: server.description, endpoints: endpoints)
            guard identities.insert(listing.id).inserted else {
                throw MCPRegistryFailure.invalidResponse
            }
            servers.append(listing)
        }
        let cursor = page.metadata.nextCursor
        return MCPRegistryPage(
            servers: servers, nextCursor: cursor.flatMap { $0.isEmpty ? nil : $0 })
    }
}

public enum MCPRegistryFailure: Error, LocalizedError, Equatable, Sendable {
    case invalidResponse, tooLarge, http(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "The MCP registry returned an invalid catalog response."
        case .tooLarge: return "The MCP registry page exceeds this app's response limit."
        case .http(let status): return "The MCP registry returned HTTP \(status). Try again later."
        }
    }
}

private struct RegistryResponse: Decodable {
    let servers: [Record]
    let metadata: PageMetadata

    struct PageMetadata: Decodable { let nextCursor: String? }
    struct Record: Decodable {
        let server: Server
        let metadata: Metadata
        enum CodingKeys: String, CodingKey { case server; case metadata = "_meta" }
    }
    struct Metadata: Decodable {
        let official: Official
        enum CodingKeys: String, CodingKey {
            case official = "io.modelcontextprotocol.registry/official"
        }
    }
    struct Official: Decodable {
        let status: String
        let isLatest: Bool
    }
    struct Server: Decodable {
        let name: String
        let version: String
        let title: String?
        let description: String?
        let remotes: [Remote]?
    }
    struct Remote: Decodable {
        let type: String
        let url: String
        let headers: [Header]?
        let variables: [String: Variable]?

        var supportedEndpoint: MCPRegistryEndpoint? {
            guard type == "streamable-http", variables?.isEmpty != false,
                !url.contains("{"), !url.contains("}"),
                let endpoint = URL(string: url), endpoint.scheme == "https",
                (try? MCPServer(name: "Catalog endpoint", endpoint: endpoint).validate()) != nil
            else { return nil }
            var requiresBearer = false
            for header in headers ?? [] {
                guard header.name.lowercased() == "authorization" else { return nil }
                if let value = header.value, !value.hasPrefix("Bearer ") { return nil }
                requiresBearer = requiresBearer || header.isRequired == true
            }
            return MCPRegistryEndpoint(url: endpoint, requiresBearerToken: requiresBearer)
        }
    }
    struct Header: Decodable {
        let name: String
        let value: String?
        let isRequired: Bool?
    }
    /// Variables are not interpreted or substituted by this client.
    struct Variable: Decodable {}
}
