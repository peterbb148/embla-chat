import Foundation
import Testing

@testable import EmblaCore

@Test func strictToolProtocolUsesNativeCallsAndRejectsPartialOrUnknownRequests() throws {
    let tool = ModelToolSpecification(
        server: "weather", name: "now", description: "Weather",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object(["city": .object(["type": .string("string")])]),
            "required": .array([.string("city")]), "additionalProperties": .bool(false),
        ]))
    let valid =
        "<tool_call>\n<function=weather__now>\n<parameter=city>\nCopenhagen\n</parameter>\n</function>\n</tool_call>"
    #expect(
        try ModelToolResponse.parse(valid, finishReason: "stop", tools: [tool])
            == .call(
                server: "weather", name: "now", arguments: ["city": .string("Copenhagen")]))
    for bad in [
        "```\n" + valid + "\n```", "Call this " + valid, valid + " trailing text",
        valid.replacingOccurrences(of: "weather__now", with: "unknown"),
        valid.replacingOccurrences(of: "</parameter>", with: ""),
        valid + valid,
    ] {
        #expect(throws: ToolProtocolError.self) {
            try ModelToolResponse.parse(bad, finishReason: "stop", tools: [tool])
        }
    }
    #expect(
        try ModelToolResponse.parse("An ordinary answer.", finishReason: "stop")
            == .answer("An ordinary answer."))
    #expect(throws: ToolProtocolError.self) {
        try ModelToolResponse.parse(valid, finishReason: "length", tools: [tool])
    }
}

@Test func mcpEndpointsAndHeaderValuesKeepCredentialsAtTheConfiguredDestination() throws {
    for raw in ["https://example.com/mcp", "http://127.0.0.1:8080/mcp"] {
        try MCPServer(name: "Test", endpoint: URL(string: raw)!).validate()
    }
    for raw in [
        "http://example.com/mcp", "https://user:token@example.com/mcp",
        "https://example.com/mcp?token=bad", "file:///tmp/mcp",
    ] {
        #expect(throws: MCPFailure.self) {
            try MCPServer(name: "Test", endpoint: URL(string: raw)!).validate()
        }
    }
    #expect(MCPClient.header("plain") == "plain")
    for raw in ["new\nline", " København ", "=?base64?literal?="] {
        let encoded = MCPClient.header(raw)
        #expect(encoded.hasPrefix("=?base64?") && encoded.hasSuffix("?="))
        #expect(
            String(
                data: Data(base64Encoded: String(encoded.dropFirst(9).dropLast(2)))!,
                encoding: .utf8) == raw)
    }
}

@Test func mcpParameterHeadersFollowOnlyStaticSchemaPathsAndSafeIntegerTypes() throws {
    let data = Data(
        #"{"type":"object","properties":{"region":{"type":"string","x-mcp-header":"Region"},"nested":{"type":"object","properties":{"count":{"type":"integer","x-mcp-header":"Count"}}}}}"#
            .utf8)
    let schema = try JSONDecoder().decode(ToolJSON.self, from: data)
    let tool = try MCPTool(name: "query", description: "Test", inputSchema: schema)
    #expect(tool.headers.count == 2)
    let count = try #require(tool.headers.first(where: { $0.name == "Count" }))
    #expect(try count.value(in: .object(["nested": .object(["count": .number(42)])])) == "42")
    #expect(throws: MCPFailure.self) {
        try count.value(in: .object(["nested": .object(["count": .number(1.5)])]))
    }
    for raw in [
        #"{"properties":{"x":{"type":"number","x-mcp-header":"X"}}}"#,
        #"{"items":{"type":"string","x-mcp-header":"X"}}"#,
        #"{"properties":{"a":{"type":"string","x-mcp-header":"X"},"b":{"type":"string","x-mcp-header":"x"}}}"#,
    ] {
        let schema = try JSONDecoder().decode(ToolJSON.self, from: Data(raw.utf8))
        #expect(throws: MCPFailure.self) {
            try MCPTool(name: "bad", description: "", inputSchema: schema)
        }
    }
}
