//
//  SchemaCoercionTests.swift
//  osaurusTests
//
//  Coverage for `SchemaValidator.coerceArguments` — the rescue layer
//  that unwraps stringified arrays / objects / scalars to native types
//  before the validator and tool body see them. Without this rescue,
//  quantized models that emit `"actions": "[{\"action\":\"type\"}]"`
//  (instead of the native array the schema declares) hit a confusing
//  "Required: actions (array)" error from the tool body.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct SchemaCoercionTests {

    // MARK: - browser_do regression

    /// Exact shape the bug report screenshot showed: `actions` is a
    /// JSON-encoded string, the schema declares it as `array`. After
    /// coercion the value must be a real `[Any]` so the tool body's
    /// `requireArray("actions")` succeeds.
    @Test func unwrapsStringifiedArrayToNative() throws {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "actions": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("object")]),
                ])
            ]),
            "required": .array([.string("actions")]),
        ])
        let raw: [String: Any] = [
            "actions":
                #"[{"action": "type", "ref": "E10", "text": "box of tissues"}, {"action": "click", "ref": "E11"}]"#
        ]
        let coerced = SchemaValidator.coerceArguments(raw, against: schema) as? [String: Any]
        let actions = try #require(coerced?["actions"] as? [Any])
        #expect(actions.count == 2)
        let first = try #require(actions[0] as? [String: Any])
        #expect(first["action"] as? String == "type")
        #expect(first["ref"] as? String == "E10")
    }

    @Test func unwrapsStringifiedObjectToNative() throws {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "config": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "depth": .object(["type": .string("integer")])
                    ]),
                ])
            ]),
        ])
        let raw: [String: Any] = ["config": #"{"depth": 3}"#]
        let coerced = SchemaValidator.coerceArguments(raw, against: schema) as? [String: Any]
        let config = try #require(coerced?["config"] as? [String: Any])
        #expect((config["depth"] as? Int) == 3 || (config["depth"] as? NSNumber)?.intValue == 3)
    }

    @Test func unwrapsStringifiedFunctionArgumentsEnvelope() throws {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "dataRef": .object(["type": .string("string")]),
                "chartType": .object(["type": .string("string")]),
                "series": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                ]),
            ]),
        ])
        let raw: [String: Any] = [
            "arguments":
                #"{"chartType":"line","dataRef":"webdata:123","series":["AAPL.Open"]}"#
        ]

        let coerced = try #require(
            SchemaValidator.coerceArguments(raw, against: schema) as? [String: Any]
        )
        #expect(coerced["arguments"] == nil)
        #expect(coerced["chartType"] as? String == "line")
        #expect(coerced["dataRef"] as? String == "webdata:123")
        #expect((coerced["series"] as? [String]) == ["AAPL.Open"])
        #expect(SchemaValidator.validate(arguments: coerced, against: schema).isValid)
    }

    @Test func declaredOrUnrelatedArgumentsEnvelopeIsNotUnwrapped() throws {
        let declaredSchema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "arguments": .object(["type": .string("string")]),
                "dataRef": .object(["type": .string("string")]),
            ]),
        ])
        let declared = try #require(
            SchemaValidator.coerceArguments(
                ["arguments": #"{"dataRef":"webdata:123"}"#],
                against: declaredSchema
            ) as? [String: Any]
        )
        #expect(declared["arguments"] as? String == #"{"dataRef":"webdata:123"}"#)
        #expect(declared["dataRef"] == nil)

        let strictSchema: JSONValue = .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "dataRef": .object(["type": .string("string")])
            ]),
        ])
        let unrelated = try #require(
            SchemaValidator.coerceArguments(
                ["arguments": #"{"unknown":true}"#],
                against: strictSchema
            ) as? [String: Any]
        )
        #expect(unrelated["arguments"] != nil)
        #expect(!SchemaValidator.validate(arguments: unrelated, against: strictSchema).isValid)
    }

    // MARK: - Scalar string coercion (mirrors ArgumentCoercion)

    @Test func unwrapsStringifiedIntegerToNative() throws {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "limit": .object(["type": .string("integer")])
            ]),
        ])
        let coerced =
            SchemaValidator.coerceArguments(["limit": "42"], against: schema)
            as? [String: Any]
        #expect((coerced?["limit"] as? Int) == 42)
    }

    @Test func unwrapsStringifiedBooleanToNative() throws {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "enabled": .object(["type": .string("boolean")])
            ]),
        ])
        let coerced =
            SchemaValidator.coerceArguments(["enabled": "yes"], against: schema)
            as? [String: Any]
        #expect((coerced?["enabled"] as? Bool) == true)
    }

    // MARK: - No-op behaviour

    @Test func nativeArrayIsLeftUnchanged() throws {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "tags": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                ])
            ]),
        ])
        let raw: [String: Any] = ["tags": ["alpha", "beta"]]
        let coerced = SchemaValidator.coerceArguments(raw, against: schema) as? [String: Any]
        let tags = try #require(coerced?["tags"] as? [Any])
        #expect((tags[0] as? String) == "alpha")
    }

    @Test func unrelatedPropertiesArePreserved() throws {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "actions": .object(["type": .string("array")]),
                "note": .object(["type": .string("string")]),
            ]),
        ])
        let raw: [String: Any] = [
            "actions": #"[{"a": 1}]"#,
            "note": "leave me alone",
        ]
        let coerced = SchemaValidator.coerceArguments(raw, against: schema) as? [String: Any]
        #expect((coerced?["note"] as? String) == "leave me alone")
        #expect(coerced?["actions"] is [Any])
    }

    @Test func openSchemaWithoutTypeDoesNothing() throws {
        // No `type` declared — coercion has no rules to apply, so we
        // pass the value through unchanged. (Matches our docs: cases
        // without a type get the lenient validator + raw payload.)
        let schema: JSONValue = .object([:])
        let coerced =
            SchemaValidator.coerceArguments(["x": "42"], against: schema)
            as? [String: Any]
        #expect((coerced?["x"] as? String) == "42")
    }

    // MARK: - Idempotence

    @Test func coercionIsIdempotent() throws {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "actions": .object(["type": .string("array")])
            ]),
        ])
        let raw: [String: Any] = ["actions": #"[1,2,3]"#]
        let once = SchemaValidator.coerceArguments(raw, against: schema)
        let twice = SchemaValidator.coerceArguments(once, against: schema)
        let firstActions = (once as? [String: Any])?["actions"] as? [Any]
        let secondActions = (twice as? [String: Any])?["actions"] as? [Any]
        #expect(firstActions?.count == 3)
        #expect(secondActions?.count == 3)
    }
}
