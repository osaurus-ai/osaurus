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
    func toTokenizerToolSpec_preservesNullableTypeUnionsForChatTemplates() throws {
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

        #expect(label["type"] as? [String] == ["string", "null"])
        #expect(label["nullable"] == nil)
        #expect(mode["type"] as? String == "string")
        #expect((mode["enum"] as? [String]) == ["fast", "full"])
    }

    @Test
    func toTokenizerToolSpec_preservesSchemaTypesAndPropertyNames() throws {
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

        #expect(parameters["type"] as? [String] == ["object", "null"])
        #expect(parameters["nullable"] == nil)
        #expect(query["type"] is NSNull)
        #expect(value["type"] as? [String] == ["string", "integer"])
        #expect(payload["type"] == nil)
        #expect(propertyNamedType["type"] as? String == "string")
    }

    @Test
    func toTokenizerToolSpec_preservesBooleanAdditionalPropertiesForChatTemplates() throws {
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

        #expect(parameters["additionalProperties"] as? Bool == false)
        #expect(set["additionalProperties"] as? Bool == true)
        #expect(whereClause["additionalProperties"] as? Bool == true)
        let shapedAdditional = try #require(shaped["additionalProperties"] as? [String: any Sendable])
        #expect(shapedAdditional["type"] as? String == "string")
        #expect(set["type"] as? String == "object")
        #expect(whereClause["type"] as? String == "object")
    }

    @Test
    func toTokenizerToolSpec_preservesMultiTypeSchemasForAllTemplates() throws {
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

        #expect(nestedProperties["type"] as? [String] == ["description", "type"])
        #expect(nestedProperties["x-osaurus-original-type"] == nil)
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
    func alwaysLoadedTokenizerToolsPreserveTheirOriginalSchemas() throws {
        for tool in ToolRegistry.shared.alwaysLoadedSpecs(mode: .none) {
            let spec = tool.toTokenizerToolSpec()
            let function = try #require(spec["function"] as? [String: any Sendable])
            if let original = tool.function.parameters {
                let parameters = try #require(function["parameters"])
                let expected = try JSONSerialization.data(withJSONObject: original.anyValue, options: [.fragmentsAllowed, .sortedKeys])
                let actual = try JSONSerialization.data(withJSONObject: parameters, options: [.fragmentsAllowed, .sortedKeys])
                #expect(actual == expected, "Schema changed for \(tool.function.name)")
            }
        }
    }

    @Test
    func decodedToolRetainsNestedNullsAndBooleanSchemas() throws {
        let source = #"{"type":"function","function":{"name":"read_record","parameters":{"type":"object","additionalProperties":false,"properties":{"query":{"type":["string","null"],"default":null,"enum":["a",null]},"free":true,"closed":false}}}}"#
        let tool = try JSONDecoder().decode(Tool.self, from: Data(source.utf8))
        let expected = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: Data(source.utf8)), options: [.sortedKeys])
        let actual = try JSONSerialization.data(withJSONObject: tool.toTokenizerToolSpec(), options: [.sortedKeys])
        #expect(actual == expected)
        let bridged = try #require(SwiftTransformersTokenizerLoader.normalizedToolsForChatTemplate([tool.toTokenizerToolSpec()])?.first)
        let bridgedData = try JSONSerialization.data(withJSONObject: bridged, options: [.sortedKeys])
        #expect(bridgedData == expected)
    }
}
