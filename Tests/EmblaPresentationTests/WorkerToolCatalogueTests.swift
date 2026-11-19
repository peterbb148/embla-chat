import Foundation
import Testing

import EmblaCore
@testable import EmblaPresentation

@Test func cataloguePagesCoverEveryEnabledToolAndPinOneExactSchema() throws {
    let tools = (1...17).map { index in
        ModelToolSpecification(
            server: "mcp_fixture", name: "method_\(index)", description: "Fixture description",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(["record": .object(["const": .integer(Int64(index))])]),
            ]))
    }
    var catalogue = WorkerToolCatalogue(tools: tools)
    #expect(catalogue.nextPage == 2)
    #expect(!((try catalogue.promptData()).contains("method_17")))
    #expect(throws: ToolProtocolError.self) {
        try catalogue.navigate("open", arguments: ["ordinal": .integer(17)])
    }
    #expect(throws: ToolProtocolError.self) {
        try catalogue.navigate("browse", arguments: ["page": .integer(3)])
    }
    try catalogue.navigate("browse", arguments: [:])
    #expect((try catalogue.promptData()).contains("method_16"))
    try catalogue.navigate("browse", arguments: [:])
    #expect(catalogue.nextPage == nil)
    #expect(catalogue.callable.contains(tools[16]) && !catalogue.callable.contains(tools[0]))
    #expect(!catalogue.offered.contains(tools[16]))
    let directCall = """
        <tool_call>
        <function=mcp_fixture__method_17>
        <parameter=record>
        17
        </parameter>
        </function>
        </tool_call>
        """
    #expect(
        try ModelToolResponse.parse(directCall, finishReason: "stop", tools: catalogue.callable)
            == .call(server: "mcp_fixture", name: "method_17", arguments: ["record": .integer(17)]))
    #expect(throws: ToolProtocolError.self) {
        try ModelToolResponse.parse(
            directCall.replacingOccurrences(of: "\n17\n", with: "\n16\n"),
            finishReason: "stop", tools: catalogue.callable)
    }
    try catalogue.navigate("open", arguments: ["ordinal": .integer(17)])
    #expect(catalogue.selected == tools.last)
    #expect(catalogue.offered.count == 3 && catalogue.offered.last == tools.last)
    try catalogue.navigate("previous", arguments: [:])
    #expect(catalogue.page == 2 && catalogue.selected == nil)
    try catalogue.navigate("open", arguments: ["ordinal": .integer(9)])
    #expect(catalogue.selected == tools[8])
    let originalBudget = catalogue.passBudget
    let narrowed = catalogue.narrowPage()
    #expect(narrowed)
    #expect(catalogue.page == 3 && catalogue.selected == tools[8])
    #expect(catalogue.passBudget > originalBudget)
    let furtherNarrowing = (0..<3).map { _ in catalogue.narrowPage() }
    #expect(furtherNarrowing == [true, true, false])
    #expect(catalogue.page == 9 && catalogue.selected == tools[8])
    #expect(catalogue.callable.filter { $0.server == "mcp_fixture" } == [tools[8]])
    try catalogue.navigate("browse", arguments: [:])
    #expect(catalogue.page == 10 && catalogue.selected == nil)
    #expect(catalogue.callable.contains(tools[9]))
    catalogue.reset()
    #expect(catalogue.page == 1 && catalogue.selected == nil)
}

@Test func oversizedCapabilityDescriptionsStayOutOfTheMainPrompt() throws {
    let tools = (1...24).map { count in
        ModelToolSpecification(
            server: "mcp_example", name: "example_\(count)",
            description: String(repeating: "long capability description ", count: 100),
            inputSchema: .object(["type": .string("object")]))
    }
    let prompt = try ToolWorkerHandoff.instructions(tools: tools)
    #expect(prompt.contains("example_24"))
    #expect(!prompt.contains("long capability description"))
}
