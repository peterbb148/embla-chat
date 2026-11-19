import Foundation

import EmblaCore

/// A transient, ordered catalogue for the worker. Only its selected method can be dispatched.
struct WorkerToolCatalogue {
    static let server = "catalog"
    static let pageSize = 8
    static let browse = ModelToolSpecification(
        server: server, name: "browse",
        description: "Advance to the next page of enabled tools. Call without arguments.",
        inputSchema: .object([
            "type": .string("object"), "additionalProperties": .bool(false),
        ]))
    static let previous = ModelToolSpecification(
        server: server, name: "previous",
        description: "Go back to the previous page of enabled tools. Call without arguments.",
        inputSchema: .object([
            "type": .string("object"), "additionalProperties": .bool(false),
        ]))
    static let open = ModelToolSpecification(
        server: server, name: "open",
        description: "Load the exact argument schema for an enabled method by its listed ordinal.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "ordinal": .object(["type": .string("integer"), "minimum": .integer(1)])
            ]),
            "required": .array([.string("ordinal")]), "additionalProperties": .bool(false),
        ]))

    let tools: [ModelToolSpecification]
    private(set) var page = 1
    private(set) var selected: ModelToolSpecification?

    var pageCount: Int { (tools.count + Self.pageSize - 1) / Self.pageSize }
    var passBudget: Int { 5 * (pageCount + 2) }
    var nextPage: Int? { page < pageCount ? page + 1 : nil }
    var offered: [ModelToolSpecification] {
        (nextPage == nil ? [] : [Self.browse]) + (page > 1 ? [Self.previous] : [])
            + [Self.open] + (selected.map { [$0] } ?? [])
    }

    mutating func navigate(_ tool: String, arguments: [String: ToolJSON]) throws {
        switch tool {
        case Self.browse.name:
            guard arguments.isEmpty, let nextPage else {
                throw ToolProtocolError.invalidArguments
            }
            page = nextPage
            selected = nil
        case Self.previous.name:
            guard arguments.isEmpty, page > 1 else { throw ToolProtocolError.invalidArguments }
            page -= 1
            selected = nil
        case Self.open.name:
            guard arguments.count == 1, case .integer(let value) = arguments["ordinal"],
                value > (page - 1) * Self.pageSize,
                value <= min(page * Self.pageSize, tools.count)
            else { throw ToolProtocolError.invalidArguments }
            selected = tools[Int(value) - 1]
        default:
            throw ToolProtocolError.invalidArguments
        }
    }

    mutating func reset() {
        page = 1
        selected = nil
    }

    func promptData() throws -> String {
        let start = (page - 1) * Self.pageSize
        let end = min(start + Self.pageSize, tools.count)
        let entries = (start..<end).map { index in
            ToolJSON.object([
                "ordinal": .integer(Int64(index + 1)),
                "name": .string(tools[index].functionName),
                "description_excerpt": .string(String(tools[index].description.prefix(160))),
            ])
        }
        return try ToolJSON.object([
            "page": .integer(Int64(page)),
            "next_page": nextPage.map { .integer(Int64($0)) } ?? .null,
            "previous_page": page > 1 ? .integer(Int64(page - 1)) : .null,
            "entries": .array(entries),
            "loaded_method": selected.map { .string($0.functionName) } ?? .null,
        ]).text()
    }
}

enum WorkerToolCatalogueError: LocalizedError {
    case navigationLimit
    case schemaDoesNotFit

    var errorDescription: String? {
        switch self {
        case .navigationLimit:
            return "The model exhausted its tool catalogue navigation budget."
        case .schemaDoesNotFit:
            return
                "The selected tool schema and the current request do not fit in the worker context."
        }
    }
}
