//
//  SchemaValidatorAdvancedTests.swift
//  osaurusTests
//
//  Coverage for the rules added in §2.3 of the inference-and-tool-calling
//  gap audit: `oneOf` / `anyOf` (first-match), `items` element validation,
//  `pattern` regex, and numeric `minimum` / `maximum` ranges. Without
//  these tests a schema regression would silently re-accept the previously
//  permissive shape.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct SchemaValidatorAdvancedTests {

    // MARK: - oneOf / anyOf

    private let oneOfSchema: JSONValue = .object([
        "oneOf": .array([
            .object(["type": .string("string")]),
            .object(["type": .string("integer"), "minimum": .number(0)]),
        ])
    ])

    @Test func oneOfMatchesStringBranch() {
        let result = SchemaValidator.validate(arguments: "hello", against: oneOfSchema)
        #expect(result.isValid)
    }

    @Test func oneOfMatchesIntegerBranchHonoringMinimum() {
        let result = SchemaValidator.validate(arguments: 5, against: oneOfSchema)
        #expect(result.isValid)
    }

    @Test func oneOfRejectsWhenNoBranchMatches() {
        // Negative integer fails the `minimum: 0` branch, and a number
        // is not a string, so neither branch accepts it.
        let result = SchemaValidator.validate(arguments: -1, against: oneOfSchema)
        #expect(!result.isValid)
        #expect((result.errorMessage ?? "").contains("did not match"))
    }

    // MARK: - nested paths in item/object failures

    /// A failure inside an array item must name the item — a bare
    /// `Property 'kind' must be one of …` is unactionable against an
    /// 11-intent batch (observed live with a large action-multiplexed tool).
    @Test func arrayItemObjectFailureCarriesTheItemIndex() {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "intents": .object([
                    "type": .string("array"),
                    "items": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "kind": .object([
                                "type": .string("string"),
                                "enum": .array([.string("say"), .string("idle")]),
                            ])
                        ]),
                        "required": .array([.string("kind")]),
                    ]),
                ])
            ]),
        ])
        let arguments: [String: Any] = [
            "intents": [["kind": "say"], ["kind": "celebrate"]]
        ]

        let result = SchemaValidator.validate(arguments: arguments, against: schema)
        #expect(!result.isValid)
        #expect(result.field == "intents[1].kind")
        #expect((result.errorMessage ?? "").hasPrefix("intents[1]: "))
    }

    /// Same for a nested object property: the parent key prefixes the path.
    @Test func nestedObjectFailureCarriesTheParentKey() {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "intent": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "kind": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("kind")]),
                ])
            ]),
        ])
        let arguments: [String: Any] = ["intent": [String: Any]()]

        let result = SchemaValidator.validate(arguments: arguments, against: schema)
        #expect(!result.isValid)
        #expect(result.field == "intent.kind")
    }

    // MARK: - object-level anyOf of required groups (path-XOR-content)

    /// Mirrors `share_artifact`'s schema: `{}` must fail preflight with a
    /// clear `field`, while either required group satisfies the call.
    private let xorSchema: JSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "path": .object(["type": .string("string")]),
            "content": .object(["type": .string("string")]),
            "filename": .object(["type": .string("string")]),
        ]),
        "required": .array([]),
        "anyOf": .array([
            .object(["required": .array([.string("path")])]),
            .object(["required": .array([.string("content"), .string("filename")])]),
        ]),
    ])

    @Test func objectAnyOfAcceptsEitherRequiredGroup() {
        #expect(SchemaValidator.validate(arguments: ["path": "a.txt"], against: xorSchema).isValid)
        #expect(
            SchemaValidator.validate(
                arguments: ["content": "hi", "filename": "a.md"],
                against: xorSchema
            ).isValid
        )
    }

    @Test func objectAnyOfRejectsEmptyArgumentsWithField() {
        let result = SchemaValidator.validate(arguments: [String: Any](), against: xorSchema)
        #expect(!result.isValid)
        #expect(result.field == "path")
        #expect((result.errorMessage ?? "").contains("`path` OR `content` + `filename`"))
    }

    @Test func objectAnyOfRejectsPartialGroup() {
        // `content` without `filename` satisfies neither branch.
        let result = SchemaValidator.validate(arguments: ["content": "hi"], against: xorSchema)
        #expect(!result.isValid)
    }

    // MARK: - items (array element validation)

    private let arrayOfStringsSchema: JSONValue = .object([
        "type": .string("array"),
        "items": .object(["type": .string("string")]),
    ])

    @Test func arrayItemsAcceptedWhenAllMatch() {
        let result = SchemaValidator.validate(
            arguments: ["a", "b", "c"],
            against: arrayOfStringsSchema
        )
        #expect(result.isValid)
    }

    @Test func arrayItemsRejectedOnTypeMismatch() {
        let result = SchemaValidator.validate(
            arguments: ["a", 42, "c"],
            against: arrayOfStringsSchema
        )
        #expect(!result.isValid)
        // The validator emits a synthetic indexed key like `[1]` for
        // top-level array element failures.
        #expect((result.field ?? "").contains("[1]"))
    }

    // MARK: - pattern (string regex)

    private let semverSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "version": .object([
                "type": .string("string"),
                "pattern": .string(#"^\d+\.\d+\.\d+$"#),
            ])
        ]),
        "required": .array([.string("version")]),
    ])

    @Test func patternAcceptsMatchingString() {
        let result = SchemaValidator.validate(
            arguments: ["version": "1.2.3"],
            against: semverSchema
        )
        #expect(result.isValid)
    }

    @Test func patternRejectsNonMatchingString() {
        let result = SchemaValidator.validate(
            arguments: ["version": "v1"],
            against: semverSchema
        )
        #expect(!result.isValid)
        #expect(result.field == "version")
        #expect((result.errorMessage ?? "").contains("pattern"))
    }

    @Test func stringLengthBoundsAreEnforced() {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "value": .object([
                    "type": .string("string"),
                    "minLength": .number(2),
                    "maxLength": .number(4),
                ])
            ]),
        ])

        #expect(
            !SchemaValidator.validate(arguments: ["value": "x"], against: schema).isValid
        )
        #expect(
            SchemaValidator.validate(arguments: ["value": "four"], against: schema).isValid
        )
        let tooLong = SchemaValidator.validate(arguments: ["value": "12345"], against: schema)
        #expect(!tooLong.isValid)
        #expect(tooLong.field == "value")
    }

    // MARK: - minimum / maximum

    private let rangeSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "score": .object([
                "type": .string("number"),
                "minimum": .number(0),
                "maximum": .number(100),
            ])
        ]),
        "required": .array([.string("score")]),
    ])

    @Test func minimumRejectsBelowBound() {
        let result = SchemaValidator.validate(
            arguments: ["score": -1],
            against: rangeSchema
        )
        #expect(!result.isValid)
        #expect(result.field == "score")
        #expect((result.errorMessage ?? "").contains(">="))
    }

    @Test func maximumRejectsAboveBound() {
        let result = SchemaValidator.validate(
            arguments: ["score": 101],
            against: rangeSchema
        )
        #expect(!result.isValid)
        #expect(result.field == "score")
        #expect((result.errorMessage ?? "").contains("<="))
    }

    @Test func rangeAcceptsValuesAtBoundsInclusive() {
        let lower = SchemaValidator.validate(arguments: ["score": 0], against: rangeSchema)
        let upper = SchemaValidator.validate(arguments: ["score": 100], against: rangeSchema)
        #expect(lower.isValid)
        #expect(upper.isValid)
    }

    // MARK: - enum failure text

    private let capabilitiesLikeEnumSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "list": .object([
                "type": .string("string"),
                "enum": .array([.string("enabled")]),
            ])
        ]),
    ])

    /// Observed live (`capabilities`, 0.24.6): the model sent the stringified
    /// array `"[\"enabled\"]"` and the old message rendered the allowed list
    /// as `["enabled"]` — byte-identical to what it sent, so the error was
    /// uncorrectable. The message must list bare allowed values, echo the
    /// received value, and name the fix.
    @Test func enumFailureForStringifiedArrayNamesTheFix() {
        let result = SchemaValidator.validate(
            arguments: ["list": "[\"enabled\"]"],
            against: capabilitiesLikeEnumSchema
        )
        #expect(!result.isValid)
        #expect(result.field == "list")
        let message = result.errorMessage ?? ""
        #expect(message.contains(#"Property 'list' must be one of: "enabled". "#))
        #expect(message.contains(#"Got "[\"enabled\"]""#))
        #expect(message.contains("pass the bare string value, not a JSON array"))
        // The allowed list must never render as an array literal again.
        #expect(!message.contains(#"one of: ["#))
    }

    /// A plainly wrong value gets the same shape without the array hint.
    @Test func enumFailureForPlainWrongValueEchoesItWithoutArrayHint() {
        let result = SchemaValidator.validate(
            arguments: ["list": "all"],
            against: capabilitiesLikeEnumSchema
        )
        #expect(!result.isValid)
        #expect(result.field == "list")
        let message = result.errorMessage ?? ""
        #expect(message.contains(#"Property 'list' must be one of: "enabled". Got "all"."#))
        #expect(!message.contains("JSON array"))
    }
}
