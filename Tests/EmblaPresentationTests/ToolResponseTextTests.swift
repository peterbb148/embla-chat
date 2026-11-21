import Testing

@testable import EmblaPresentation

@Test func largeToolResponsePartsPreserveEveryCharacter() {
    let singleLine = String(repeating: "e\u{301}漢🐧<", count: 30_000)
    let source = singleLine + String(repeating: "\r\nNext", count: 100)
    let parts = ToolResponseText(source).parts

    #expect(parts.count > 2)
    #expect(parts.allSatisfy { $0.count <= 1_536 && $0.filter(\.isNewline).count <= 48 })
    #expect(parts.joined().utf8.elementsEqual(source.utf8))
}
