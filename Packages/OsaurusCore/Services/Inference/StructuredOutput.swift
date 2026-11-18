//
//  StructuredOutput.swift
//  osaurus
//
//  Native structured output for workflow inference nodes. The node's
//  output schema goes to the provider's own schema-constrained mode
//  (OpenAI/Azure/Router `response_format: json_schema`, Responses
//  `text.format`, Anthropic `output_config.format`, Gemini
//  `responseJsonSchema`, Apple Foundation Models `GenerationSchema`, local
//  MLX grammar-constrained decoding via vmlx `GenerateParameters.jsonSchema`).
//  Models without one (a local bundle whose tokenizer the grammar adapter
//  cannot use, Claude Code, remote Osaurus agents) are refused before the
//  call with a typed error — there is no prompt-only JSON fallback.
//
//  Strict provider modes need every object closed and every property
//  required, and most need an object root. `wire(_:)` rewrites the node
//  schema into that form (optional properties become `anyOf [T, null]`,
//  scalar roots are wrapped in `{value: T}`); `decode(_:schema:)` reverses
//  it and then validates against the original schema.
//

import Foundation

public enum StructuredOutputSupport: Equatable, Sendable {
    case supported
    case unsupported(String)
}

public enum StructuredOutputError: Error, LocalizedError, Equatable {
    /// The bound model has no native schema enforcement.
    case unsupportedModel(model: String, reason: String)
    /// The model returned text that is not JSON.
    case notJSON(String)
    /// The model returned JSON that fails the node schema.
    case schemaMismatch([String])

    public var errorDescription: String? {
        switch self {
        case .unsupportedModel(let model, let reason):
            return "\(model) cannot enforce a JSON schema: \(reason)"
        case .notJSON(let text):
            return "The model output is not JSON: \(text.prefix(200))"
        case .schemaMismatch(let issues):
            return "The model output does not match the schema: " + issues.joined(separator: "; ")
        }
    }
}

public enum StructuredOutputSchema {
    static let defaultName = "node_output"
    static let wrappedKey = "value"

    /// Whether `wire(_:)` wraps this schema's root in `{value: …}`.
    static func wrapsRoot(_ schema: JSONValue) -> Bool {
        guard case .object(let obj) = schema else { return true }
        if case .string("object")? = obj["type"] { return false }
        if obj["type"] == nil, obj["properties"] != nil { return false }
        return true
    }

    /// The provider-facing schema: object root, closed objects, all
    /// properties required with optional ones nullable. Idempotent: the
    /// wire form of a wire form is itself, so a schema that already went
    /// through here is not wrapped or rewritten again.
    static func strictWire(_ schema: JSONValue) -> JSONValue {
        strictify(objectRoot(schema))
    }

    /// The schema with a scalar or array root wrapped in `{value: T}`;
    /// object roots are returned as they are. `CoreModelService` applies
    /// this once before dispatch so every backend — including Apple
    /// Foundation Models, which takes the schema without `strictWire` —
    /// produces the shape `decode(_:schema:)` unwraps. Idempotent.
    static func objectRoot(_ schema: JSONValue) -> JSONValue {
        guard wrapsRoot(schema) else { return schema }
        return .object([
            "type": .string("object"),
            "properties": .object([wrappedKey: schema]),
            "required": .array([.string(wrappedKey)]),
        ])
    }

    /// Whether the schema has an object anywhere that is a map (no fixed
    /// `properties`, any or schema-typed `additionalProperties`). Strict
    /// provider modes cannot express one; `StructuredOutputCapability`
    /// refuses such a pairing up front instead of the provider rejecting
    /// the request or the map silently closing to `{}`.
    static func hasOpenMap(_ schema: JSONValue) -> Bool {
        guard case .object(let obj) = schema else { return false }
        if isOpenMap(obj) { return true }
        for key in ["properties", "$defs", "definitions"] {
            if let members = obj[key]?.objectValue, members.values.contains(where: hasOpenMap) { return true }
        }
        for key in ["anyOf", "oneOf", "allOf"] {
            if case .array(let options)? = obj[key], options.contains(where: hasOpenMap) { return true }
        }
        if let items = obj["items"], hasOpenMap(items) { return true }
        if case .object? = obj["additionalProperties"], hasOpenMap(obj["additionalProperties"]!) { return true }
        return false
    }

