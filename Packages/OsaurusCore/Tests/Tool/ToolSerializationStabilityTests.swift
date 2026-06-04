//
//  ToolSerializationStabilityTests.swift
//  osaurusTests
//
//  Pins down the byte-stability of `Tool.toTokenizerToolSpec` so the
//  rendered `<tools>` block in the system prompt doesn't shuffle between
//  invocations and silently invalidate the MLX paged KV cache.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct ToolSerializationStabilityTests {

    @Test
    func toTokenizerToolSpec_isByteStableAcrossInvocations() throws {
        let tool = Tool(
            type: "function",
            function: ToolFunction(
                name: "echo",
                description: "Echoes its input back.",
                parameters: .object([
                    "type": .string("object"),
                    // Insertion order chosen so a non-canonical encoder would
                    // surface key reordering between runs.
                    "z_last": .object(["type": .string("string")]),
                    "a_first": .object(["type": .string("string")]),
                    "m_middle": .object(["type": .string("string")]),
                ])
            )
        )

        let a = tool.toTokenizerToolSpec()
        let b = tool.toTokenizerToolSpec()

        // Re-serialize both with sortedKeys so we get a deterministic byte
        // representation we can compare. (`isValidJSONObject` + serialize is
        // intentionally identical to the path the canonical helper uses.)
        let aData = try JSONSerialization.data(withJSONObject: a, options: [.sortedKeys])
        let bData = try JSONSerialization.data(withJSONObject: b, options: [.sortedKeys])
        #expect(aData == bData)
    }

    @Test
    func toTokenizerToolSpec_normalizesNullableTypeUnionsForChatTemplates() throws {
        let tool = Tool(
            type: "function",
            function: ToolFunction(
                name: "lookup",
                description: "Looks up an optional label.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "label": .object([
                            "type": .array([.string("string"), .string("null")]),
                            "description": .string("Optional label."),
                        ]),
                        "mode": .object([
                            "type": .string("string"),
                            "enum": .array([.string("fast"), .string("full")]),
                        ]),
                    ]),
                    "required": .array([.string("label")]),
                ])
            )
        )

        let spec = tool.toTokenizerToolSpec()
        let fn = try #require(spec["function"] as? [String: any Sendable])
        let parameters = try #require(fn["parameters"] as? [String: any Sendable])
        let properties = try #require(parameters["properties"] as? [String: any Sendable])
        let label = try #require(properties["label"] as? [String: any Sendable])
        let mode = try #require(properties["mode"] as? [String: any Sendable])

        #expect(label["type"] as? String == "string")
        #expect(label["nullable"] as? Bool == true)
        #expect(mode["type"] as? String == "string")
        #expect((mode["enum"] as? [String]) == ["fast", "full"])
    }

    @Test
    func toTokenizerToolSpec_normalizesGemmaSensitiveTypeFieldsOnlyInSchemaPositions() throws {
        let tool = Tool(
            type: "function",
            function: ToolFunction(
                name: "schema_probe",
                description: "Exercises Gemma4 template-sensitive schema shapes.",
                parameters: .object([
                    "type": .array([.string("object"), .string("null")]),
                    "properties": .object([
                        "query": .object([
                            "type": .null,
                            "description": .string("Malformed external schema still renders."),
                        ]),
                        "value": .object([
                            "type": .array([.string("string"), .string("integer")])
                        ]),
                        "payload": .object([
                            "properties": .object([
                                "type": .object(["type": .string("string")])
                            ])
                        ]),
                    ]),
                ])
            )
        )

        let spec = tool.toTokenizerToolSpec()
        let fn = try #require(spec["function"] as? [String: any Sendable])
        let parameters = try #require(fn["parameters"] as? [String: any Sendable])
        let properties = try #require(parameters["properties"] as? [String: any Sendable])
        let query = try #require(properties["query"] as? [String: any Sendable])
        let value = try #require(properties["value"] as? [String: any Sendable])
        let payload = try #require(properties["payload"] as? [String: any Sendable])
        let payloadProperties = try #require(payload["properties"] as? [String: any Sendable])
        let propertyNamedType = try #require(payloadProperties["type"] as? [String: any Sendable])

        #expect(parameters["type"] as? String == "object")
        #expect(parameters["nullable"] as? Bool == true)
        #expect(query["type"] as? String == "string")
        #expect(value["type"] as? String == "string")
        #expect(payload["type"] as? String == "object")
        #expect(propertyNamedType["type"] as? String == "string")
        try Self.assertSchemaTypesAreTemplateRenderable(parameters)
    }

    @Test
    func toTokenizerToolSpec_dropsBooleanAdditionalPropertiesForChatTemplates() throws {
        // Mirrors the Osaurus default `db_*` tools (db_insert/db_update/db_upsert/
        // db_delete/db_restore), whose free-form object args are spelled
        // `{"type": "object", "additionalProperties": true}`. Gemma4's template
        // pipes a property's `additionalProperties` through `| upper`, which
        // throws "upper filter requires string" on the boolean form. The schema
        // object form must still survive so nested constraints keep rendering.
        let tool = Tool(
            type: "function",
            function: ToolFunction(
                name: "db_update",
                description: "Update rows matched by `where`.",
                parameters: .object([
                    "type": .string("object"),
                    "additionalProperties": .bool(false),
                    "properties": .object([
                        "set": .object([
                            "type": .string("object"),
                            "additionalProperties": .bool(true),
                        ]),
                        "where": .object([
                            "type": .string("object"),
                            "additionalProperties": .bool(true),
                        ]),
                        "shaped": .object([
                            "type": .string("object"),
                            "additionalProperties": .object(["type": .string("string")]),
                        ]),
                    ]),
                    "required": .array([.string("set"), .string("where")]),
                ])
            )
        )

        let spec = tool.toTokenizerToolSpec()
        let fn = try #require(spec["function"] as? [String: any Sendable])
        let parameters = try #require(fn["parameters"] as? [String: any Sendable])
        let properties = try #require(parameters["properties"] as? [String: any Sendable])
        let set = try #require(properties["set"] as? [String: any Sendable])
        let whereClause = try #require(properties["where"] as? [String: any Sendable])
        let shaped = try #require(properties["shaped"] as? [String: any Sendable])

        // Boolean additionalProperties (both at the root and nested) is dropped.
        #expect(parameters["additionalProperties"] == nil)
        #expect(set["additionalProperties"] == nil)
        #expect(whereClause["additionalProperties"] == nil)
        // Object-form additionalProperties is preserved and still renderable.
        let shapedAdditional = try #require(shaped["additionalProperties"] as? [String: any Sendable])
        #expect(shapedAdditional["type"] as? String == "string")
        // Surrounding shape is untouched.
        #expect(set["type"] as? String == "object")
        #expect(whereClause["type"] as? String == "object")
        try Self.assertNoBooleanAdditionalProperties(parameters)
    }

    private static func assertNoBooleanAdditionalProperties(
        _ value: any Sendable
    ) throws {
        if let dict = value as? [String: any Sendable] {
            #expect(
                !(dict["additionalProperties"] is Bool),
                "boolean additionalProperties must be dropped from the template-facing schema"
            )
            for child in dict.values {
                try assertNoBooleanAdditionalProperties(child)
            }
        } else if let array = value as? [any Sendable] {
            for child in array {
                try assertNoBooleanAdditionalProperties(child)
            }
        }
    }

    private static func assertSchemaTypesAreTemplateRenderable(
        _ schema: [String: any Sendable]
    ) throws {
        if let typeValue = schema["type"] {
            #expect(typeValue is String, "schema type must be String, got \(type(of: typeValue))")
        }

        if let properties = schema["properties"] as? [String: any Sendable] {
            for value in properties.values {
                let child = try #require(value as? [String: any Sendable])
                try assertSchemaTypesAreTemplateRenderable(child)
            }
        }

        if let items = schema["items"] as? [String: any Sendable] {
            try assertSchemaTypesAreTemplateRenderable(items)
        }

        for key in ["oneOf", "anyOf", "allOf"] {
            guard let branches = schema[key] as? [Any] else { continue }
            for branch in branches {
                guard let child = branch as? [String: any Sendable] else { continue }
                try assertSchemaTypesAreTemplateRenderable(child)
            }
        }
    }
}
