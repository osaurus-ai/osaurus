//
//  JSONSchemaValidator.swift
//  osaurus
//
//  Strict JSON Schema checks for workflow boundaries: the workflow input,
//  every node output, and the workflow output. Unlike `SchemaValidator`
//  (tool arguments, deliberately lenient about string-encoded scalars),
//  nothing is coerced here: a mismatch fails the node and names the path.
//
//  Supported keywords: type (single or list), enum, const, properties,
//  required, additionalProperties (bool or schema), items, minItems,
//  maxItems, minLength, maxLength, minimum, maximum, anyOf, oneOf.
//

import Foundation

public struct SchemaIssue: Equatable, Sendable, CustomStringConvertible {
    /// JSON path of the offending value, e.g. `$.client.email`.
    public var path: String
    public var message: String

    public var description: String { "\(path): \(message)" }
}

public enum JSONSchemaValidator {

    public static func validate(_ value: JSONValue, against schema: JSONValue) -> [SchemaIssue] {
        var issues: [SchemaIssue] = []
        check(value, schema, path: "$", into: &issues)
        return issues
    }

    private static let knownTypes: Set<String> = ["string", "number", "integer", "boolean", "object", "array", "null"]

    private static func types(of schema: [String: JSONValue]) -> [String]? {
        switch schema["type"] {
        case .string(let t)?: return [t]
        case .array(let list)?: return list.compactMap(\.stringValue)
        default: return nil
        }
    }

    private static func matches(_ value: JSONValue, type: String) -> Bool {
        switch (type, value) {
        case ("string", .string), ("boolean", .bool), ("object", .object), ("array", .array), ("null", .null):
            return true
        case ("number", .number):
            return true
        case ("integer", .number(let n)):
            return n.rounded() == n
        default:
            return false
        }
    }

    private static func typeName(_ value: JSONValue) -> String {
        switch value {
        case .string: return "string"
        case .number: return "number"
        case .bool: return "boolean"
        case .object: return "object"
        case .array: return "array"
        case .null: return "null"
        }
    }

    private static func check(_ value: JSONValue, _ schemaValue: JSONValue, path: String, into issues: inout [SchemaIssue]) {
        guard case .object(let schema) = schemaValue else {
            if case .bool(false) = schemaValue { issues.append(SchemaIssue(path: path, message: "not allowed")) }
            return
        }

        if let ts = types(of: schema), !ts.isEmpty, !ts.contains(where: { matches(value, type: $0) }) {
            issues.append(SchemaIssue(path: path, message: "expected \(ts.joined(separator: " or ")), got \(typeName(value))"))
            return
        }
        if case .array(let options)? = schema["enum"], !options.contains(value) {
            let list = options.map { BindingRenderer.textValue($0) }.joined(separator: ", ")
            issues.append(SchemaIssue(path: path, message: "must be one of: \(list)"))
        }
        if let constant = schema["const"], constant != value {
            issues.append(SchemaIssue(path: path, message: "must equal \(constant.compactJSONString)"))
        }

        for key in ["anyOf", "oneOf"] {
            guard case .array(let branches)? = schema[key] else { continue }
            let passing = branches.filter { validate(value, against: $0).isEmpty }.count
            if key == "anyOf", passing == 0 {
                issues.append(SchemaIssue(path: path, message: "matches none of the allowed shapes"))
            } else if key == "oneOf", passing != 1 {
                issues.append(SchemaIssue(path: path, message: "must match exactly one allowed shape, matched \(passing)"))
            }
        }

        switch value {
        case .object(let obj):
            let props = schema["properties"]?.objectValue ?? [:]
            if case .array(let required)? = schema["required"] {
                for key in required.compactMap(\.stringValue) where obj[key] == nil {
                    issues.append(SchemaIssue(path: "\(path).\(key)", message: "is required"))
                }
            }
            for (key, child) in obj {
                if let propSchema = props[key] {
                    check(child, propSchema, path: "\(path).\(key)", into: &issues)
                } else {
                    switch schema["additionalProperties"] {
                    case .bool(false)?:
                        issues.append(SchemaIssue(path: "\(path).\(key)", message: "is not an allowed property"))
                    case .object(let extra)?:
                        check(child, .object(extra), path: "\(path).\(key)", into: &issues)
                    default:
                        break
                    }
                }
            }
        case .array(let list):
            if let items = schema["items"] {
                for (i, item) in list.enumerated() { check(item, items, path: "\(path)[\(i)]", into: &issues) }
            }
            if case .number(let min)? = schema["minItems"], Double(list.count) < min {
                issues.append(SchemaIssue(path: path, message: "needs at least \(Int(min)) items"))
            }
            if case .number(let max)? = schema["maxItems"], Double(list.count) > max {
                issues.append(SchemaIssue(path: path, message: "allows at most \(Int(max)) items"))
            }
        case .string(let s):
            if case .number(let min)? = schema["minLength"], Double(s.count) < min {
                issues.append(SchemaIssue(path: path, message: "needs at least \(Int(min)) characters"))
            }
            if case .number(let max)? = schema["maxLength"], Double(s.count) > max {
                issues.append(SchemaIssue(path: path, message: "allows at most \(Int(max)) characters"))
            }
        case .number(let n):
            if case .number(let min)? = schema["minimum"], n < min {
                issues.append(SchemaIssue(path: path, message: "must be at least \(BindingRenderer.textValue(.number(min)))"))
            }
            if case .number(let max)? = schema["maximum"], n > max {
                issues.append(SchemaIssue(path: path, message: "must be at most \(BindingRenderer.textValue(.number(max)))"))
            }
        default:
            break
        }
    }

    /// Well-formedness of a schema itself (not of a value).
    public static func schemaIssues(_ schema: JSONValue, path: String = "$") -> [SchemaIssue] {
        guard case .object(let obj) = schema else {
            return [SchemaIssue(path: path, message: "a schema must be an object")]
        }
        var issues: [SchemaIssue] = []
        if let raw = obj["type"] {
            let names: [String]
            switch raw {
            case .string(let t): names = [t]
            case .array(let list): names = list.compactMap(\.stringValue)
            default:
                names = []
                issues.append(SchemaIssue(path: path, message: "`type` must be a string or a list of strings"))
            }
            for n in names where !knownTypes.contains(n) {
                issues.append(SchemaIssue(path: path, message: "unknown type `\(n)`"))
            }
        }
        if let props = obj["properties"] {
            guard case .object(let map) = props else {
                issues.append(SchemaIssue(path: path, message: "`properties` must be an object"))
                return issues
            }
            for (key, child) in map { issues += schemaIssues(child, path: "\(path).\(key)") }
        }
        if let req = obj["required"] {
            if case .array(let list) = req, list.allSatisfy({ $0.stringValue != nil }) {
                let declared = Set((obj["properties"]?.objectValue ?? [:]).keys)
                for key in list.compactMap(\.stringValue) where !declared.contains(key) && obj["properties"] != nil {
                    issues.append(SchemaIssue(path: path, message: "`required` names undeclared property `\(key)`"))
                }
            } else {
                issues.append(SchemaIssue(path: path, message: "`required` must be a list of property names"))
            }
        }
        if let items = obj["items"] { issues += schemaIssues(items, path: "\(path)[]") }
        if let e = obj["enum"], case .array = e {} else if obj["enum"] != nil {
            issues.append(SchemaIssue(path: path, message: "`enum` must be a list"))
        }
        return issues
    }
}
