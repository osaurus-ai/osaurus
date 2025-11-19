//
//  SchemaValidator.swift
//  OsaurusCore
//
//  Minimal JSON Schema validator for tool arguments.
//  Supports: type (object/string/integer/number/boolean/array), properties, required, enum (strings or numbers).
//

import Foundation

struct SchemaValidator {
    struct ValidationResult {
        let isValid: Bool
        let errorMessage: String?

        static func ok() -> ValidationResult { .init(isValid: true, errorMessage: nil) }
        static func fail(_ message: String) -> ValidationResult { .init(isValid: false, errorMessage: message) }
    }

    static func validate(arguments: Any, against schema: JSONValue) -> ValidationResult {
        guard case .object(let schemaObj) = schema else {
            return .fail("Schema must be an object")
        }
        // Top-level type: expect object
        if let typeVal = schemaObj["type"], case .string(let t) = typeVal, t != "object" {
            // If not object, validate the raw value directly as a scalar
            return validateScalar(value: arguments, schemaObject: schemaObj)
        }
        // Validate object with properties/required
        guard let dict = arguments as? [String: Any] else {
            return .fail("Arguments must be an object")
        }
        return validateObject(dict, schemaObject: schemaObj)
    }

    // MARK: - Object validation
    private static func validateObject(_ obj: [String: Any], schemaObject: [String: JSONValue]) -> ValidationResult {
        // required
        var required: [String] = []
        if let reqVal = schemaObject["required"], case .array(let arr) = reqVal {
            required = arr.compactMap {
                if case .string(let s) = $0 { return s }
                return nil
            }
        }
        for key in required {
            if obj[key] == nil || obj[key] is NSNull {
                return .fail("Missing required property: \(key)")
            }
        }
        // properties
        var properties: [String: JSONValue] = [:]
        if let propsVal = schemaObject["properties"], case .object(let props) = propsVal {
            properties = props
        }
        for (key, value) in obj {
            guard let propSchemaVal = properties[key] else { continue }
            guard case .object(let propSchemaObj) = propSchemaVal else {
                continue
            }
            // If property declares a type, validate accordingly
            if let typeVal = propSchemaObj["type"], case .string(let t) = typeVal {
                switch t {
                case "object":
                    // nested object validation if nested properties exist
                    if let nestedPropsVal = propSchemaObj["properties"], case .object = nestedPropsVal {
                        if let dict = value as? [String: Any] {
                            let res = validateObject(dict, schemaObject: propSchemaObj)
                            if !res.isValid { return res }
                        } else {
                            return .fail("Property '\(key)' must be an object")
                        }
                    } else if !(value is [String: Any]) {
                        return .fail("Property '\(key)' must be an object")
                    }
                case "array":
                    guard let arr = value as? [Any] else {
                        return .fail("Property '\(key)' must be an array")
                    }
                    // Optional: item type validation could go here
                    if let _ = propSchemaObj["items"] {
                        // Not implemented; accept any items
                        _ = arr
                    }
                case "string", "integer", "number", "boolean":
                    let res = validateScalar(value: value, schemaObject: propSchemaObj, key: key)
                    if !res.isValid { return res }
                default:
                    // Unknown type: ignore
                    break
                }
            }
            // enum constraint
            if let enumVal = propSchemaObj["enum"], case .array(let enumArr) = enumVal {
                let allowed = enumArr.map { $0.foundationValue }
                if !allowed.contains(where: { SchemaValidator.equalJSONValues($0, value) }) {
                    return .fail("Property '\(key)' must be one of: \(allowed)")
                }
            }
        }
        return .ok()
    }

    // MARK: - Scalar validation
    private static func validateScalar(value: Any, schemaObject: [String: JSONValue], key: String? = nil)
        -> ValidationResult
    {
        let label = key.map { " '\($0)'" } ?? ""
        if let typeVal = schemaObject["type"], case .string(let t) = typeVal {
            switch t {
            case "string":
                guard value is String else { return .fail("Property\(label) must be a string") }
            case "integer":
                if let _ = value as? Int {
                    // ok
                } else if let d = value as? Double, d.rounded() == d {
                    // accept integral doubles
                } else {
                    return .fail("Property\(label) must be an integer")
                }
            case "number":
                guard (value is Double) || (value is Int) else {
                    return .fail("Property\(label) must be a number")
                }
            case "boolean":
                guard value is Bool else { return .fail("Property\(label) must be a boolean") }
            case "object":
                guard value is [String: Any] else { return .fail("Property\(label) must be an object") }
            case "array":
                guard value is [Any] else { return .fail("Property\(label) must be an array") }
            default:
                break
            }
        }
        if let enumVal = schemaObject["enum"], case .array(let enumArr) = enumVal {
            let allowed = enumArr.map { $0.foundationValue }
            if !allowed.contains(where: { SchemaValidator.equalJSONValues($0, value) }) {
                return .fail("Property\(label) must be one of: \(allowed)")
            }
        }
        return .ok()
    }

    private static func equalJSONValues(_ a: Any, _ b: Any) -> Bool {
        switch (a, b) {
        case (let x as String, let y as String): return x == y
        case (let x as Bool, let y as Bool): return x == y
        case (let x as Int, let y as Int): return x == y
        case (let x as Double, let y as Double): return x == y
        case (let x as Int, let y as Double): return Double(x) == y
        case (let x as Double, let y as Int): return x == Double(y)
        default: return false
        }
    }
}

private extension JSONValue {
    var foundationValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let arr): return arr.map { $0.foundationValue }
        case .object(let obj): return obj.mapValues { $0.foundationValue }
        }
    }
}
