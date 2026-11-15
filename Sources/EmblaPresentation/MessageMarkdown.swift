import Foundation

/// Native Markdown blocks, retaining inline attributes and exact fenced-code whitespace.
public struct MessageMarkdown {
    public struct Block: Identifiable {
        public enum Style: Equatable {
            case prose
            case heading(Int)
            case code(String?)
            case listItem(String, showsMarker: Bool = true)
            case quote
        }

        public let id: Int
        public let style: Style
        public let listDepth: Int
        public var text: AttributedString
        public var plainText: String { String(text.characters) }
    }

    public let blocks: [Block]

    /// Parse using Foundation's Markdown grammar, including incomplete streamed fences.
    public init(_ source: String) throws {
        let parsed = try AttributedString(markdown: source)
        var result: [Block] = []
        var markedItems: Set<Int> = []
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            let identity = components.first?.identity ?? 0
            let listDepth = components.filter {
                $0.kind == .orderedList || $0.kind == .unorderedList
            }.count
            var style = Block.Style.prose
            if let first = components.first {
                switch first.kind {
                case .header(level: let level): style = .heading(level)
                case .codeBlock(languageHint: let language): style = .code(language)
                default: break
                }
            }
            if style == .prose,
               let itemIndex = components.firstIndex(where: {
                   if case .listItem = $0.kind { return true }
                   return false
               }), case .listItem(ordinal: let ordinal) = components[itemIndex].kind {
                let container = components.dropFirst(itemIndex + 1).first {
                    $0.kind == .orderedList || $0.kind == .unorderedList
                }
                let itemID = components[itemIndex].identity
                let newBlock = result.last?.id != identity
                let firstParagraph = !markedItems.contains(itemID)
                style = .listItem(
                    container?.kind == .orderedList ? "\(ordinal)." : "•",
                    showsMarker: firstParagraph)
                if newBlock { markedItems.insert(itemID) }
            } else if style == .prose && components.contains(where: { $0.kind == .blockQuote }) {
                style = .quote
            }
            var text = AttributedString(parsed[run.range])
            text.presentationIntent = nil
            if result.last?.id == identity {
                result[result.count - 1].text.append(text)
            } else {
                result.append(Block(id: identity, style: style, listDepth: listDepth, text: text))
            }
        }
        blocks = result
    }
}
