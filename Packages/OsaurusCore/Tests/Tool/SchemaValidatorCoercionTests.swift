//
//  SchemaValidatorCoercionTests.swift
//  osaurusTests
//
//  Coverage for the lenient scalar coercion in `SchemaValidator`. Local
//  models routinely emit `"15"` where the schema declares `integer` (or
//  `"true"` where it declares `boolean`); the tool body would coerce
//  these via `ArgumentCoercion`, so the preflight validator does too.
//
//  These tests pin down the accepted vocabulary and guard against the
//  obvious over-relaxations (don't accept arbitrary strings as `string`,
//  don't accept `2` as a `boolean`, don't quietly accept floats as
//  integers).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct SchemaValidatorCoercionTests {

    // MARK: - Schemas

    private let intSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "n": .object(["type": .string("integer")])
        ]),
    ])

    private let numberSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "n": .object(["type": .string("number")])
        ]),
    ])

    private let boolSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "b": .object(["type": .string("boolean")])
        ]),
    ])

    private let stringSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "s": .object(["type": .string("string")])
        ]),
    ])

    private let arraySchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "xs": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
            ])
        ]),
    ])

    // MARK: - Integer

    @Test func integerAcceptsNativeInt() {
        let r = SchemaValidator.validate(arguments: ["n": 15], against: intSchema)
        #expect(r.isValid, "native Int should validate; got: \(r.errorMessage ?? "?")")
    }

    @Test func integerAcceptsStringEncoded() {
        // The screenshot bug: `sandbox_exec` got `"timeout": "15"`.
        let r = SchemaValidator.validate(arguments: ["n": "15"], against: intSchema)
        #expect(r.isValid, "string-encoded integer should validate; got: \(r.errorMessage ?? "?")")
    }

    @Test func integerAcceptsIntegralDouble() {
        let r = SchemaValidator.validate(arguments: ["n": 30.0], against: intSchema)
        #expect(r.isValid)
    }

    @Test func integerAcceptsIntegralStringDouble() {
        let r = SchemaValidator.validate(arguments: ["n": "30.0"], against: intSchema)
        #expect(r.isValid)
    }

    @Test func integerRejectsFractionalDouble() {
        let r = SchemaValidator.validate(arguments: ["n": 1.5], against: intSchema)
        #expect(!r.isValid)
        #expect(r.field == "n")
    }

    @Test func integerRejectsFractionalString() {
        let r = SchemaValidator.validate(arguments: ["n": "1.5"], against: intSchema)
        #expect(!r.isValid)
        #expect(r.field == "n")
    }

    @Test func integerRejectsNonNumericString() {
        let r = SchemaValidator.validate(arguments: ["n": "abc"], against: intSchema)
        #expect(!r.isValid)
        #expect(r.field == "n")
    }

    @Test func integerRejectsBoolean() {
        // `true` must NOT silently coerce to 1.
        let r = SchemaValidator.validate(arguments: ["n": true], against: intSchema)
        #expect(!r.isValid)
        #expect(r.field == "n")
    }

    // MARK: - Number

    @Test func numberAcceptsInt() {
        let r = SchemaValidator.validate(arguments: ["n": 42], against: numberSchema)
        #expect(r.isValid)
    }

    @Test func numberAcceptsDouble() {
        let r = SchemaValidator.validate(arguments: ["n": 3.14], against: numberSchema)
        #expect(r.isValid)
    }

    @Test func numberAcceptsStringEncodedDouble() {
        let r = SchemaValidator.validate(arguments: ["n": "3.14"], against: numberSchema)
        #expect(r.isValid)
    }

    @Test func numberAcceptsStringEncodedInt() {
        let r = SchemaValidator.validate(arguments: ["n": "42"], against: numberSchema)
        #expect(r.isValid)
    }

    @Test func numberRejectsNonNumericString() {
        let r = SchemaValidator.validate(arguments: ["n": "foo"], against: numberSchema)
        #expect(!r.isValid)
        #expect(r.field == "n")
    }

    @Test func numberRejectsBoolean() {
        let r = SchemaValidator.validate(arguments: ["n": false], against: numberSchema)
        #expect(!r.isValid)
        #expect(r.field == "n")
    }

    // MARK: - Boolean

    @Test func booleanAcceptsNative() {
        #expect(
            SchemaValidator.validate(arguments: ["b": true], against: boolSchema).isValid
        )
        #expect(
            SchemaValidator.validate(arguments: ["b": false], against: boolSchema).isValid
        )
    }

    @Test func booleanAcceptsStringVocabulary() {
        for s in ["true", "false", "TRUE", "False", "1", "0", "yes", "no", "YES"] {
            let r = SchemaValidator.validate(arguments: ["b": s], against: boolSchema)
            #expect(r.isValid, "expected `\(s)` to coerce to bool; got: \(r.errorMessage ?? "?")")
        }
    }

    @Test func booleanRejectsArbitraryString() {
        let r = SchemaValidator.validate(arguments: ["b": "maybe"], against: boolSchema)
        #expect(!r.isValid)
        #expect(r.field == "b")
    }

    @Test func booleanRejectsNumberOutsideZeroOne() {
        // We intentionally do NOT accept `2` as a boolean — that's a real
        // arg bug worth surfacing.
        let r = SchemaValidator.validate(arguments: ["b": 2], against: boolSchema)
        #expect(!r.isValid)
        #expect(r.field == "b")
    }

    // MARK: - Array

    @Test func arrayAcceptsNative() {
        let r = SchemaValidator.validate(
            arguments: ["xs": ["matplotlib", "numpy"]],
            against: arraySchema
        )
        #expect(r.isValid, "got: \(r.errorMessage ?? "?")")
    }

    @Test func arrayAcceptsJSONEncodedString() {
        // The screenshot bug: `sandbox_pip_install` got
        // `"packages": "[\"matplotlib\", \"numpy\"]"`.
        let r = SchemaValidator.validate(
            arguments: ["xs": "[\"matplotlib\", \"numpy\"]"],
            against: arraySchema
        )
        #expect(r.isValid, "got: \(r.errorMessage ?? "?")")
    }

    @Test func arrayAcceptsJSONEncodedEmptyArrayString() {
        let r = SchemaValidator.validate(
            arguments: ["xs": "[]"],
            against: arraySchema
        )
        #expect(r.isValid)
    }

    @Test func arrayRejectsBareString() {
        // `"numpy"` (single string) is a real arg bug worth surfacing —
        // the tool's `requireStringArray` has its own wrap fallback but
        // the validator stays strict so the model gets a clear signal.
        let r = SchemaValidator.validate(
            arguments: ["xs": "numpy"],
            against: arraySchema
        )
        #expect(!r.isValid)
        #expect(r.field == "xs")
    }

    @Test func arrayRejectsObjectEncodedString() {
        let r = SchemaValidator.validate(
            arguments: ["xs": "{\"a\": 1}"],
            against: arraySchema
        )
        #expect(!r.isValid)
        #expect(r.field == "xs")
    }

    // MARK: - String (regression guard — must stay strict)

    @Test func stringStillRejectsInteger() {
        let r = SchemaValidator.validate(arguments: ["s": 42], against: stringSchema)
        #expect(!r.isValid)
        #expect(r.field == "s")
    }

    @Test func stringStillRejectsBoolean() {
        let r = SchemaValidator.validate(arguments: ["s": true], against: stringSchema)
        #expect(!r.isValid)
        #expect(r.field == "s")
    }

    // MARK: - Top-level scalar schema (early-return path)

    @Test func topLevelIntegerCoercesString() {
        let schema: JSONValue = .object(["type": .string("integer")])
        let r = SchemaValidator.validate(arguments: "15", against: schema)
        #expect(r.isValid)
    }

    @Test func topLevelBooleanCoercesString() {
        let schema: JSONValue = .object(["type": .string("boolean")])
        let r = SchemaValidator.validate(arguments: "yes", against: schema)
        #expect(r.isValid)
    }

    // MARK: - Realistic sandbox_exec shape

    @Test func sandboxPipInstallLikeSchemaAcceptsStringEncodedPackages() {
        // Mirrors `SandboxPipInstallTool.parameters` — second user-reported
        // screenshot. Model emitted the array as a JSON-encoded string.
        let schema: JSONValue = .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "packages": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                ])
            ]),
            "required": .array([.string("packages")]),
        ])
        let r = SchemaValidator.validate(
            arguments: ["packages": "[\"matplotlib\", \"numpy\"]"],
            against: schema
        )
        #expect(r.isValid, "got: \(r.errorMessage ?? "?")")
    }

    @Test func sandboxExecLikeSchemaAcceptsStringTimeout() {
        // Mirrors `SandboxExecTool.parameters` shape — the case in the
        // user-reported screenshot.
        let schema: JSONValue = .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "command": .object(["type": .string("string")]),
                "timeout": .object(["type": .string("integer")]),
            ]),
            "required": .array([.string("command")]),
        ])
        let r = SchemaValidator.validate(
            arguments: ["command": "echo hi", "timeout": "15"],
            against: schema
        )
        #expect(r.isValid, "got: \(r.errorMessage ?? "?")")
    }
}
