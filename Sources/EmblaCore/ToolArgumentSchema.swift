import Foundation

/// Validates the supported JSON Schema subset without changing the original JSON values.
/// Unsupported assertions fail explicitly; this is not a full JSON Schema implementation.
public enum ToolArgumentSchema {
    public static func validate(_ value: ToolJSON, schema: ToolJSON) throws {
        try checkSchema(schema, depth: 0)
        guard matches(value, schema: schema) else {
            throw ToolProtocolError.invalidArguments
        }
    }

    private static let annotations: Set<String> = [
        "$schema", "$comment", "title", "description", "default", "examples", "deprecated",
        "readOnly", "writeOnly", "x-mcp-header",
    ]
    private static let assertions: Set<String> = [
        "type", "enum", "const", "properties", "required", "additionalProperties",
        "minProperties", "maxProperties", "items", "minItems", "maxItems", "uniqueItems",
        "minLength", "maxLength", "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum",
        "multipleOf", "allOf", "anyOf", "oneOf", "not",
    ]
    private static let types: Set<String> = [
        "object", "array", "string", "number", "integer", "boolean", "null",
    ]

    /// Check every subschema, including branches not taken by this particular instance.
    private static func checkSchema(_ schema: ToolJSON, depth: Int) throws {
        guard depth < 32 else { throw ToolProtocolError.unsupportedSchema("nesting exceeds 32") }
        if case .bool = schema { return }
        guard let fields = schema.object else { throw ToolProtocolError.invalidArguments }
        for (key, value) in fields {
            guard assertions.contains(key) || annotations.contains(key) else {
                throw ToolProtocolError.unsupportedSchema(key)
            }
            switch key {
            case "$schema":
                guard value == .string("https://json-schema.org/draft/2020-12/schema") else {
                    throw ToolProtocolError.unsupportedSchema("schema dialect")
                }
            case "type":
                let names: [ToolJSON]
                if case .array(let values) = value { names = values } else { names = [value] }
                guard !names.isEmpty,
                    names.allSatisfy({ $0.string.map { types.contains($0) } == true })
                else { throw ToolProtocolError.invalidArguments }
            case "properties":
                guard let properties = value.object else {
                    throw ToolProtocolError.invalidArguments
                }
                for child in properties.values { try checkSchema(child, depth: depth + 1) }
            case "items", "additionalProperties", "not":
                try checkSchema(value, depth: depth + 1)
            case "allOf", "anyOf", "oneOf":
                guard case .array(let children) = value, !children.isEmpty else {
                    throw ToolProtocolError.invalidArguments
                }
                for child in children { try checkSchema(child, depth: depth + 1) }
            case "required":
                guard case .array(let names) = value, names.allSatisfy({ $0.string != nil }) else {
                    throw ToolProtocolError.invalidArguments
                }
            case "enum":
                guard case .array(let values) = value, !values.isEmpty else {
                    throw ToolProtocolError.invalidArguments
                }
            case "uniqueItems":
                guard case .bool = value else { throw ToolProtocolError.invalidArguments }
            case "minProperties", "maxProperties", "minItems", "maxItems", "minLength", "maxLength":
                guard let n = number(value), n >= 0, integral(n) else {
                    throw ToolProtocolError.invalidArguments
                }
            case "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf":
                guard let n = number(value), key != "multipleOf" || n > 0 else {
                    throw ToolProtocolError.invalidArguments
                }
            default: break
            }
        }
    }