    /// An object schema with no `properties` whose `additionalProperties`
    /// is absent, `true`, or a schema: the author means "any keys".
    private static func isOpenMap(_ obj: [String: JSONValue]) -> Bool {
        guard obj["properties"] == nil else { return false }
        let isObject: Bool
        switch obj["type"] {
        case .string("object")?: isObject = true
        case .array(let types)?: isObject = types.contains(.string("object"))
        default: isObject = false
        }
        guard isObject else { return false }
        switch obj["additionalProperties"] {
        case .bool(false)?: return false
        default: return true
        }
    }

    /// The strict wire form as the JSON text the local MLX runtime takes
    /// (`GenerateParameters.jsonSchema`). Keys are sorted so the same node
    /// schema always compiles the same grammar.
    static func localWire(_ schema: JSONValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(strictWire(schema)), as: UTF8.self)
    }

    private static func strictify(_ schema: JSONValue) -> JSONValue {
        guard case .object(var obj) = schema else { return schema }
        if let props = obj["properties"]?.objectValue {
            // Grammar compilers need the object type spelled out next to
            // `properties`; providers accept it either way.
            if obj["type"] == nil { obj["type"] = .string("object") }
            let required = Set(obj["required"]?.arrayStrings ?? [])
            var rewritten: [String: JSONValue] = [:]
            for (key, value) in props {
                let inner = strictify(value)
                rewritten[key] =
                    required.contains(key) || isNullable(inner)
                    ? inner : .object(["anyOf": .array([inner, .object(["type": .string("null")])])])
            }
            obj["properties"] = .object(rewritten)
            obj["required"] = .array(props.keys.sorted().map(JSONValue.string))
            obj["additionalProperties"] = .bool(false)
        } else if isOpenMap(obj) {
            // A map keeps its keys open; only the value schema is made
            // strict. `true`/absent stays open for backends that take it.
            if case .object? = obj["additionalProperties"] {
                obj["additionalProperties"] = strictify(obj["additionalProperties"]!)
            } else {
                obj["additionalProperties"] = .bool(true)
            }
        } else if case .string("object")? = obj["type"] {
            obj["properties"] = .object([:])
            obj["required"] = .array([])
            obj["additionalProperties"] = .bool(false)
        }
        if let items = obj["items"] { obj["items"] = strictify(items) }
        for key in ["anyOf", "oneOf", "allOf"] {
            if case .array(let options)? = obj[key] { obj[key] = .array(options.map(strictify)) }
        }
        for key in ["$defs", "definitions"] {
            if let defs = obj[key]?.objectValue { obj[key] = .object(defs.mapValues(strictify)) }
        }
        return .object(obj)
    }

    /// Whether a (strict) property schema already admits `null`, so a
    /// second pass must not wrap it in another `anyOf [T, null]`.
    private static func isNullable(_ schema: JSONValue) -> Bool {
        guard case .object(let s) = schema else { return false }
        switch s["type"] {
        case .string("null")?: return true
        case .array(let types)?: return types.contains(.string("null"))
        default: break
        }
        if case .array(let options)? = s["anyOf"] {
            return options.contains { $0 == .object(["type": .string("null")]) }
        }
        return false
    }

    /// Parse provider text, undo `wire(_:)`, and validate strictly against
    /// the original schema.
    static func decode(_ text: String, schema: JSONValue) throws -> JSONValue {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = JSONValue.parse(trimmed) else { throw StructuredOutputError.notJSON(trimmed) }
        var value = parsed
        if wrapsRoot(schema) {
            guard let inner = parsed.objectValue?[wrappedKey] else {
                throw StructuredOutputError.schemaMismatch(["missing wrapped `value`"])
            }
            value = inner
        }
        value = dropNullOptionals(value, schema: schema)
        let issues = JSONSchemaValidator.validate(value, against: schema)
        if !issues.isEmpty {
            throw StructuredOutputError.schemaMismatch(issues.map { "\($0.path): \($0.message)" })
        }
        return value
    }

    /// The key of a schema that is one required, unconstrained string
    /// property. Such an output needs no JSON: the model writes the text
    /// itself and `decodeText` makes it `{key: text}`. Any constraint on
    /// the string (`enum`, `const`, `format`, `pattern`, length) or on the
    /// object keeps the schema-enforced path.
    static func singleTextField(_ schema: JSONValue) -> String? {
        let rootKeys: Set<String> = [
            "type", "properties", "required", "additionalProperties", "title", "description", "$comment", "x-order",
        ]
        let fieldKeys: Set<String> = ["type", "title", "description", "$comment", "examples", "default"]
        guard case .object(let root) = schema, !wrapsRoot(schema), Set(root.keys).isSubset(of: rootKeys),
            let props = root["properties"]?.objectValue, props.count == 1, let (key, field) = props.first,
            root["required"]?.arrayStrings?.contains(key) == true,
            case .object(let spec) = field, spec["type"] == .string("string"), Set(spec.keys).isSubset(of: fieldKeys)
        else { return nil }
        return key
    }

    /// A single-text-field reply as the node output: the trimmed text under
    /// `field`, validated against the schema. Empty text is a mismatch, so
    /// the node's retry policy can ask again.
    static func decodeText(_ text: String, field: String, schema: JSONValue) throws -> JSONValue {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw StructuredOutputError.schemaMismatch(["\(field): the model returned no text"])
        }
        let value = JSONValue.object([field: .string(trimmed)])
        let issues = JSONSchemaValidator.validate(value, against: schema)
        if !issues.isEmpty {
            throw StructuredOutputError.schemaMismatch(issues.map { "\($0.path): \($0.message)" })
        }
        return value
    }

    /// Remove `null` values the strict wire form put in for optional keys.
    static func dropNullOptionals(_ value: JSONValue, schema: JSONValue) -> JSONValue {
        guard case .object(let s) = schema else { return value }
        // A union: continue into the first branch shaped like the value.
        if s["properties"] == nil, s["items"] == nil {
            for key in ["anyOf", "oneOf"] {
                guard case .array(let options)? = s[key] else { continue }
                guard let branch = options.first(where: { matchesType(value, schema: $0) }) else { return value }
                return dropNullOptionals(value, schema: branch)
            }
        }
        if case .array(let parts)? = s["allOf"] {
            return parts.reduce(value) { dropNullOptionals($0, schema: $1) }
        }
        switch value {
        case .object(var obj):
            let props = s["properties"]?.objectValue ?? [:]
            let required = Set(s["required"]?.arrayStrings ?? [])
            for (key, propSchema) in props {
                guard let v = obj[key] else { continue }
                if v == .null, !required.contains(key), !allowsNull(propSchema) {
                    obj.removeValue(forKey: key)
                } else {
                    obj[key] = dropNullOptionals(v, schema: propSchema)
                }
            }
            if case .object? = s["additionalProperties"], let valueSchema = s["additionalProperties"] {
                for (key, v) in obj where props[key] == nil {
                    obj[key] = dropNullOptionals(v, schema: valueSchema)
                }
            }
            return .object(obj)
        case .array(let items):
            guard let itemSchema = s["items"] else { return value }
            return .array(items.map { dropNullOptionals($0, schema: itemSchema) })
        default:
            return value
        }
    }

    /// Whether `value` has the JSON type `schema` declares. Untyped and
    /// nested-union schemas match anything and let recursion decide.
    private static func matchesType(_ value: JSONValue, schema: JSONValue) -> Bool {
        guard case .object(let s) = schema else { return false }
        if s["anyOf"] != nil || s["oneOf"] != nil { return true }
        let types: Set<String>
        switch s["type"] {
        case .string(let t)?: types = [t]
        case .array(let list)?: types = Set(list.compactMap(\.stringValue))
        case nil:
            if s["properties"] != nil || s["additionalProperties"] != nil { types = ["object"] }
            else if s["items"] != nil { types = ["array"] }
            else { return true }
        default: return false
        }
        switch value {
        case .object: return types.contains("object")
        case .array: return types.contains("array")
        case .string: return types.contains("string")
        case .number(let d): return types.contains("number") || (types.contains("integer") && d == d.rounded())
        case .bool: return types.contains("boolean")
        case .null: return types.contains("null")
        }
    }

    private static func allowsNull(_ schema: JSONValue) -> Bool {
        guard case .object(let s) = schema else { return true }
        switch s["type"] {
        case .string("null")?: return true
        case .array(let types)?: return types.contains(.string("null"))
        case nil: return s["anyOf"] == nil && s["oneOf"] == nil && s["enum"] == nil && s["const"] == nil
        default: return false
        }
    }
}

