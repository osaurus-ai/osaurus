//
//  EvalCase.swift
//  OsaurusEvalsKit
//
//  JSON schema for a single behaviour case. Cases live as small JSON
//  files under `Suites/<domain>/` so non-Swift contributors can add new
//  ones with a text editor. Schema design:
//    - `domain` is the eval family (today: "preflight"). It selects
//      which runner code-path executes the case.
//    - `fixtures` describes the world the case should run against
//      (preflight mode, required plugins). The runner uses
//      `requirePlugins` to skip cases the local install can't satisfy
//      instead of failing them — a contributor without `osaurus.browser`
//      should still be able to run the rest of the suite.
//    - `expect` is what we'd score against. All matchers are optional
//      so a case can scope to just tools, just companions, or both.
//

import Foundation
import OsaurusCore

public struct EvalCase: Sendable, Codable, Identifiable {
    /// Unique slug, e.g. `preflight.browser.amazon-orders`. Surfaced in
    /// reports for diffing across runs.
    public let id: String
    /// Selects the runner code path. Exactly one domain is supported
    /// today (`preflight`); future domains will live under sibling
    /// directories (`Suites/AgentLoop/`, `Suites/ToolCalling/`, ...).
    public let domain: String
    /// Optional human label for reports — falls back to `id` when nil.
    public let label: String?
    /// User message the case sends through preflight.
    public let query: String
    public let fixtures: Fixtures
    public let expect: Expectations

    public init(
        id: String,
        domain: String,
        label: String? = nil,
        query: String,
        fixtures: Fixtures,
        expect: Expectations
    ) {
        self.id = id
        self.domain = domain
        self.label = label
        self.query = query
        self.fixtures = fixtures
        self.expect = expect
    }

    public struct Fixtures: Sendable, Codable {
        /// Preflight aggressiveness for the case. Default `.balanced`
        /// matches the production default — over-narrow cases should
        /// opt down explicitly so the picker behaviour they're asserting
        /// is the same one users see.
        public let preflightMode: PreflightMode?
        /// Plugin ids the case needs in the local registry. Cases with
        /// missing requirements are SKIPPED in the report (not failed)
        /// so an incomplete local setup doesn't mask real regressions.
        public let requirePlugins: [String]?

        public init(
            preflightMode: PreflightMode? = nil,
            requirePlugins: [String]? = nil
        ) {
            self.preflightMode = preflightMode
            self.requirePlugins = requirePlugins
        }
    }

    /// Mirror of `OsaurusCore.PreflightSearchMode` decoded from JSON.
    /// We don't import the OsaurusCore enum directly because we want
    /// the JSON to use lowercase strings (`"balanced"`) and don't want
    /// the schema to break if the upstream enum gains cases.
    public enum PreflightMode: String, Sendable, Codable {
        case off, narrow, balanced, wide
    }

    /// What we score against. All sub-fields are optional so a case can
    /// scope its assertions narrowly. An empty `Expectations` is valid
    /// — it acts as a smoke-test that just records what preflight did
    /// without scoring anything (useful while bootstrapping a new case).
    public struct Expectations: Sendable, Codable {
        public let tools: ToolExpectations?
        public let companions: CompanionExpectations?
        /// Schema-validation expectation for `domain == "schema"` cases.
        /// Lets us pin the SchemaValidator's behaviour against canned
        /// schema/arg pairs — extremely useful for keeping the new
        /// `oneOf` / `anyOf` / `pattern` / `items` / `minimum` /
        /// `maximum` rules from regressing.
        public let schema: SchemaExpectations?
        public let toolEnvelope: ToolEnvelopeExpectations?
        public let streamingHint: StreamingHintExpectations?
        public let prefixHash: PrefixHashExpectations?
        public let argumentCoercion: ArgumentCoercionExpectations?
        public let requestValidation: RequestValidationExpectations?

        public init(
            tools: ToolExpectations? = nil,
            companions: CompanionExpectations? = nil,
            schema: SchemaExpectations? = nil,
            toolEnvelope: ToolEnvelopeExpectations? = nil,
            streamingHint: StreamingHintExpectations? = nil,
            prefixHash: PrefixHashExpectations? = nil,
            argumentCoercion: ArgumentCoercionExpectations? = nil,
            requestValidation: RequestValidationExpectations? = nil
        ) {
            self.tools = tools
            self.companions = companions
            self.schema = schema
            self.toolEnvelope = toolEnvelope
            self.streamingHint = streamingHint
            self.prefixHash = prefixHash
            self.argumentCoercion = argumentCoercion
            self.requestValidation = requestValidation
        }
    }

