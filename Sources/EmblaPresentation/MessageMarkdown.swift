import Foundation

/// Native Markdown blocks, retaining inline attributes and exact fenced-code whitespace.
public struct MessageMarkdown {
    public struct Block: Identifiable {
        public enum Style: Equatable {
            case prose
            case heading(Int)
            case code(String?)
            case listItem(String)
            case quote
        }

        public let id: Int
        public let style: Style
        public var text: AttributedString
        public var plainText: String { String(text.characters) }
    }

    public let blocks: [Block]

    /// Parse using Foundation's Markdown grammar, including incomplete streamed fences.
    public init(_ source: String) throws {
        let parsed = try AttributedString(markdown: source)
        var result: [Block] = []
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            let identity = components.first?.identity ?? 0
            var style = Block.Style.prose
            for component in components {
                switch component.kind {
                case .header(level: let level): style = .heading(level)
                case .codeBlock(languageHint: let language): style = .code(language)
                case .listItem(ordinal: let ordinal):
                    let ordered = components.contains { $0.kind == .orderedList }
                    style = .listItem(ordered ? "\(ordinal)." : "•")
                case .blockQuote:
                    if style == .prose { style = .quote }
                default: break
                }
            }
            var text = AttributedString(parsed[run.range])
            text.presentationIntent = nil
            if result.last?.id == identity {
                result[result.count - 1].text.append(text)
            } else {
                result.append(Block(id: identity, style: style, text: text))
            }
        }
        blocks = result
    }
}