    private static func matches(_ value: ToolJSON, schema: ToolJSON) -> Bool {
        if case .bool(let allowed) = schema { return allowed }
        guard let fields = schema.object else { return false }
        if let type = fields["type"] {
            let names: [ToolJSON]
            if case .array(let values) = type { names = values } else { names = [type] }
            guard names.contains(where: { hasType(value, $0.string!) }) else { return false }
        }
        if case .array(let choices) = fields["enum"], !choices.contains(where: { equal(value, $0) })
        {
            return false
        }
        if let expected = fields["const"], !equal(value, expected) { return false }
        for key in ["allOf", "anyOf", "oneOf"] {
            guard case .array(let branches) = fields[key] else { continue }
            let count = branches.filter { matches(value, schema: $0) }.count
            if key == "allOf" && count != branches.count { return false }
            if key == "anyOf" && count == 0 { return false }
            if key == "oneOf" && count != 1 { return false }
        }
        if let forbidden = fields["not"], matches(value, schema: forbidden) { return false }
        switch value {
        case .object(let object):
            if !within(Decimal(object.count), fields, "minProperties", "maxProperties") {
                return false
            }
            if case .array(let required) = fields["required"],
                !required.allSatisfy({ object[$0.string!] != nil })
            {
                return false
            }
            let properties = fields["properties"]?.object ?? [:]
            for (name, child) in object {
                if let rule = properties[name] ?? fields["additionalProperties"],
                    !matches(child, schema: rule)
                {
                    return false
                }
            }
        case .array(let array):
            if !within(Decimal(array.count), fields, "minItems", "maxItems") { return false }
            if let items = fields["items"], !array.allSatisfy({ matches($0, schema: items) }) {
                return false
            }
            if fields["uniqueItems"] == .bool(true) {
                for index in array.indices {
                    if array[..<index].contains(where: { equal($0, array[index]) }) { return false }
                }
            }
        case .string(let string):
            // JSON Schema length counts Unicode scalar values, not grapheme clusters.
            if !within(Decimal(string.unicodeScalars.count), fields, "minLength", "maxLength") {
                return false
            }
        default: break
        }
        if let n = number(value) {
            if !within(n, fields, "minimum", "maximum") { return false }
            if let bound = fields["exclusiveMinimum"].flatMap(number), n <= bound { return false }
            if let bound = fields["exclusiveMaximum"].flatMap(number), n >= bound { return false }
            if let step = fields["multipleOf"].flatMap(number) {
                var numerator = n
                var denominator = step
                var quotient = Decimal()
                guard NSDecimalDivide(&quotient, &numerator, &denominator, .plain) == .noError,
                    integral(quotient)
                else { return false }
            }
        }
        return true
    }

    private static func within(
        _ n: Decimal, _ fields: [String: ToolJSON], _ minimum: String, _ maximum: String
    ) -> Bool {
        if let bound = fields[minimum].flatMap(number), n < bound { return false }
        if let bound = fields[maximum].flatMap(number), n > bound { return false }
        return true
    }

    private static func number(_ value: ToolJSON) -> Decimal? {
        switch value {
        case .integer(let n): return Decimal(n)
        case .unsignedInteger(let n): return Decimal(string: String(n))
        case .number(let n): return n.isNaN ? nil : n
        default: return nil
        }
    }

    private static func integral(_ n: Decimal) -> Bool {
        var input = n
        var rounded = Decimal()
        NSDecimalRound(&rounded, &input, 0, .plain)
        return rounded == n
    }

    private static func hasType(_ value: ToolJSON, _ type: String) -> Bool {
        switch (type, value) {
        case ("object", .object), ("array", .array), ("string", .string),
            ("boolean", .bool), ("null", .null):
            return true
        case ("number", _): return number(value) != nil
        case ("integer", _): return number(value).map(integral) == true
        default: return false
        }
    }

    private static func equal(_ lhs: ToolJSON, _ rhs: ToolJSON) -> Bool {
        if let a = number(lhs), let b = number(rhs) { return a == b }
        switch (lhs, rhs) {
        case (.array(let a), .array(let b)):
            return a.count == b.count && zip(a, b).allSatisfy(equal)
        case (.object(let a), .object(let b)):
            return a.count == b.count
                && a.allSatisfy { key, value in
                    b[key].map { equal(value, $0) } == true
                }
        default: return lhs == rhs
        }
    }
}
