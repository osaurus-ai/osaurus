//
//  SchemaValidatorAdditionalPropertiesTests.swift
//  osaurusTests
//
//  Coverage for the `additionalProperties: false` extension added to
//  `SchemaValidator`. Tools that opt in (via their schema) must reject
//  unexpected keys with a structured error whose `field` points at the
//  offending key.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct SchemaValidatorAdditionalPropertiesTests {

    private let schemaStrict: JSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "name": .object(["type": .string("string")])
        ]),
        "required": .array([.string("name")]),
    ])

    private let schemaLenient: JSONValue = .object([
        "type": .string("object"),
        // No additionalProperties declared — JSON Schema default allows extras.
        "properties": .object([
            "name": .object(["type": .string("string")])
        ]),
    ])

    @Test func rejectsUnexpectedPropertyWhenStrict() {
        let result = SchemaValidator.validate(
            arguments: ["name": "alice", "rogue": "extra"],
            against: schemaStrict
        )
        #expect(!result.isValid)
        #expect(result.field == "rogue")
        #expect((result.errorMessage ?? "").contains("rogue"))
    }

    @Test func acceptsExactDeclaredPropertiesWhenStrict() {
        let result = SchemaValidator.validate(
            arguments: ["name": "alice"],
            against: schemaStrict
        )
        #expect(result.isValid)
    }

    @Test func lenientSchemaIgnoresUnknownKeys() {
        let result = SchemaValidator.validate(
            arguments: ["name": "alice", "rogue": "extra"],
            against: schemaLenient
        )
        #expect(result.isValid)
    }

    @Test func stillReportsRequiredBeforeAdditional() {
        // Missing-required should trip first — we want the model to fix
        // the missing arg before getting yelled at about a stray extra.
        let result = SchemaValidator.validate(
            arguments: ["rogue": "extra"],
            against: schemaStrict
        )
        #expect(!result.isValid)
        #expect(result.field == "name")
    }
}
