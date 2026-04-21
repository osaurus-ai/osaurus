//
//  SchemaValidator.swift
//  OsaurusCore
//
//  Minimal JSON Schema validator for tool arguments.
//  Supports `type` (object/string/integer/number/boolean/array),
//  `properties`, `required`, `additionalProperties: false`, and `enum`.
//
//  Scalar types (`integer`, `number`, `boolean`) and `array` are
//  intentionally lenient about string-encoded equivalents (`"15"`,
//  `"3.14"`, `"true"`, `"[\"a\",\"b\"]"`) to match the tool-side
//  `ArgumentCoercion` helpers in `OsaurusTool.swift`. Local models
//  often emit slightly off types and the tool body would coerce them
//  anyway; rejecting at the preflight is pure noise.
//

import Foundation

struct SchemaValidator {
    struct ValidationResult {
        let isValid: Bool
        let errorMessage: String?
        /// Offending property name when failure is tied to a specific arg
        /// (wrong type, missing required, unknown key under
        /// `additionalProperties: false`). Nil for structural failures.
        /// Surfaced as `field` in the `ToolEnvelope.failure(...)`.
        let field: String?

        static func ok() -> ValidationResult {
            .init(isValid: true, errorMessage: nil, field: nil)
        }

        static func fail(_ message: String, field: String? = nil) -> ValidationResult {
            .init(isValid: false, errorMessage: message, field: field)
        }
    }

    static func validate(arguments: Any, against schema: JSONValue) -> ValidationResult {
        guard case .object(let schemaObj) = schema else {
            return .fail("Schema must be an object")
        }
        // Non-object top-level schema: validate the raw value directly.
        if case .string(let t)? = schemaObj["type"], t != "object" {
            return validateValue(arguments, schemaObject: schemaObj, key: nil)
        }
        guard let dict = arguments as? [String: Any] else {
            return .fail("Arguments must be an object")
        }
        return validateObject(dict, schemaObject: schemaObj)
    }

    // MARK: - Object validation

    private static func validateObject(
        _ obj: [String: Any],
        schemaObject: [String: JSONValue]
    ) -> ValidationResult {
        for key in requiredKeys(schemaObject) {
            if obj[key] == nil || obj[key] is NSNull {
                return .fail("Missing required property: \(key)", field: key)
            }
        }

        let properties = propertiesMap(schemaObject)

        // `additionalProperties: false` rejects keys not declared in
        // `properties`. JSON Schema's default is to allow extras, and we
        // only honour the strict `bool(false)` form — schema-typed extras
        // are not implemented.
        if case .bool(false) = schemaObject["additionalProperties"] {
            for key in obj.keys where properties[key] == nil {
                let allowed = properties.keys.sorted().joined(separator: ", ")
                return .fail("Unexpected property `\(key)`. Allowed: \(allowed)", field: key)
            }
        }

        for (key, value) in obj {
            guard case .object(let propSchemaObj)? = properties[key] else { continue }
            let res = validateValue(value, schemaObject: propSchemaObj, key: key)
            if !res.isValid { return res }
            // Recurse into nested objects that declare their own properties.
            if case .string("object")? = propSchemaObj["type"],
                case .object? = propSchemaObj["properties"],
                let nested = value as? [String: Any]
            {
                let inner = validateObject(nested, schemaObject: propSchemaObj)
                if !inner.isValid { return inner }
            }
        }
        return .ok()
    }

    // MARK: - Value validation (single value against its schema)

    /// Run the type and `enum` checks for one value against its schema.
    /// Used for object properties (via `validateObject`) and for top-level
    /// non-object schemas. Does NOT recurse into nested objects — that's
    /// `validateObject`'s job.
    private static func validateValue(
        _ value: Any,
        schemaObject: [String: JSONValue],
        key: String?
    ) -> ValidationResult {
        if case .string(let t)? = schemaObject["type"] {
            switch t {
            case "string":
                guard value is String else { return typeMismatch("string", key: key) }
            case "integer":
                guard isIntegerLike(value) else { return typeMismatch("integer", key: key) }
            case "number":
                guard isNumberLike(value) else { return typeMismatch("number", key: key) }
            case "boolean":
                guard isBoolLike(value) else { return typeMismatch("boolean", key: key) }
            case "object":
                guard value is [String: Any] else { return typeMismatch("object", key: key) }
            case "array":
                guard isArrayLike(value) else { return typeMismatch("array", key: key) }
            // Item-level validation is intentionally not implemented.
            default:
                break
            }
        }
        return enumCheck(value: value, schemaObject: schemaObject, key: key)
    }