/// Which models can enforce a schema natively.
public enum StructuredOutputCapability {
    /// A local MLX model whose tokenizer the engine's grammar adapter does
    /// not accept (see `LocalGrammarTokenizerProbe`).
    static let localMLXReason = LocalGrammarTokenizerProbe.unsupportedReason

    /// Pure classification. `isLocalMLX`, `localTokenizerSupported`, and
    /// `foundationAvailable` are injected so tests need no live services.
    /// A local MLX model is supported when vmlx can compile a grammar over
    /// its tokenizer; the engine masks logits against the node schema.
    static func support(
        for model: String,
        providerType: RemoteProviderType?,
        isLocalMLX: Bool,
        localTokenizerSupported: Bool = false,
        foundationAvailable: Bool,
        schemas: [JSONValue] = []
    ) -> StructuredOutputSupport {
        let lowered = model.lowercased()
        let needsOpenMap = schemas.contains(where: StructuredOutputSchema.hasOpenMap)
        if lowered == "foundation" || lowered.hasSuffix("/foundation") {
            guard foundationAvailable else {
                return .unsupported("Apple Foundation Models is not available on this Mac.")
            }
            return needsOpenMap ? .unsupported(openMapReason("Apple Foundation Models")) : .supported
        }
        if let providerType {
            switch providerType {
            case .openaiLegacy, .azureOpenAI, .anthropic, .openResponses, .openAICodex, .osaurusRouter:
                return needsOpenMap ? .unsupported(openMapReason("its strict JSON schema mode")) : .supported
            case .gemini:
                return .supported
            case .osaurus:
                return .unsupported("a remote Osaurus agent runs its own loop and does not accept a response schema.")
            }
        }
        if lowered.hasPrefix("claude-code/") || lowered == "claude-code" {
            return .unsupported("the Claude Code backend runs a CLI session and does not accept a response schema.")
        }
        if isLocalMLX { return localTokenizerSupported ? .supported : .unsupported(localMLXReason) }
        return .unsupported("no installed model or connected provider serves this id.")
    }

