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
}
