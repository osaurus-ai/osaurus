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
}