    /// Expectation for `domain == "schema"` cases. Pure data — the
    /// runner feeds `arguments` through `SchemaValidator.validate`
    /// against `schema` and asserts the outcome matches `expectValid`.
    /// When `expectField` is set, the failure must additionally surface
    /// that field name. Both `schema` and `arguments` are decoded as
    /// `JSONValue` so the JSON literal in the case file maps 1:1 onto
    /// what the validator sees at runtime.
    public struct SchemaExpectations: Sendable, Codable {
        public let schema: JSONValue
        public let arguments: JSONValue
        public let expectValid: Bool
        public let expectField: String?

        public init(
            schema: JSONValue,
            arguments: JSONValue,
            expectValid: Bool,
            expectField: String? = nil
        ) {
            self.schema = schema
            self.arguments = arguments
            self.expectValid = expectValid
            self.expectField = expectField
        }
    }

    /// Expectation for `domain == "tool_envelope"` cases. Drives one
    /// of the `ToolEnvelope.{success,failure}` builders and asserts the
    /// resulting JSON parses back into a dict whose top-level keys
    /// match the expectations. `expectKeys` lets a case pin the
    /// envelope's discriminator (`ok`, `kind`, `tool`, `retryable`)
    /// without having to spell out the entire payload.
    public struct ToolEnvelopeExpectations: Sendable, Codable {
        /// Which builder to invoke. Mirrors the `ToolEnvelope` API.
        ///   - `failure`: `ToolEnvelope.failure(kind:message:tool:)`
        ///   - `successText`: `ToolEnvelope.success(tool:text:)`
        public enum Builder: String, Sendable, Codable {
            case failure
            case successText
        }
        public let builder: Builder
        /// Inputs to the builder. Unused fields are ignored — e.g.
        /// `text` is read only by `successText`, `kind` only by
        /// `failure`.
        public let kind: String?
        public let message: String?
        public let text: String?
        public let tool: String?
        /// Top-level fields of the parsed envelope JSON the case
        /// requires. Each value must equal the corresponding field
        /// (string/bool/number); use `JSONValue` so the case file
        /// matches the runtime types exactly.
        public let expectKeys: [String: JSONValue]

        public init(
            builder: Builder,
            kind: String? = nil,
            message: String? = nil,
            text: String? = nil,
            tool: String? = nil,
            expectKeys: [String: JSONValue]
        ) {
            self.builder = builder
            self.kind = kind
            self.message = message
            self.text = text
            self.tool = tool
            self.expectKeys = expectKeys
        }
    }

    /// Expectation for `domain == "streaming_hint"` cases. Drives one
    /// of the `StreamingToolHint.{encode,encodeArgs,encodeDone}`
    /// helpers, then assertions on the resulting sentinel: that
    /// `isSentinel` reports true, and that the matching `decode*`
    /// helper round-trips back to the original payload.
    public struct StreamingHintExpectations: Sendable, Codable {
        public enum Operation: String, Sendable, Codable {
            case encode  // tool name → `\u{FFFE}tool:<name>`
            case encodeArgs  // args fragment → `\u{FFFE}args:<frag>`
            case encodeDone  // {id,name,args,result} → `\u{FFFE}done:<json>`
        }
        public let op: Operation
        /// For `.encode` and `.encodeArgs` — the single string payload.
        public let payload: String?
        /// For `.encodeDone` — structured payload fields.
        public let callId: String?
        public let name: String?
        public let arguments: String?
        public let result: String?

        public init(
            op: Operation,
            payload: String? = nil,
            callId: String? = nil,
            name: String? = nil,
            arguments: String? = nil,
            result: String? = nil
        ) {
            self.op = op
            self.payload = payload
            self.callId = callId
            self.name = name
            self.arguments = arguments
            self.result = result
        }
    }

