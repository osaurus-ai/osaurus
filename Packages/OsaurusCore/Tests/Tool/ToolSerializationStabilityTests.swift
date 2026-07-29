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
                    "z_last": .object(["type": .string("string")]),
                    "a_first": .object(["type": .string("string")]),
                    "m_middle": .object(["type": .string("string")]),
                ])
            )
        )

        let a = tool.toTokenizerToolSpec()
        let b = tool.toTokenizerToolSpec()

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

        #expect(parameters["additionalProperties"] == nil)
        #expect(set["additionalProperties"] == nil)
        #expect(whereClause["additionalProperties"] == nil)
        let shapedAdditional = try #require(shaped["additionalProperties"] as? [String: any Sendable])
        #expect(shapedAdditional["type"] as? String == "string")
        #expect(set["type"] as? String == "object")
        #expect(whereClause["type"] as? String == "object")
        try Self.assertNoBooleanAdditionalProperties(parameters)
    }

    @Test
    func toTokenizerToolSpec_collapsesMultiTypeSchemasForGemmaTemplates() throws {
        let tool = Tool(
            type: "function",
            function: ToolFunction(
                name: "create_table",
                description: "Creates a table.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "columns": .object([
                            "type": .string("array"),
                            "items": .object([
                                "type": .string("object"),
                                "properties": .object([
                                    "properties": .object([
                                        "type": .array([.string("description"), .string("type")]),
                                        "description": .string("Column metadata."),
                                    ])
                                ]),
                            ]),
                        ])
                    ]),
                ])
            )
        )

        let spec = tool.toTokenizerToolSpec()
        let fn = try #require(spec["function"] as? [String: any Sendable])
        let parameters = try #require(fn["parameters"] as? [String: any Sendable])
        let rootProperties = try #require(parameters["properties"] as? [String: any Sendable])
        let columns = try #require(rootProperties["columns"] as? [String: any Sendable])
        let items = try #require(columns["items"] as? [String: any Sendable])
        let itemProperties = try #require(items["properties"] as? [String: any Sendable])
        let nestedProperties = try #require(itemProperties["properties"] as? [String: any Sendable])

        #expect(nestedProperties["type"] as? String == "description")
        #expect((nestedProperties["x-osaurus-original-type"] as? [String]) == ["description", "type"])
    }

    /// The complete ordered baseline payload — every always-loaded tool's
    /// canonical tokenizer spec, in registry order — must be byte-identical
    /// across invocations. This is the actual unit the chat template renders
    /// into the static `<tools>` prefix: a single tool whose schema reads
    /// mutable state (the old provider-derived `web_search` category enum),
    /// or a nondeterministic ordering, silently invalidates KV-cache reuse
    /// for every conversation.
    @Test
    @MainActor
    func alwaysLoadedTokenizerToolPayload_isByteStableAcrossInvocations() throws {
        func orderedPayload() throws -> (names: [String], bytes: Data) {
            let specs = ToolRegistry.shared.alwaysLoadedSpecs(mode: .none)
            var joined = Data()
            for tool in specs {
                joined.append(
                    try JSONSerialization.data(
                        withJSONObject: tool.toTokenizerToolSpec(),
                        options: [.sortedKeys]
                    )
                )
                // Separator so ("ab","c") never collides with ("a","bc").
                joined.append(0x1F)
            }
            return (specs.map(\.function.name), joined)
        }

        let first = try orderedPayload()
        let second = try orderedPayload()
        #expect(first.names == second.names)
        #expect(first.bytes == second.bytes)
    }

    @Test
    @MainActor
    func alwaysLoadedTokenizerToolSpecsExposeOnlyStringTypeFields() throws {
        let specs = ToolRegistry.shared.alwaysLoadedSpecs(mode: .none)
            .map { $0.toTokenizerToolSpec() }
        var failures: [String] = []

        func walk(_ value: Any, path: String) {
            if let dict = value as? [String: Any] {
                if !path.hasSuffix(".properties"), let type = dict["type"], !(type is String) {
                    failures.append("\(path).type=\(type)")
                }
                for (key, child) in dict {
                    walk(child, path: path + "." + key)
                }
            } else if let array = value as? [Any] {
                for (index, child) in array.enumerated() {
                    walk(child, path: "\(path)[\(index)]")
                }
            }
        }

        for spec in specs {
            let name =
                ((spec["function"] as? [String: Any])?["name"] as? String)
                ?? "<unknown>"
            walk(spec, path: name)
        }

        #expect(failures.isEmpty, Comment(rawValue: failures.joined(separator: "\n")))
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
