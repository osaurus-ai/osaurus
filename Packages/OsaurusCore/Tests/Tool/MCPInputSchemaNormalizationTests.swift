//
//  MCPInputSchemaNormalizationTests.swift
//  osaurusTests
//
//  MCP no-arg tools may advertise `{"type":"object"}` without `properties`.
//  OpenAI-style validators reject that, so ingest and wire encoding fill in
//  `properties: {}` while leaving every other schema untouched.
//

import Foundation
import MCP
import Testing

@testable import OsaurusCore

struct MCPInputSchemaNormalizationTests {

    @Test func missingPropertiesIsFilledAtIngest() {
        let schema: MCP.Value = .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
        ])
        let converted = MCPProviderTool.convertInputSchema(schema)
        #expect(
            converted
                == .object([
                    "type": .string("object"),
                    "additionalProperties": .bool(false),
                    "properties": .object([:]),
                ])
        )
    }

    @Test func nilSchemaFallbackIncludesProperties() {
        let converted = MCPProviderTool.convertInputSchema(nil)
        #expect(converted == .object(["type": .string("object"), "properties": .object([:])]))
    }

    @Test func existingPropertiesAreUnchanged() {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object(["q": .object(["type": .string("string")])]),
        ])
        #expect(schema.withEmptyPropertiesIfMissing == schema)
    }

    @Test func nonObjectSchemaIsUnchanged() {
        let schema: JSONValue = .object(["type": .string("string")])
        #expect(schema.withEmptyPropertiesIfMissing == schema)
    }

    @Test func wireEncodingFillsMissingProperties() throws {
        let function = ToolFunction(
            name: "get_accounts",
            description: nil,
            parameters: .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
            ])
        )
        let data = try JSONEncoder().encode(function)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let parameters = try #require(json["parameters"] as? [String: Any])
        #expect((parameters["properties"] as? [String: Any])?.isEmpty == true)
        #expect(parameters["additionalProperties"] as? Bool == false)
    }
    @Test func responsesEncodingNormalizesPreviouslyStoredFunctionSchema() throws {
        let old = Data(
            #"{"type":"function","name":"get_accounts","parameters":{"type":"object","additionalProperties":false},"strict":false}"#
                .utf8
        )
        let tool = try JSONDecoder().decode(OpenResponsesTool.self, from: old)
        let encoded = try JSONEncoder().encode(tool)
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let parameters = try #require(json["parameters"] as? [String: Any])
        #expect((parameters["properties"] as? [String: Any])?.isEmpty == true)
        #expect(parameters["additionalProperties"] as? Bool == false)
        #expect(json["strict"] as? Bool == false)
    }

    @Test func responsesEncodingSuppliesMissingSchema() throws {
        let tool = OpenResponsesTool(name: "no_args", description: nil, parameters: nil)
        let data = try JSONEncoder().encode(tool)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let parameters = try #require(json["parameters"] as? [String: Any])
        #expect(parameters["type"] as? String == "object")
        #expect((parameters["properties"] as? [String: Any])?.isEmpty == true)
    }

    @Test func normalizationPreservesNestedSchemasAndOtherTopLevelShapes() throws {
        // This bridge fills only explicit top-level object schemas. It must not
        // change the meaning of unconstrained schemas, references, or unions.
        for raw in [
            #"{}"#,
            #"{"type":["object","null"]}"#,
            #"{"anyOf":[{"type":"object"},{"type":"null"}]}"#,
            ##"{"$ref":"#/$defs/empty","$defs":{"empty":{"type":"object"}}}"##,
            #"{"type":"object","properties":{"nested":{"type":"object"},"items":{"type":"array","items":{"type":"object"}}},"required":["nested"],"description":"preserve","additionalProperties":false}"#,
        ] {
            let schema = try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
            #expect(schema.withEmptyPropertiesIfMissing == schema)
        }
    }

    @Test func discoveredNoArgToolLoadsAndReachesLocalTemplate() async throws {
        let wrapper = MCPProviderTool(
            mcpTool: MCP.Tool(
                name: "get_accounts",
                description: "No arguments",
                inputSchema: .object(["type": .string("object"), "additionalProperties": .bool(false)])
            ),
            providerId: UUID(),
            providerName: "Schema proof"
        )
        let tool = Tool(
            type: "function",
            function: ToolFunction(
                name: wrapper.name,
                description: wrapper.description,
                parameters: wrapper.parameters
            )
        )
        let buffer = CapabilityLoadBuffer()
        let diagnostic = await buffer.add(tool)
        #expect(diagnostic == nil)
        let loaded = await buffer.drain()
        #expect(loaded.count == 1)
        let spec = try #require(loaded.first).toTokenizerToolSpec()
        let function = try #require(spec["function"] as? [String: any Sendable])
        let parameters = try #require(function["parameters"] as? [String: any Sendable])
        #expect((parameters["properties"] as? [String: any Sendable])?.isEmpty == true)
        #expect(parameters["additionalProperties"] as? Bool == false)
    }

}
