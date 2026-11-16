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

        func client(_ path: String) throws -> MCPClient {
            try MCPClient(
                server: MCPServer(
                    name: "Synthetic HTTP fixture",
                    endpoint: URL(string: "http://127.0.0.1:\(port)/\(path)")!))
        }

        func stop() { if process.isRunning { process.terminate(); process.waitUntilExit() } }
    }

    @Test func mcpNativeClientDiscoversAndCallsUsingJSONAndSSE() async throws {
        let fixture = try HTTPFixture(); defer { fixture.stop() }
        for path in ["json", "sse"] {
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

    @Test func mcpNativeClientRejectsWrongIDsAuthenticationRedirectsAndToolErrors() async throws {
        let fixture = try HTTPFixture(); defer { fixture.stop() }
        for path in ["wrong-id", "auth", "redirect"] {
            let client = try fixture.client(path)
            await #expect(throws: MCPFailure.self) { try await client.discover() }
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
#endif