    /// Expectation for `domain == "prefix_hash"` cases. Two flavors:
    ///   - `expectHash` set → assert `computePrefixHash(a) == expectHash`
    ///   - `compareTo` set → assert `computePrefixHash(a)` and
    ///                       `computePrefixHash(compareTo)` are equal /
    ///                       not equal per `expectEqual`
    /// Cases use this to pin both stability (hash matches a literal)
    /// and structural invariants (tool-order independence, no
    /// delimiter collisions).
    public struct PrefixHashExpectations: Sendable, Codable {
        public let systemContent: String
        public let toolNames: [String]
        public let expectHash: String?
        public let compareTo: ComparisonInput?
        public let expectEqual: Bool?

        public init(
            systemContent: String,
            toolNames: [String],
            expectHash: String? = nil,
            compareTo: ComparisonInput? = nil,
            expectEqual: Bool? = nil
        ) {
            self.systemContent = systemContent
            self.toolNames = toolNames
            self.expectHash = expectHash
            self.compareTo = compareTo
            self.expectEqual = expectEqual
        }

        public struct ComparisonInput: Sendable, Codable {
            public let systemContent: String
            public let toolNames: [String]

            public init(systemContent: String, toolNames: [String]) {
                self.systemContent = systemContent
                self.toolNames = toolNames
            }
        }
    }

    /// Expectation for `domain == "argument_coercion"` cases. Drives
    /// one of `ArgumentCoercion.{stringArray,int,bool}` against an
    /// arbitrary JSON value and asserts the coerced output matches
    /// `expect`. Use `expect: null` to pin the "rejected, returns nil"
    /// branch — extremely valuable for the boolean / numeric edge
    /// cases that quantized models ship.
    public struct ArgumentCoercionExpectations: Sendable, Codable {
        public enum Helper: String, Sendable, Codable {
            case stringArray
            case int
            case bool
        }
        public let helper: Helper
        public let value: JSONValue
        public let expect: JSONValue?  // nil expectation → coercion must return nil
    }

    /// Expectation for `domain == "request_validation"` cases. Pins
    /// the accept/reject decision of `RequestValidator.unsupportedSamplerReason`
    /// for the (`n`, `response_format.type`) tuple. `expectAccept: true`
    /// asserts no rejection; otherwise the reason string must contain
    /// `expectReasonContains`.
    public struct RequestValidationExpectations: Sendable, Codable {
        public let n: Int?
        public let responseFormatType: String?
        public let expectAccept: Bool
        public let expectReasonContains: String?

        public init(
            n: Int? = nil,
            responseFormatType: String? = nil,
            expectAccept: Bool,
            expectReasonContains: String? = nil
        ) {
            self.n = n
            self.responseFormatType = responseFormatType
            self.expectAccept = expectAccept
            self.expectReasonContains = expectReasonContains
        }
    }

    public struct ToolExpectations: Sendable, Codable {
        /// Tool names that MUST appear in the picked set. Each missing
        /// name costs a fixed weight (see `Scorers.scoreTools`).
        public let mustInclude: [String]?
        /// Tool names that must NOT appear. Each spurious pick fails
        /// the contract.
        public let mustNotInclude: [String]?

        public init(mustInclude: [String]? = nil, mustNotInclude: [String]? = nil) {
            self.mustInclude = mustInclude
            self.mustNotInclude = mustNotInclude
        }
    }

    public struct CompanionExpectations: Sendable, Codable {
        /// Plugin skills (by name) that should surface in the teaser.
        /// A case asserts on names rather than the full skill object so
        /// the schema stays compact.
        public let skills: [String]?
        /// Sibling-tool overlap matcher: AT LEAST `minOverlap` of these
        /// candidates should appear in the teaser. Captures "the right
        /// SHAPE of siblings showed up" without pinning the exact list,
        /// which is helpful when sibling ordering is query-dependent.
        public let siblings: SiblingMatcher?

        public init(skills: [String]? = nil, siblings: SiblingMatcher? = nil) {
            self.skills = skills
            self.siblings = siblings
        }

        public struct SiblingMatcher: Sendable, Codable {
            public let minOverlap: Int
            public let candidates: [String]

            public init(minOverlap: Int, candidates: [String]) {
                self.minOverlap = minOverlap
                self.candidates = candidates
            }
        }
    }
}
