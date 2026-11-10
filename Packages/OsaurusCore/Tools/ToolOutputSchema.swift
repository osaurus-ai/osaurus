//
//  ToolOutputSchema.swift
//  osaurus
//
//  Builders for the `outputSchema` a built-in tool publishes: the shape of
//  its success envelope's `result`, which is what a workflow tool step
//  outputs. The Architect reads it to bind the real fields, and a tool
//  step whose own `output_schema` is `{}` is checked against it strictly.
//  So these schemas never forbid extra fields, `require` only what every
//  success carries, and leave a field untyped when its type varies.
//

import Foundation

enum ToolOutputSchema {

    static func object(
        _ properties: [String: JSONValue], required: [String] = [], _ description: String? = nil
    ) -> JSONValue {
        var o: [String: JSONValue] = ["type": .string("object"), "properties": .object(properties)]
        if !required.isEmpty { o["required"] = .array(required.map { .string($0) }) }
        if let description { o["description"] = .string(description) }
        return .object(o)
    }

    static func string(_ description: String) -> JSONValue { typed("string", description) }
    static func integer(_ description: String) -> JSONValue { typed("integer", description) }
    static func number(_ description: String) -> JSONValue { typed("number", description) }
    static func boolean(_ description: String) -> JSONValue { typed("boolean", description) }

    /// An object whose fields are not listed (a passthrough record).
    static func anyObject(_ description: String) -> JSONValue { typed("object", description) }

    static func array(_ items: JSONValue? = nil, _ description: String) -> JSONValue {
        var o: [String: JSONValue] = ["type": .string("array"), "description": .string(description)]
        if let items { o["items"] = items }
        return .object(o)
    }

    /// `schema` that may also be `null` (a lookup that found nothing).
    static func nullable(_ schema: JSONValue) -> JSONValue {
        guard case .object(var o) = schema, let type = o["type"]?.stringValue else { return schema }
        o["type"] = .array([.string(type), .string("null")])
        return .object(o)
    }

    /// A field whose type varies between results.
    static func value(_ description: String) -> JSONValue {
        .object(["description": .string(description)])
    }

    /// The result of a tool that answers in prose: `{text}`.
    static func text(_ description: String) -> JSONValue {
        object(["text": string(description)], required: ["text"])
    }

    /// `{text}` plus the optional fields a tool adds beside it.
    static func text(_ description: String, plus extra: [String: JSONValue]) -> JSONValue {
        object(extra.merging(["text": string(description)]) { _, new in new }, required: ["text"])
    }

    private static func typed(_ type: String, _ description: String) -> JSONValue {
        .object(["type": .string(type), "description": .string(description)])
    }
}