    // MARK: - Shared helpers

    private static func requiredKeys(_ schemaObject: [String: JSONValue]) -> [String] {
        guard case .array(let arr)? = schemaObject["required"] else { return [] }
        return arr.compactMap {
            if case .string(let s) = $0 { return s }
            return nil
        }
    }

    private static func propertiesMap(_ schemaObject: [String: JSONValue]) -> [String: JSONValue] {
        guard case .object(let props)? = schemaObject["properties"] else { return [:] }
        return props
    }

    private static func enumCheck(
        value: Any,
        schemaObject: [String: JSONValue],
        key: String?
    ) -> ValidationResult {
        guard case .array(let enumArr)? = schemaObject["enum"] else { return .ok() }
        let allowed = enumArr.map { $0.foundationValue }
        if allowed.contains(where: { equalJSONValues($0, value) }) { return .ok() }
        let label = key.map { " '\($0)'" } ?? ""
        return .fail("Property\(label) must be one of: \(allowed)", field: key)
    }

    /// Format a "Property [name] must be a[n] [type]" failure with the
    /// correct article for the given JSON Schema type name.
    private static func typeMismatch(_ expected: String, key: String?) -> ValidationResult {
        let label = key.map { " '\($0)'" } ?? ""
        let article = startsWithVowel(expected) ? "an" : "a"
        return .fail("Property\(label) must be \(article) \(expected)", field: key)
    }

    private static func startsWithVowel(_ s: String) -> Bool {
        guard let c = s.first else { return false }
        return "aeiouAEIOU".contains(c)
    }

    // MARK: - Lenient type checks
    //
    // Mirror the coercion vocabulary used by `ArgumentCoercion` in
    // `OsaurusTool.swift` so the preflight validator and the tool body
    // agree on what counts as an acceptable value.

    /// True when `value` is an integer, an integral floating-point number,
    /// or a string that parses to either. Excludes `Bool` so `true`/
    /// `false` aren't silently accepted as `1`/`0`.
    private static func isIntegerLike(_ value: Any) -> Bool {
        if let n = value as? NSNumber, !isObjCBool(n) {
            let d = n.doubleValue
            return d.rounded() == d
        }
        if let s = value as? String {
            if Int(s) != nil { return true }
            if let d = Double(s), d.rounded() == d { return true }
        }
        return false
    }

    /// True when `value` is any number or a string that parses as `Double`.
    /// Excludes `Bool`.
    private static func isNumberLike(_ value: Any) -> Bool {
        if let n = value as? NSNumber { return !isObjCBool(n) }
        if let s = value as? String { return Double(s) != nil }
        return false
    }

    /// True when `value` is a native `Bool` or a string from the same
    /// vocabulary as `ArgumentCoercion.bool` (`true`/`false`/`1`/`0`/
    /// `yes`/`no`, case-insensitive). Numeric `NSNumber`s (e.g. `2`) are
    /// rejected — only the Objective-C boolean tag counts as native bool.
    private static func isBoolLike(_ value: Any) -> Bool {
        if let n = value as? NSNumber, isObjCBool(n) { return true }
        if let s = value as? String {
            switch s.lowercased() {
            case "true", "false", "1", "0", "yes", "no": return true
            default: return false
            }
        }
        return false
    }

    /// Distinguish a true Objective-C `Bool` (`@YES`/`@NO`) from a numeric
    /// `NSNumber`. `JSONSerialization` decodes `true`/`false` as the former
    /// and integers as the latter; checking the CFTypeID avoids the
    /// `NSNumber` ⇄ `Bool` bridging trap (`NSNumber(1) as? Bool == true`).
    private static func isObjCBool(_ n: NSNumber) -> Bool {
        CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    /// True when `value` is a native array or a string that JSON-decodes
    /// to an array. Mirrors the JSON-decode branch of
    /// `ArgumentCoercion.stringArray` so models that send
    /// `"packages": "[\"a\",\"b\"]"` (a stringified array) get past the
    /// preflight and let the tool body coerce. A bare non-empty string is
    /// not accepted here — the tool can wrap it itself if it wants the
    /// single-element fallback, but the validator surfaces the type
    /// mismatch so the model gets a clear signal.
    private static func isArrayLike(_ value: Any) -> Bool {
        if value is [Any] { return true }
        if let s = value as? String,
            let data = s.data(using: .utf8),
            (try? JSONSerialization.jsonObject(with: data)) is [Any]
        {
            return true
        }
        return false
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
