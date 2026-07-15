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
        // The screenshot bug: `sandbox_install` got
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

    // MARK: - Empty-string-as-absent (optional string fields)

    private let optionalStringSchema: JSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "path": .object(["type": .string("string")]),
            "description": .object(["type": .string("string")]),
        ]),
        "required": .array([.string("path")]),
    ])

    @Test func emptyOptionalStringIsDropped() throws {
        // ShareArtifact-style: model passes `description: ""` as filler
        // for an unused optional. Coercion should drop the key so
        // downstream tools don't trip non-empty checks.
        let coerced =
            SchemaValidator.coerceArguments(
                ["path": "report.pdf", "description": ""],
                against: optionalStringSchema
            ) as? [String: Any]
        #expect(coerced?["description"] == nil)
        #expect((coerced?["path"] as? String) == "report.pdf")
    }

    @Test func whitespaceOnlyOptionalStringIsDropped() throws {
        let coerced =
            SchemaValidator.coerceArguments(
                ["path": "report.pdf", "description": "   \n\t  "],
                against: optionalStringSchema
            ) as? [String: Any]
        #expect(coerced?["description"] == nil)
    }

    @Test func emptyRequiredStringIsPreserved() throws {
        // Required fields must keep their empty value so the validator's
        // own "Missing required" check fires (the value IS present —
        // it's just empty) and the tool's `requireString` rejects with a
        // pointed `must not be empty` envelope.
        let coerced =
            SchemaValidator.coerceArguments(
                ["path": "", "description": ""],
                against: optionalStringSchema
            ) as? [String: Any]
        #expect((coerced?["path"] as? String) == "")
        #expect(coerced?["description"] == nil)
    }

    @Test func nonStringOptionalPropertyIsLeftAlone() throws {
        // Empty-string-as-absent only applies to declared `string` properties
        // — a typed `boolean` or `integer` field that happens to receive
        // `""` should fall through to the validator's type check.
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "verbose": .object(["type": .string("boolean")])
            ]),
        ])
        let coerced =
            SchemaValidator.coerceArguments(
                ["verbose": ""],
                against: schema
            ) as? [String: Any]
        #expect((coerced?["verbose"] as? String) == "")
    }

    // MARK: - Case-insensitive enum match

    private let enumSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "scope": .object([
                "type": .string("string"),
                "enum": .array([
                    .string("pinned"),
                    .string("episodes"),
                    .string("transcript"),
                ]),
            ])
        ]),
    ])

    @Test func enumNormalizesCanonicalCaseDuringCoercion() throws {
        // SearchMemory-style: model emits `"Pinned"` for an enum that
        // declares `"pinned"`. Coercion should normalise the value to
        // its canonical case so the tool body's strict equality check
        // succeeds without per-tool case-folding.
        let coerced =
            SchemaValidator.coerceArguments(
                ["scope": "Pinned"],
                against: enumSchema
            ) as? [String: Any]
        #expect((coerced?["scope"] as? String) == "pinned")
    }

    @Test func enumValidatesCaseInsensitivelyWithoutCoercion() {
        // Defence in depth: callers that bypass coercion (tests, ad-hoc
        // validators) should still get a permissive enum match.
        let r = SchemaValidator.validate(
            arguments: ["scope": "TRANSCRIPT"],
            against: enumSchema
        )
        #expect(r.isValid, "got: \(r.errorMessage ?? "?")")
    }

    @Test func enumStillRejectsUnknownValue() {
        let coerced = SchemaValidator.coerceArguments(
            ["scope": "graph"],
            against: enumSchema
        )
        let r = SchemaValidator.validate(arguments: coerced, against: enumSchema)
        #expect(!r.isValid)
        #expect(r.field == "scope")
    }

    @Test func nullableEnumAcceptsRequiredNull() {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object([
                    "type": .array([.string("string"), .string("null")]),
                    "enum": .array([.string("prefix cache"), .string("tool usage"), .null]),
                ]),
                "verbose": .object(["type": .string("boolean")]),
            ]),
            "required": .array([.string("query"), .string("verbose")]),
            "additionalProperties": .bool(false),
        ])

        let nativeNull = SchemaValidator.validate(
            arguments: ["query": NSNull(), "verbose": true],
            against: schema
        )
        #expect(nativeNull.isValid, "got: \(nativeNull.errorMessage ?? "?")")

        let coerced = SchemaValidator.coerceArguments(
            ["query": "null", "verbose": true],
            against: schema
        )
        let stringNull = SchemaValidator.validate(arguments: coerced, against: schema)
        #expect(stringNull.isValid, "got: \(stringNull.errorMessage ?? "?")")
    }

    // MARK: - Nested `properties:` wrapper rescue

    private let renderChartLikeSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "data": .object(["type": .string("string")]),
            "chartType": .object(["type": .string("string")]),
            "series": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
            ]),
        ]),
        "required": .array([.string("data"), .string("chartType"), .string("series")]),
    ])

    @Test func unwrapsPropertiesWrapper() throws {
        // RenderChart-style schema confusion: the model wrapped its real
        // arguments in a `properties:` envelope. Coercion should unwrap.
        let raw: [String: Any] = [
            "properties": [
                "data": "x,y\n1,2\n",
                "chartType": "bar",
                "series": ["y"],
            ]
        ]
        let coerced =
            SchemaValidator.coerceArguments(raw, against: renderChartLikeSchema)
            as? [String: Any]
        #expect((coerced?["chartType"] as? String) == "bar")
        #expect((coerced?["data"] as? String)?.contains("x,y") == true)
        #expect(coerced?["properties"] == nil)
        let r = SchemaValidator.validate(arguments: coerced as Any, against: renderChartLikeSchema)
        #expect(r.isValid, "got: \(r.errorMessage ?? "?")")
    }

    @Test func partialPropertiesWrapperKeepsTopLevelPriority() throws {
        // Model double-emitted: `chartType` at the top level AND inside
        // `properties`. Outer wins.
        let raw: [String: Any] = [
            "chartType": "line",
            "properties": [
                "chartType": "bar",
                "data": "x,y\n1,2\n",
                "series": ["y"],
            ],
        ]
        let coerced =
            SchemaValidator.coerceArguments(raw, against: renderChartLikeSchema)
            as? [String: Any]
        #expect((coerced?["chartType"] as? String) == "line")
        #expect((coerced?["data"] as? String)?.contains("x,y") == true)
    }

    @Test func propertiesWithoutOverlapIsLeftAlone() throws {
        // Defensive: if `properties` is present but contains no declared
        // keys, leave it alone (the schema's `additionalProperties: false`
        // can still flag it). Stops innocuous payloads from being
        // accidentally rewritten.
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "data": .object(["type": .string("string")])
            ]),
            "required": .array([.string("data")]),
        ])
        let raw: [String: Any] = [
            "data": "ok",
            "properties": ["unrelated": "stuff"],
        ]
        let coerced = SchemaValidator.coerceArguments(raw, against: schema) as? [String: Any]
        #expect(coerced?["properties"] is [String: Any])
        #expect((coerced?["data"] as? String) == "ok")
    }

    @Test func declaredPropertiesPropertyIsNotUnwrapped() throws {
        // If a schema legitimately declares a property literally named
        // `properties`, coercion must leave it intact — unwrapping would
        // silently move the user's data out of the field they meant to
        // populate.
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "properties": .object([
                    "type": .string("object")
                ])
            ]),
        ])
        let raw: [String: Any] = [
            "properties": ["nested": "value"]
        ]
        let coerced = SchemaValidator.coerceArguments(raw, against: schema) as? [String: Any]
        let nested = try #require(coerced?["properties"] as? [String: Any])
        #expect((nested["nested"] as? String) == "value")
    }

    // MARK: - Key-spelling rescue (case / snake-camel drift)

    /// `file_search`-shaped schema: the live failure was gemma-4-12B emitting
    /// `{"Pattern": "…", "target": "content"}` and spiralling on the resulting
    /// "Missing required property: pattern" for 18 identical calls.
    private let fileSearchLikeSchema: JSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "pattern": .object(["type": .string("string")]),
            "target": .object([
                "type": .string("string"),
                "enum": .array([.string("content"), .string("files")]),
            ]),
            "file_pattern": .object(["type": .string("string")]),
        ]),
        "required": .array([.string("pattern")]),
    ])

    @Test func renamesCaseDriftedKeyToDeclaredSpelling() throws {
        let coerced =
            SchemaValidator.coerceArguments(
                ["Pattern": "magic-token", "target": "content"],
                against: fileSearchLikeSchema
            ) as? [String: Any]
        #expect((coerced?["pattern"] as? String) == "magic-token")
        #expect(coerced?["Pattern"] == nil)
        let r = SchemaValidator.validate(arguments: coerced as Any, against: fileSearchLikeSchema)
        #expect(r.isValid, "got: \(r.errorMessage ?? "?")")
    }

    @Test func renamesSnakeCaseDriftToCamelDeclared() throws {
        // render_chart-shaped: `chart_type` → declared `chartType`.
        let coerced =
            SchemaValidator.coerceArguments(
                [
                    "data": "x,y\n1,2\n",
                    "chart_type": "bar",
                    "series": ["y"],
                ],
                against: renderChartLikeSchema
            ) as? [String: Any]
        #expect((coerced?["chartType"] as? String) == "bar")
        #expect(coerced?["chart_type"] == nil)
    }

    @Test func renamedKeyValueStillGetsTypeCoercion() throws {
        // The renamed key's value must flow through the normal per-property
        // coercion (here: stringified array → native array).
        let coerced =
            SchemaValidator.coerceArguments(
                [
                    "data": "x,y\n1,2\n",
                    "ChartType": "bar",
                    "Series": "[\"y\"]",
                ],
                against: renderChartLikeSchema
            ) as? [String: Any]
        #expect((coerced?["chartType"] as? String) == "bar")
        #expect((coerced?["series"] as? [String]) == ["y"])
    }

    @Test func verbatimKeyWinsOverSpellingDrift() throws {
        // Double-emit: `pattern` AND `Pattern` both present. The verbatim
        // key keeps its value; the stray key is left for the validator's
        // unknown-key report rather than silently merged.
        let coerced =
            SchemaValidator.coerceArguments(
                ["pattern": "keep-me", "Pattern": "not-me"],
                against: fileSearchLikeSchema
            ) as? [String: Any]
        #expect((coerced?["pattern"] as? String) == "keep-me")
        #expect((coerced?["Pattern"] as? String) == "not-me")
    }

    @Test func ambiguousDeclaredFoldIsNeverRenamed() throws {
        // Two declared keys that fold identically (`filePattern` +
        // `file_pattern`) make the fold ambiguous — a drifted key must NOT
        // be guessed into either one.
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "filePattern": .object(["type": .string("string")]),
                "file_pattern": .object(["type": .string("string")]),
            ]),
        ])
        let coerced =
            SchemaValidator.coerceArguments(
                ["FILEPATTERN": "*.swift"],
                against: schema
            ) as? [String: Any]
        #expect((coerced?["FILEPATTERN"] as? String) == "*.swift")
        #expect(coerced?["filePattern"] == nil)
        #expect(coerced?["file_pattern"] == nil)
    }

    @Test func unrelatedKeysAreLeftAlone() throws {
        let coerced =
            SchemaValidator.coerceArguments(
                ["pattern": "x", "bogus_key": "y"],
                against: fileSearchLikeSchema
            ) as? [String: Any]
        #expect((coerced?["bogus_key"] as? String) == "y")
    }

    @Test func missingRequiredNamesNearMissKeyWhenCoercionBypassed() {
        // Validation without coercion (defence in depth): the error must
        // name the drifted key so the model can correct its next call
        // instead of re-sending identical arguments.
        let r = SchemaValidator.validate(
            arguments: ["Pattern": "magic-token"],
            against: fileSearchLikeSchema
        )
        #expect(!r.isValid)
        #expect(r.field == "pattern")
        #expect(r.errorMessage?.contains("you sent `Pattern`") == true)
        #expect(r.errorMessage?.contains("use `pattern`") == true)
    }
}
