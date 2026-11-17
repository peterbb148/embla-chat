import Foundation
import Testing

@testable import EmblaCore

#if os(macOS)
    /// Actual loopback HTTP against a clearly synthetic fixture; no public service or model claim.
    private final class HTTPFixture {
        let process = Process()
        let port: Int

        init() throws {
            let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Fixtures/mcp_server.py")
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", fixture.path]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = pipe.fileHandleForReading.availableData
            port = try #require(
                Int(
                    String(decoding: data, as: UTF8.self).trimmingCharacters(
                        in: .whitespacesAndNewlines)))
        }

        func client(
            _ path: String, network: NetworkAccess = NetworkAccess(initialState: .satisfied),
            timeouts: MCPClient.Timeouts = .init()
        ) throws -> MCPClient {
            try MCPClient(
                server: MCPServer(
                    name: "Synthetic HTTP fixture",
                    endpoint: URL(string: "http://127.0.0.1:\(port)/\(path)")!),
                network: network, timeouts: timeouts)
        }

        func counts() async throws -> [String: [String: Int]] {
            let url = URL(string: "http://127.0.0.1:\(port)/request-counts")!
            let (data, _) = try await URLSession.shared.data(from: url)
            return try JSONDecoder().decode([String: [String: Int]].self, from: data)
        }

        func stop() { if process.isRunning { process.terminate(); process.waitUntilExit() } }
    }

    @Test func mcpNativeClientDiscoversAndCallsUsingJSONAndSSE() async throws {
        let fixture = try HTTPFixture(); defer { fixture.stop() }
        for path in ["json", "sse", "sse-cr", "sse-bom"] {
            let client = try fixture.client(path)
            let discovery = try await client.discover()
            let tool = try #require(discovery.tools.first)
            let result = try await client.call(tool, arguments: ["text": .string("København\n")])
            #expect(
                result["content"]
                    == .array([.object(["type": .string("text"), "text": .string("København\n")])]))
            #expect(
                result["structuredContent"]?["header"] == .string(MCPClient.header("København\n")))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func discoverySharesOneAbsoluteDeadlineAcrossInformationAndCatalogPages() async throws {
        let fixture = try HTTPFixture(); defer { fixture.stop() }
        let enough = try fixture.client(
            "paged-discovery", timeouts: .init(discovery: 2, toolCall: 2))
        #expect(try await enough.discover().tools.count == 2)
        let short = try fixture.client(
            "paged-discovery", timeouts: .init(discovery: 0.2, toolCall: 2))
        do {
            _ = try await short.discover()
            Issue.record("Each 80 ms RPC fits alone, but the three-RPC discovery exceeds 200 ms")
        } catch MCPFailure.requestTimedOut {
        } catch { Issue.record("Unexpected discovery error: \(error)") }
    }

    @Test(.timeLimit(.minutes(1)))
    func toolCallCanOutliveTheShortDiscoveryDeadlineWithoutReissuingIt() async throws {
        let fixture = try HTTPFixture(); defer { fixture.stop() }
        // Discovery is setup, not the operation under this short-budget assertion.
        // Give it the normal budget so concurrent package tests cannot consume 200 ms.
        let discovery = try fixture.client("delayed-tool")
        let tool = try #require(try await discovery.discover().tools.first)
        let client = try fixture.client(
            "delayed-tool", timeouts: .init(discovery: 0.2, toolCall: 2))
        let result = try await client.call(tool, arguments: ["text": .string("Delayed real response")])
        #expect(result["content"] == .array([
            .object(["type": .string("text"), "text": .string("Delayed real response")])
        ]))
        #expect(try await fixture.counts()["/delayed-tool"]?["tools/call"] == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func discoveryAndToolDeadlinesCoverHeadersAndActiveSSEKeepAlives() async throws {
        let fixture = try HTTPFixture(); defer { fixture.stop() }
        let discovery = try fixture.client(
            "delayed-discovery", timeouts: .init(discovery: 0.1, toolCall: 2))
        do {
            _ = try await discovery.discover()
            Issue.record("Delayed discovery must respect its short absolute deadline")
        } catch MCPFailure.requestTimedOut {
            // Both the explicit deadline and native URLSession expiry use this error.
        } catch { Issue.record("Unexpected timeout error: \(error)") }
        #expect(try await fixture.counts()["/delayed-discovery"]?["server/discover"] == 1)
        for path in ["delayed-tool", "progress-tool"] {
            let client = try fixture.client(path, timeouts: .init(discovery: 1, toolCall: 0.2))
            let tool = try #require(try await client.discover().tools.first)
            do {
                _ = try await client.call(tool, arguments: ["text": .string("Must expire")])
                Issue.record("Tool request must expire even while SSE keep-alives arrive")
            } catch MCPFailure.requestTimedOut {
                // Both the explicit deadline and native URLSession expiry use this error.
            } catch { Issue.record("Unexpected timeout error: \(error)") }
            #expect(try await fixture.counts()["/" + path]?["tools/call"] == 1)
            // Discovery still works; timing out one request must not invalidate the client session.
            _ = try await client.discover()
            #expect(try await fixture.counts()["/" + path]?["tools/call"] == 1)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func extendedToolWaitStillCancelsItsSocketAndNeverReplaysOnReconnect(_ privacy: Bool)
        async throws
    {
        let fixture = try HTTPFixture(); defer { fixture.stop() }
        let access = NetworkAccess(initialState: .satisfied)
        let client = try fixture.client(
            "progress-tool", network: access, timeouts: .init(discovery: 1, toolCall: 2))
        let tool = try #require(try await client.discover().tools.first)
        let pending = Task { try await client.call(tool, arguments: ["text": .string("Wait")]) }
        let clock = ContinuousClock(); let started = clock.now
        while try await fixture.counts()["/progress-tool"]?["tools/call"] != 1,
            clock.now - started < .seconds(5)
        { try await Task.sleep(for: .milliseconds(5)) }
        try #require(try await fixture.counts()["/progress-tool"]?["tools/call"] == 1)
        if privacy { access.updatePath(.unsatisfied) } else { pending.cancel() }
        do {
            _ = try await pending.value
            Issue.record("Cancelled tool call must not return a late result")
        } catch {
            if privacy { #expect(error as? NetworkAccessFailure == .offline) }
            else { #expect(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        }
        access.updatePath(.satisfied)
        access.activateRequests(after: access.snapshot.revision)
        while try await fixture.counts()["/progress-tool"]?["disconnected"] == nil,
            clock.now - started < .seconds(5)
        { try await Task.sleep(for: .milliseconds(10)) }
        #expect(try await fixture.counts()["/progress-tool"]?["disconnected"] != nil)
        #expect(try await fixture.counts()["/progress-tool"]?["tools/call"] == 1)
    }

    @Test func mcpNativeClientRejectsWrongIDsAuthenticationRedirectsAndToolErrors() async throws {
        let fixture = try HTTPFixture(); defer { fixture.stop() }
        for path in ["wrong-id", "auth", "redirect", "invalid-utf8"] {
            let client = try fixture.client(path)
            await #expect(throws: MCPFailure.self) { try await client.discover() }
        }
        for path in [
            "missing-content", "bad-content", "bad-text", "bad-error-flag", "numeric-overflow",
        ] {
            let client = try fixture.client(path)
            let tool = try #require(try await client.discover().tools.first)
            await #expect(throws: MCPFailure.self) {
                try await client.call(tool, arguments: ["text": .string("Synthetic shape test")])
            }
        }
        let client = try fixture.client("tool-error")
        let tool = try #require(try await client.discover().tools.first)
        do {
            _ = try await client.call(
                tool, arguments: ["text": .string("Synthetic failure detail")])
            Issue.record("Server isError result must not become a successful tool result")
        } catch MCPFailure.toolError(let result) {
            #expect(try result.text().contains("Synthetic failure detail"))
        }
        let rpc = try fixture.client("rpc-error")
        do {
            _ = try await rpc.discover()
            Issue.record("Expected actual JSON-RPC error")
        } catch MCPFailure.rpc(let detail) {
            #expect(detail["code"] == .integer(-32602))
            #expect(detail["message"] == .string("Synthetic invalid timezone"))
            #expect(detail["data"]?["field"] == .string("timezone"))
        }
        let httpRPC = try fixture.client("rpc-error-http")
        do {
            _ = try await httpRPC.discover()
            Issue.record("Expected HTTP/protocol error with actual details")
        } catch MCPFailure.httpRPC(let status, let detail) {
            #expect(status == 400)
            #expect(detail["message"] == .string("Synthetic invalid timezone"))
            #expect(detail["data"]?["reason"] == .string("Fixture detail"))
        }
    }

    @Test(.timeLimit(.minutes(1))) func mcpNativeClientCancellationClosesThePendingSSERequest()
        async throws
    {
        let fixture = try HTTPFixture(); defer { fixture.stop() }
        let client = try fixture.client("slow")
        let task = Task { try await client.discover() }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        do {
            _ = try await task.value;
            Issue.record("Cancelled network work must not publish a result")
        } catch { #expect(error is CancellationError || (error as? URLError)?.code == .cancelled) }
    }
    @Test func offlineGateBlocksCachedCallsDiscoveryAndReplayUntilExplicitRetry() async throws {
        let fixture = try HTTPFixture(); defer { fixture.stop() }
        let access = NetworkAccess(initialState: .satisfied)
        let client = try fixture.client("json", network: access)
        let catalog = try await client.discover()
        let tool = try #require(catalog.tools.first)
        let before = try await fixture.counts()
        access.updatePath(.unsatisfied)
        await #expect(throws: NetworkAccessFailure.offline) { try await client.discover() }
        await #expect(throws: NetworkAccessFailure.offline) {
            try await client.call(tool, arguments: ["text": .string("Must not reach fixture")])
        }
        #expect(try await fixture.counts() == before)
        access.updatePath(.satisfied)
        await #expect(throws: NetworkAccessFailure.checking) { try await client.discover() }
        access.activateRequests(after: access.snapshot.revision)
        try await Task.sleep(for: .milliseconds(50))
        #expect(try await fixture.counts() == before)
        _ = try await client.call(tool, arguments: ["text": .string("Explicit retry")])
        #expect(try await fixture.counts()["/json"]?["tools/call"] == 1)
    }

    @Test(.timeLimit(.minutes(1))) func pathLossCancelsAPendingRequestWithItsPrivacyReason()
        async throws
    {
        let fixture = try HTTPFixture(); defer { fixture.stop() }
        let access = NetworkAccess(initialState: .satisfied)
        let client = try fixture.client("slow", network: access)
        let pending = Task { try await client.discover() }
        let clock = ContinuousClock(); let started = clock.now
        while try await fixture.counts()["/slow"]?["server/discover"] != 1,
            clock.now - started < .seconds(10)
        { try await Task.sleep(for: .milliseconds(5)) }
        try #require(try await fixture.counts()["/slow"]?["server/discover"] == 1)
        access.updatePath(.unsatisfied)
        await #expect(throws: NetworkAccessFailure.offline) { try await pending.value }
        #expect(try await fixture.counts()["/slow"]?["tools/list"] == nil)
    }
    @Test func onDemandConnectivityUpgradePreservesAnInflightRequestLease() async throws {
        let fixture = try HTTPFixture(); defer { fixture.stop() }
        let access = NetworkAccess(initialState: .requiresConnection)
        let client = try fixture.client("slow", network: access)
        let pending = Task { try await client.discover() }
        defer { pending.cancel() }
        let clock = ContinuousClock(); let started = clock.now
        while try await fixture.counts()["/slow"]?["server/discover"] != 1,
            clock.now - started < .seconds(10)
        { try await Task.sleep(for: .milliseconds(5)) }
        try #require(try await fixture.counts()["/slow"]?["server/discover"] == 1)
        access.updatePath(.satisfied)
        #expect(access.snapshot.allowsRequests && !access.snapshot.localOnly)
        try access.check()
        pending.cancel()
        do {
            _ = try await pending.value
            Issue.record("The slow fixture should finish only after explicit cancellation.")
        } catch {
            #expect(error is CancellationError || (error as? URLError)?.code == .cancelled)
        }
    }
#endif
