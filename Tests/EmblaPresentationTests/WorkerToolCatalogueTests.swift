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
    try catalogue.navigate("open", arguments: ["ordinal": .integer(17)])
    #expect(catalogue.selected == tools.last)
    #expect(catalogue.offered.count == 3 && catalogue.offered.last == tools.last)
    try catalogue.navigate("previous", arguments: [:])
    #expect(catalogue.page == 2 && catalogue.selected == nil)
    try catalogue.navigate("open", arguments: ["ordinal": .integer(9)])
    #expect(catalogue.selected == tools[8])
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
