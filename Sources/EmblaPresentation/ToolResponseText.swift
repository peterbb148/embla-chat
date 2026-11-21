/// Splits raw tool text into small renderable ranges without changing any characters.
public struct ToolResponseText {
    public let parts: [Substring]

    public init(_ source: String) {
        var parts: [Substring] = []
        var start = source.startIndex
        var characterCount = 0
        var lineBreakCount = 0

        for index in source.indices {
            if characterCount == 1_536 || lineBreakCount == 48 {
                parts.append(source[start..<index])
                start = index
                characterCount = 0
                lineBreakCount = 0
            }
            characterCount += 1
            if source[index].isNewline { lineBreakCount += 1 }
        }
        if start < source.endIndex { parts.append(source[start...]) }
        self.parts = parts
    }
}
