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

public struct SchemaValidator {
    public struct ValidationResult {
        public let isValid: Bool
        public let errorMessage: String?
        /// Offending property name when failure is tied to a specific arg
        /// (wrong type, missing required, unknown key under
        /// `additionalProperties: false`). Nil for structural failures.
        /// Surfaced as `field` in the `ToolEnvelope.failure(...)`.
        public let field: String?

        static func ok() -> ValidationResult {
            .init(isValid: true, errorMessage: nil, field: nil)
        }

        static func fail(_ message: String, field: String? = nil) -> ValidationResult {
            .init(isValid: false, errorMessage: message, field: field)
        }
    }

    public static func validate(arguments: Any, against schema: JSONValue) -> ValidationResult {
        guard case .object(let schemaObj) = schema else {
            return .fail("Schema must be an object")
        }
        // Non-object top-level schema (or untyped combinator-only schema):
        // validate the raw value directly. Combinator-only schemas
        // (`{oneOf: [...]}` with no `type`) are common when a parameter
        // accepts e.g. either a string or an integer — we must NOT
        // require the input to be a JSON object in that case.
        let topType: String?
        if case .string(let t)? = schemaObj["type"] {
            topType = t
        } else {
            topType = nil
        }
        let hasCombinator =
            schemaObj["oneOf"] != nil || schemaObj["anyOf"] != nil
        if let t = topType, t != "object" {
            return validateValue(arguments, schemaObject: schemaObj, key: nil)
        }
        if topType == nil && hasCombinator {
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
        let properties = propertiesMap(schemaObject)
        for key in requiredKeys(schemaObject) {
            let propertySchema: [String: JSONValue]? = {
                if case .object(let prop)? = properties[key] { return prop }
                return nil
            }()
            if obj[key] == nil || (obj[key] is NSNull && propertySchema.map(permitsNull) != true) {
                // Near-miss diagnosis: quantized local models routinely emit
                // the right key in the wrong spelling (`Pattern`, `chart_type`).
                // `coerceArguments` rescues the unambiguous cases before
                // validation; when a mismatch still reaches here (coercion
                // bypassed, or the fold was ambiguous), name the offending key
                // so the model can fix its next call instead of re-sending the
                // same arguments against a "Missing required property" it
                // believes it satisfied (observed live: an 18-call retry
                // spiral on `file_search {"Pattern": …}`).
                if let nearMiss = obj.keys.first(where: {
                    properties[$0] == nil && foldKey($0) == foldKey(key)
                }) {
                    return .fail(
                        "Missing required property: \(key) (you sent `\(nearMiss)` — "
                            + "JSON keys are exact; use `\(key)`)",
                        field: key
                    )
                }
                return .fail("Missing required property: \(key)", field: key)
            }
        }

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

        // Object-level `anyOf` / `oneOf` of `required` branches: the
        // standard way to express "at least one of these key groups must
        // be present" (e.g. share_artifact's path-XOR-content). Only
        // presence is checked here — branches carrying their own
        // `properties` constraints are out of scope (per-property
        // validation below covers the declared property schemas).
        if case .array(let branches)? = schemaObject["anyOf"] ?? schemaObject["oneOf"] {
            let requiredGroups: [[String]] = branches.compactMap { branch in
                guard case .object(let branchObj) = branch else { return nil }
                let keys = requiredKeys(branchObj)
                return keys.isEmpty ? nil : keys
            }
            if !requiredGroups.isEmpty {
                let satisfied = requiredGroups.contains { group in
                    group.allSatisfy { obj[$0] != nil && !(obj[$0] is NSNull) }
                }
                if !satisfied {
                    let alternatives =
                        requiredGroups
                        .map { "`" + $0.joined(separator: "` + `") + "`" }
                        .joined(separator: " OR ")
                    return .fail(
                        "Arguments must include \(alternatives).",
                        field: requiredGroups.first?.first
                    )
                }
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

    /// Run the type, range, format, and `enum` checks for one value
    /// against its schema. Used for object properties (via
    /// `validateObject`) and for top-level non-object schemas. Does NOT
    /// recurse into nested objects — that's `validateObject`'s job.
    private static func validateValue(
        _ value: Any,
        schemaObject: [String: JSONValue],
        key: String?
    ) -> ValidationResult {
        if value is NSNull {
            guard permitsNull(schemaObject) else { return typeMismatch("non-null", key: key) }
            return enumCheck(value: value, schemaObject: schemaObject, key: key)
        }

        // First-match dispatch on combinators. We match OpenAI's
        // observed JSON-Schema usage: `oneOf` and `anyOf` are common
        // tool-arg patterns; `allOf` is rare. We treat `oneOf` and
        // `anyOf` interchangeably (first matching branch wins) — this
        // is permissive but matches what GPT-4 emits in practice.
        if case .array(let branches)? = schemaObject["oneOf"] ?? schemaObject["anyOf"] {
            for branch in branches {
                guard case .object(let branchObj) = branch else { continue }
                let res = validateValue(value, schemaObject: branchObj, key: key)
                if res.isValid { return res }
            }
            let label = key.map { " '\($0)'" } ?? ""
            return .fail(
                "Property\(label) did not match any of the allowed schema branches.",
                field: key
            )
        }

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
            default:
                break
            }
        }

        // String-specific constraints: `pattern` (regex) + `minLength` /
        // `maxLength`. Pattern compilation failures are tolerated — a
        // bad regex in the schema shouldn't break the tool call.
        if let s = value as? String {
            if case .string(let pat)? = schemaObject["pattern"] {
                if let regex = try? NSRegularExpression(pattern: pat),
                    regex.firstMatch(
                        in: s,
                        range: NSRange(s.startIndex..., in: s)
                    ) == nil
                {
                    let label = key.map { " '\($0)'" } ?? ""
                    return .fail(
                        "Property\(label) does not match required pattern `\(pat)`.",
                        field: key
                    )
                }
            }
        }

        // Numeric range constraints: `minimum` and `maximum`. Inclusive
        // bounds (the JSON Schema default). `exclusiveMinimum` /
        // `exclusiveMaximum` are not implemented yet — flag them
        // silently rather than miscompare.
        if let bound = numericValue(value) {
            if case .number(let min)? = schemaObject["minimum"], bound < min {
                let label = key.map { " '\($0)'" } ?? ""
                return .fail(
                    "Property\(label) must be >= \(min) (got \(bound)).",
                    field: key
                )
            }
            if case .number(let max)? = schemaObject["maximum"], bound > max {
                let label = key.map { " '\($0)'" } ?? ""
                return .fail(
                    "Property\(label) must be <= \(max) (got \(bound)).",
                    field: key
                )
            }
        }

        // Array element validation: `items` (single schema applied to
        // every element). Tuple-form `items: [schema, schema, ...]` is
        // not implemented — defer to the caller for that rarer shape.
        if case .object(let itemsSchema)? = schemaObject["items"],
            let arr = value as? [Any]
        {
            for (idx, element) in arr.enumerated() {
                let elementKey = key.map { "\($0)[\(idx)]" } ?? "[\(idx)]"
                let res = validateValue(element, schemaObject: itemsSchema, key: elementKey)
                if !res.isValid { return res }
                if case .string("object")? = itemsSchema["type"],
                    case .object? = itemsSchema["properties"],
                    let nested = element as? [String: Any]
                {
                    let inner = validateObject(nested, schemaObject: itemsSchema)
                    if !inner.isValid { return inner }
                }
            }
        }

        return enumCheck(value: value, schemaObject: schemaObject, key: key)
    }

    /// Coerce the value to a `Double` for numeric range checks. Mirrors
    /// `isNumberLike` but returns the parsed value so we can compare.
    /// Excludes booleans (NSNumber tag).
    private static func numericValue(_ value: Any) -> Double? {
        if let n = value as? NSNumber, !isObjCBool(n) { return n.doubleValue }
        if let s = value as? String, let d = Double(s) { return d }
        return nil
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
        // Case-insensitive fallback for string enums. `coerceValue` already
        // normalises matching strings to their canonical case before the
        // validator runs, but callers that bypass coercion (tests, ad-hoc
        // validation) still benefit from this lenient comparison.
        if let s = value as? String,
            allowed.contains(where: { ($0 as? String)?.lowercased() == s.lowercased() })
        {
            return .ok()
        }
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
        case (_ as NSNull, _ as NSNull): return true
        case (let x as String, let y as String): return x == y
        case (let x as Bool, let y as Bool): return x == y
        case (let x as Int, let y as Int): return x == y
        case (let x as Double, let y as Double): return x == y
        case (let x as Int, let y as Double): return Double(x) == y
        case (let x as Double, let y as Int): return x == Double(y)
        default: return false
        }
    }

    // MARK: - Schema-aware coercion
    //
    // Quantized local models routinely emit nested arrays and objects as
    // JSON-encoded strings instead of native types — e.g. they send
    //
    //   {"actions": "[{\"action\": \"type\", \"ref\": \"E10\"}]"}
    //
    // when the schema declares `actions: array`. The validator's lenient
    // `isArrayLike` check would let that through, but the tool body
    // ultimately reads `args["actions"]` as a `String` and rejects with
    // "Required: actions (array)" — confusing for a model that thinks it
    // sent the right shape.
    //
    // `coerceArguments` walks the schema and, for each declared property,
    // attempts the obvious unwrap (string → array via JSON parse, string
    // → object via JSON parse, string → number via Double parse, etc.).
    // It always returns a value, falling through unchanged when no
    // coercion rule applies, so callers can run it unconditionally
    // before validation + dispatch. Together with `validate`, this gives
    // the tool body native types whenever the model gets close enough.

    /// Coerce `arguments` toward the types declared in `schema`.
    /// Recursive — descends into object properties and array items —
    /// and idempotent: passing already-coerced arguments is a no-op.
    /// Schemas without enough type information (no `type`, untyped
    /// `oneOf` / `anyOf`) fall through unchanged.
    public static func coerceArguments(_ arguments: Any, against schema: JSONValue) -> Any {
        guard case .object(let schemaObj) = schema else { return arguments }
        return coerceValue(arguments, schemaObject: schemaObj)
    }

    /// Recursive worker. `schemaObject` is the unwrapped schema dict
    /// for the current value. We dispatch on the declared `type`:
    ///   - `object` → recurse into each declared property
    ///   - `array`  → recurse into items
    ///   - `integer` / `number` / `boolean` → unwrap a string scalar
    ///   - everything else → return the value unchanged
    /// String inputs that look like JSON (`"[…]"` / `"{…}"`) are
    /// upgraded to native arrays / objects when the schema asks for
    /// the matching collection type.
    private static func coerceValue(
        _ value: Any,
        schemaObject: [String: JSONValue]
    ) -> Any {
        if let s = value as? String,
            s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "null",
            permitsNull(schemaObject)
        {
            return NSNull()
        }

        let typeName: String? = {
            if case .string(let t)? = schemaObject["type"] { return t }
            return nil
        }()

        switch typeName {
        case "object":
            // Unwrap stringified object first.
            let target = unwrapJSONString(value, expecting: .object) ?? value
            guard let dict = target as? [String: Any] else { return target }
            return coerceObject(dict, schemaObject: schemaObject)
        case "array":
            let target = unwrapJSONString(value, expecting: .array) ?? value
            guard let arr = target as? [Any] else { return target }
            return coerceArray(arr, schemaObject: schemaObject)
        case "integer":
            return coerceScalarString(value) { ArgumentCoercion.int($0) as Any? } ?? value
        case "number":
            if let s = value as? String, let d = Double(s) { return d }
            return value
        case "boolean":
            return coerceScalarString(value) { ArgumentCoercion.bool($0) as Any? } ?? value
        case "string":
            // Normalise case-insensitive enum hits to their canonical
            // declared form. Quantized models routinely emit `"Pinned"`
            // when the schema declares `"pinned"` — handing the canonical
            // value to the tool body lets it keep its strict equality
            // check (and skip a private case-folding helper per tool).
            return normalizeStringEnumCase(value, schemaObject: schemaObject)
        default:
            return value
        }
    }

    /// When `schemaObject` declares a string `enum`, replace `value` with
    /// the canonical-case entry it matches case-insensitively. Pure pass-
    /// through when there's no enum, the value isn't a string, or the
    /// value already matches an enum entry verbatim.
    private static func normalizeStringEnumCase(
        _ value: Any,
        schemaObject: [String: JSONValue]
    ) -> Any {
        guard let s = value as? String,
            case .array(let enumArr)? = schemaObject["enum"]
        else { return value }
        let canonical: [String] = enumArr.compactMap {
            if case .string(let str) = $0 { return str }
            return nil
        }
        if canonical.contains(s) { return value }
        let lower = s.lowercased()
        return canonical.first(where: { $0.lowercased() == lower }) ?? value
    }

    private static func coerceObject(
        _ obj: [String: Any],
        schemaObject: [String: JSONValue]
    ) -> [String: Any] {
        guard case .object(let propsDict)? = schemaObject["properties"] else { return obj }
        var out = unwrapPropertiesWrapper(in: obj, propsDict: propsDict)
        out = normalizeKeySpelling(in: out, propsDict: propsDict)
        out = dropEmptyOptionalStrings(in: out, propsDict: propsDict, required: requiredKeys(schemaObject))
        for (key, value) in out {
            guard case .object(let propSchema)? = propsDict[key] else { continue }
            out[key] = coerceValue(value, schemaObject: propSchema)
        }
        return out
    }

    /// Rename argument keys to their declared schema spelling when the
    /// match is unambiguous. Quantized local models routinely emit
    /// `{"Pattern": …}` for a schema declaring `pattern`, or
    /// `{"chart_type": …}` for `chartType` — the value is right, only the
    /// key spelling drifted, and the strict validator then reports
    /// "Missing required property" for a key the model believes it sent
    /// (observed live: an 18-call identical-retry spiral on `file_search`).
    /// Same rescue class as `normalizeStringEnumCase` (enum VALUE case) and
    /// `unwrapPropertiesWrapper` (schema-body confusion), extended to keys.
    ///
    /// A key is renamed only when ALL of:
    ///   1. it is not itself a declared property (verbatim keys always win),
    ///   2. exactly one declared property has the same alphanumeric fold
    ///      (lowercased, `_`/`-` stripped — covers case drift AND
    ///      snake/camel drift in one rule; declared keys whose folds
    ///      collide with each other are excluded as ambiguous),
    ///   3. the declared spelling is not already present in the arguments
    ///      (a double-emit keeps the verbatim key; the stray one falls
    ///      through to the validator's unknown-key / near-miss report).
    static func normalizeKeySpelling(
        in obj: [String: Any],
        propsDict: [String: JSONValue]
    ) -> [String: Any] {
        var declaredByFold: [String: String?] = [:]  // fold → key (nil = ambiguous)
        for declared in propsDict.keys {
            let fold = foldKey(declared)
            declaredByFold[fold] = declaredByFold[fold] == nil ? declared : .some(nil)
        }
        var out = obj
        for key in obj.keys {
            guard propsDict[key] == nil,
                let foldEntry = declaredByFold[foldKey(key)],
                let declared = foldEntry,
                declared != key,
                out[declared] == nil
            else { continue }
            out[declared] = out.removeValue(forKey: key)
        }
        return out
    }

    /// Alphanumeric fold used for key-spelling rescue: lowercase, keep
    /// only letters and digits (drops `_`, `-`, and other separators).
    static func foldKey(_ key: String) -> String {
        String(key.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// Quantized models occasionally emit `{"properties": {chartType:
    /// "bar", …}}` when they confuse the schema body with the schema
    /// itself. Merge the inner object up so the validator and tool body
    /// see the unwrapped shape. Only when (a) `properties` is not itself
    /// a declared property of this schema and (b) the inner object
    /// contains at least one declared key. Outer keys win on collision
    /// so a partial double-emit doesn't get clobbered.
    private static func unwrapPropertiesWrapper(
        in obj: [String: Any],
        propsDict: [String: JSONValue]
    ) -> [String: Any] {
        guard propsDict["properties"] == nil,
            let nested = obj["properties"] as? [String: Any]
        else { return obj }
        let declared = Set(propsDict.keys)
        guard !declared.intersection(Set(nested.keys)).isEmpty else { return obj }
        var out = obj
        out.removeValue(forKey: "properties")
        for (key, value) in nested where out[key] == nil {
            out[key] = value
        }
        return out
    }

    /// Drop optional string properties whose value is empty or
    /// whitespace-only. Many models pass empty placeholders for
    /// fields they don't intend to use (`description: ""`,
    /// `filename: ""`); treating them as absent stops downstream
    /// non-empty checks from rejecting a legitimate call. Required
    /// fields keep their empty value so the validator's
    /// `Missing required` / tool's `must not be empty` envelope still
    /// surfaces — `requireString` (default `allowEmpty: false`) will
    /// then point at the offending field.
    private static func dropEmptyOptionalStrings(
        in obj: [String: Any],
        propsDict: [String: JSONValue],
        required: [String]
    ) -> [String: Any] {
        let requiredSet = Set(required)
        var out = obj
        for (key, value) in obj {
            guard !requiredSet.contains(key),
                case .object(let propSchema)? = propsDict[key],
                case .string("string")? = propSchema["type"],
                let s = value as? String,
                s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            out.removeValue(forKey: key)
        }
        return out
    }

    private static func coerceArray(
        _ arr: [Any],
        schemaObject: [String: JSONValue]
    ) -> [Any] {
        guard case .object(let itemsSchema)? = schemaObject["items"] else { return arr }
        return arr.map { coerceValue($0, schemaObject: itemsSchema) }
    }

    /// What we expect to find when JSON-parsing a string scalar that
    /// the schema typed as a collection. The two cases the validator
    /// rescues today are array-encoded-as-string and
    /// object-encoded-as-string; everything else is intentionally left
    /// to the unwrapped scalar coercion path.
    private enum ExpectedJSONShape { case array, object }

    /// If `value` is a `String` that JSON-decodes to the requested
    /// shape, return the decoded native object. Otherwise nil so the
    /// caller can fall back to whatever the input was.
    private static func unwrapJSONString(
        _ value: Any,
        expecting shape: ExpectedJSONShape
    ) -> Any? {
        guard let s = value as? String,
            let data = s.data(using: .utf8),
            let parsed = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        switch shape {
        case .array where parsed is [Any]: return parsed
        case .object where parsed is [String: Any]: return parsed
        default: return nil
        }
    }

    /// Apply `coercer` only when `value` is a `String` AND the result
    /// is non-nil. Otherwise return nil so the caller knows nothing
    /// changed and can keep the original value.
    private static func coerceScalarString(
        _ value: Any,
        _ coercer: (String) -> Any?
    ) -> Any? {
        guard let s = value as? String, let coerced = coercer(s) else { return nil }
        return coerced
    }

    private static func permitsNull(_ schemaObject: [String: JSONValue]) -> Bool {
        if case .bool(true)? = schemaObject["nullable"] {
            return true
        }
        if case .array(let entries)? = schemaObject["type"],
            entries.contains(.string("null"))
        {
            return true
        }
        if case .array(let entries)? = schemaObject["enum"],
            entries.contains(.null)
        {
            return true
        }
        return false
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
