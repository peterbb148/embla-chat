import Foundation
import Testing

@testable import EmblaCore

/// Synthetic catalog transport; production always uses the official anonymous HTTPS session.
private final class RegistryWireFixture: URLProtocol, @unchecked Sendable {
    private struct Reply: Sendable { let status: Int; let data: Data }
    private final class Book: @unchecked Sendable {
        let lock = NSLock()
        var replies: [String: Reply] = [:]
        var requests: [String: URLRequest] = [:]
    }
    private static let book = Book()

    static func session(for request: URLRequest, status: Int = 200, data: Data) -> URLSession {
        book.lock.withLock { book.replies[request.url!.absoluteString] = Reply(
            status: status, data: data) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RegistryWireFixture.self]
        return URLSession(configuration: configuration)
    }

    static func observed(_ request: URLRequest) -> URLRequest? {
        book.lock.withLock { book.requests[request.url!.absoluteString] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let key = request.url!.absoluteString
        let reply = Self.book.lock.withLock {
            Self.book.requests[key] = request
            return Self.book.replies.removeValue(forKey: key)
        }
        guard let reply else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func registryRecord(
    _ name: String, latest: Bool = true, status: String = "active",
    remotes: [[String: Any]]? = [["type": "streamable-http", "url": "https://example.invalid/mcp"]]
) -> [String: Any] {
    var server: [String: Any] = [
        "name": name, "version": "1.0", "title": "Synthetic catalog", "description": "Fixture.",
    ]
    if let remotes { server["remotes"] = remotes }
    return [
        "server": server,
        "_meta": ["io.modelcontextprotocol.registry/official": [
            "status": status, "isLatest": latest,
        ]],
    ]
}

private func registryPage(_ records: [[String: Any]], cursor: String? = nil) throws -> Data {
    var metadata: [String: Any] = [:]
    if let cursor { metadata["nextCursor"] = cursor }
    return try JSONSerialization.data(withJSONObject: ["servers": records, "metadata": metadata])
}

@Test func registryFiltersLifecycleAndUnsupportedConnectionsWithoutMergingPublishers() throws {
    let page = try MCPRegistryClient.decode(registryPage([
        registryRecord("one/reader"),
        registryRecord("two/reader", remotes: [[
            "type": "streamable-http", "url": "https://example.invalid/mcp",
            "headers": [["name": "Authorization", "value": "Bearer {token}", "isRequired": true]],
        ]]),
        registryRecord("older/version", latest: false),
        registryRecord("inactive/server", status: "deprecated"),
        registryRecord("local/only", remotes: nil),
        registryRecord(
            "legacy/sse", remotes: [["type": "sse", "url": "https://example.invalid/sse"]]),
        registryRecord("custom/header", remotes: [[
            "type": "streamable-http", "url": "https://example.invalid/mcp",
            "headers": [["name": "X-API-Key", "isRequired": true]],
        ]]),
        registryRecord("variable/url", remotes: [[
            "type": "streamable-http", "url": "https://example.invalid/{tenant}/mcp",
            "variables": ["tenant": ["description": "Choose tenant"]],
        ]]),
        registryRecord("query/key", remotes: [[
            "type": "streamable-http", "url": "https://example.invalid/mcp?key=fixture",
        ]]),
    ], cursor: "opaque:next/+&"))
    #expect(page.servers.map(\.name) == ["one/reader", "two/reader"])
    #expect(page.servers[0].endpoints[0].url == page.servers[1].endpoints[0].url)
    #expect(!page.servers[0].endpoints[0].requiresBearerToken)
    #expect(page.servers[1].endpoints[0].requiresBearerToken)
    #expect(page.nextCursor == "opaque:next/+&")
    let server = MCPServer(
        name: page.servers[0].displayName, endpoint: page.servers[0].endpoints[0].url)
    #expect(server.enableToolsOnFirstDiscovery && server.enabledTools.isEmpty)
}

@Test func registryPaginationPreservesOpaqueCursorSearchAndAnonymousRequests() async throws {
    let search = "fixture-\(UUID())&limit=999"
    let cursor = "opaque:/+?&=next"
    for next in [nil, cursor] as [String?] {
        let request = MCPRegistryClient.request(search: search, cursor: next)
        let data = try registryPage([registryRecord("synthetic/\(next == nil ? "one" : "two")")])
        let session = RegistryWireFixture.session(for: request, data: data)
        let client = MCPRegistryClient(session: session)
        let page = try await client.page(search: search, cursor: next)
        #expect(page.servers.count == 1 && page.nextCursor == nil)
        let observed = try #require(RegistryWireFixture.observed(request))
        let items = try #require(URLComponents(url: observed.url!, resolvingAgainstBaseURL: false))
            .queryItems ?? []
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value) })
        #expect(values["version"] == "latest")
        #expect(values["search"] == search)
        #expect(values["limit"] == "20")
        #expect(values["cursor"] == next.map { Optional($0) })
        #expect(observed.httpMethod == "GET")
        #expect(observed.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(observed.value(forHTTPHeaderField: "Cookie") == nil)
    }
}

@Test(arguments: [401, 429, 503])
func registryHTTPFailuresNeverBecomeAnEmptySuccessfulCatalog(_ status: Int) async throws {
    let query = UUID().uuidString
    let request = MCPRegistryClient.request(search: query, cursor: nil)
    let session = RegistryWireFixture.session(
        for: request, status: status, data: try registryPage([]))
    let client = MCPRegistryClient(session: session)
    await #expect(throws: MCPRegistryFailure.http(status)) {
        try await client.page(search: query)
    }
}

@Test func invalidRegistryJSONAndDuplicateRecordIdentitiesFailClearly() throws {
    for data in [Data("not JSON".utf8), Data(#"{"servers":[]}"#.utf8),
                 try registryPage([registryRecord("same/id"), registryRecord("same/id")])] {
        #expect(throws: MCPRegistryFailure.invalidResponse) {
            try MCPRegistryClient.decode(data)
        }
    }
    let empty = try MCPRegistryClient.decode(registryPage([], cursor: ""))
    #expect(empty.servers.isEmpty && empty.nextCursor == nil)
}

@Test func registryRejectsOversizedWireResponseBeforeParsing() async throws {
    let query = UUID().uuidString
    let request = MCPRegistryClient.request(search: query, cursor: nil)
    let session = RegistryWireFixture.session(
        for: request, data: Data(repeating: 32, count: 2_097_153))
    let client = MCPRegistryClient(session: session)
    await #expect(throws: MCPRegistryFailure.tooLarge) {
        try await client.page(search: query)
    }
}
