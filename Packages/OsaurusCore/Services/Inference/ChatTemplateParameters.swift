import Foundation

/// The request owns conversation structure; model-specific variables remain JSON.
enum ChatTemplateParameters {
    /// Internal app-to-tokenizer signal, removed before rendering.
    static let explicitContextKey = "_osaurus_explicit_template_parameters"
    struct InvalidParameter: Error, LocalizedError {
        let key: String
        var errorDescription: String? {
            "chat_template_kwargs.\(key) cannot replace the request's conversation, tools or generation-prompt flag."
        }
    }

    static func validate(_ values: [String: JSONValue]?) throws {
        for key in ["messages", "tools", "add_generation_prompt", explicitContextKey] where values?[key] != nil {
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
        case .number(let value): return value
        case .string(let value): return value
        case .array(let values): return values.map(\.templateContextValue)
        case .object(let values): return values.mapValues(\.templateContextValue)
        }
    }
}