    /// Strict schema modes (OpenAI-style `strict: true`, Anthropic's
    /// `output_config`, Foundation Models' `GenerationSchema`) require every
    /// object to list its properties; a map with open keys has no form there.
    static func openMapReason(_ backend: String) -> String {
        "a node output schema has an object with open keys (no `properties`), which \(backend) cannot express. Name the properties, or bind a model with grammar-constrained decoding."
    }

    @MainActor
    public static func support(for model: String, schemas: [JSONValue] = []) -> StructuredOutputSupport {
        let manager = RemoteProviderManager.shared
        let providerType = manager.configuration.providers.first { provider in
            model.lowercased().hasPrefix(RemoteProviderManager.pickerPrefix(for: provider.name) + "/")
        }?.providerType
        let local = ModelManager.shared.availableModels.first {
            $0.isDownloaded && $0.id.caseInsensitiveCompare(model) == .orderedSame
        }
        return support(
            for: model,
            providerType: providerType,
            isLocalMLX: local != nil,
            localTokenizerSupported: local.map { LocalGrammarTokenizerProbe.supports(bundle: $0.localDirectory) }
                ?? false,
            foundationAvailable: FoundationModelService.defaultModelAvailability().unavailableReason == nil,
            schemas: schemas)
    }
}

extension JSONValue {
    var arrayStrings: [String]? {
        guard case .array(let items) = self else { return nil }
        return items.compactMap(\.stringValue)
    }
}
