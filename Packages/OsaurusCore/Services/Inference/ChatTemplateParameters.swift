import Foundation

/// The request owns conversation structure; model-specific variables remain JSON.
enum ChatTemplateParameters {
    /// Internal app-to-tokenizer signal, removed before rendering.
    static let explicitContextKey = "_osaurus_explicit_template_parameters"
    /// These are the exact specialTokenAttributes populated by the vendored
    /// tokenizer after additionalContext. Configured values would silently
    /// replace a caller's values; missing/null config would let the caller
    /// invent token delimiters. Both cases belong to the tokenizer contract.
    private static let tokenizerOwnedKeys: Set<String> = [
        "bos_token", "eos_token", "unk_token", "sep_token", "pad_token",
        "cls_token", "mask_token", "additional_special_tokens",
    ]

    struct InvalidParameter: Error, LocalizedError {
        let key: String
        var errorDescription: String? {
            "chat_template_kwargs.\(key) is managed by the request or tokenizer and cannot be overridden."
        }
    }

    static func validate(_ values: [String: JSONValue]?) throws {
        let reserved = tokenizerOwnedKeys.union(["messages", "tools", "add_generation_prompt", explicitContextKey])
        for key in reserved.sorted() where values?[key] != nil {
            throw InvalidParameter(key: key)
        }
    }
}

extension JSONValue {
    /// Jinja supports NSNull. Unlike tool-schema conversion, template variables
    /// must preserve null object members and array elements exactly.
    var templateContextValue: any Sendable {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value):
            // JSON integers must remain integers for Jinja range/index helpers.
            // Conversion is exact and bounds-checked; fractional values stay Double.
            if let integer = Int(exactly: value) { return integer }
            return value
        case .string(let value): return value
        case .array(let values): return values.map(\.templateContextValue)
        case .object(let values): return values.mapValues(\.templateContextValue)
        }
    }
}
