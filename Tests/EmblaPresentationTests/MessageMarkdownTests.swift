import Foundation
import Testing
@testable import EmblaPresentation

@Test func markdownKeepsBlockStructureAndInlineEmphasis() throws {
    let document = try MessageMarkdown("# Heading\n\nHello **world** and `code`.\n\n- one\n- two\n\n> quoted")
    #expect(document.blocks.map(\.style) == [
        .heading(1), .prose, .listItem("•"), .listItem("•"), .quote,
    ])
    #expect(document.blocks.map(\.plainText) == [
        "Heading", "Hello world and code.", "one", "two", "quoted",
    ])
    let runs = document.blocks[1].text.runs
    #expect(runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
    #expect(runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
}

@Test func codeBlocksPreserveWhitespaceAndDoNotInterpretMarkdownAsFormatting() throws {
    let code = "let text = \"**literal**\"\n\tprint(text)\n\n"
    let blocks = try MessageMarkdown("Before\n\n```swift\n\(code)```\n\nAfter").blocks
    #expect(blocks.count == 3)
    #expect(blocks[1].style == .code("swift"))
    #expect(blocks[1].plainText == code)
    #expect(blocks[1].text.runs.allSatisfy {
        $0.inlinePresentationIntent?.contains(.stronglyEmphasized) != true
    })
}

@Test func incompleteStreamingFencesStillDisplayTheirActualCode() throws {
    let block = try #require(MessageMarkdown("```python\n  print(1)").blocks.first)
    #expect(block.style == .code("python"))
    #expect(block.plainText.hasPrefix("  print(1)"))
    let ordered = try MessageMarkdown("3. third\n4. fourth").blocks
    #expect(ordered.map(\.style) == [.listItem("3."), .listItem("4.")])
}
