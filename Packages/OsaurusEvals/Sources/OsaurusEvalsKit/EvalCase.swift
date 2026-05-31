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
    /// Free-form per-case explanatory text. Echoed into the report's
    /// per-case `notes` array so a reader sees WHY a case is shaped the
    /// way it is. Used today to call out cases that are intentionally
    /// red (e.g. `capability_search.shell-execution` — `sandbox_exec`
    /// is excluded from the search index by design, so no recall fix
    /// can rescue it). Avoid using this as a debug log; keep it short
    /// and structural.
    public let notes: String?
    public let fixtures: Fixtures
    public let expect: Expectations

    public init(
        id: String,
        domain: String,
        label: String? = nil,
        query: String,
        notes: String? = nil,
        fixtures: Fixtures,
        expect: Expectations
    ) {
        self.id = id
        self.domain = domain
        self.label = label
        self.query = query
        self.notes = notes
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
        /// Methods to insert into `MethodDatabase` before the case
        /// runs (and remove afterwards). Used by `capability_search`
        /// cases that probe the methods lane — methods have no
        /// built-in seed so a fixture has to bring its own. Each
        /// entry's `id` becomes the deterministic primary key
        /// (preferred: `eval-<slug>`) so cleanup works idempotently
        /// across crashes.
        ///
        /// Insert/cleanup is wrapped around the case body in
        /// `EvalRunner.runCapabilitySearchCase`. Other domains
        /// ignore this field.
        public let seedMethods: [SeedMethod]?
        /// Skill names to flip `enabled = true` on for the duration
        /// of the case (and restore afterwards). Used by
        /// `capability_search` skill-lane fixtures because every
        /// built-in skill ships disabled-by-default and
        /// `SkillSearchService.search` post-filters disabled skills
        /// out — so a recall fixture against e.g. "Research Analyst"
        /// silently returns 0 unless we toggle it on first.
        ///
        /// Mutates the user's persistent skill state for the run
        /// window only; the runner snapshots prior state and
        /// restores it after the case body. Restoration is
        /// best-effort, not crash-safe — a process crash mid-case
        /// can leave a built-in skill flipped on. Re-running any
        /// case that names the same skill converges the state back.
        public let enableSkills: [String]?

        public init(
            preflightMode: PreflightMode? = nil,
            requirePlugins: [String]? = nil,
            seedMethods: [SeedMethod]? = nil,
            enableSkills: [String]? = nil
        ) {
            self.preflightMode = preflightMode
            self.requirePlugins = requirePlugins
            self.seedMethods = seedMethods
            self.enableSkills = enableSkills
        }
    }

    /// One method to seed into `MethodDatabase` for a case run. Schema
    /// is intentionally minimal — the recall layer reads
    /// `name`/`description`/`triggerText` (via
    /// `MethodSearchService.buildIndexText`) and needs nothing else
    /// to score recall.
    ///
    /// `body` and `triggerText` are optional in the JSON shape so
    /// fixture authors don't have to think about them — `body` is
    /// only required by the storage layer's `NOT NULL` constraint
    /// (search ignores it); `triggerText` exists so cases probing
    /// the "user phrasing differs from method name" shape can pin
    /// extra index signal. Codable's synthesized decoder doesn't
    /// honour Swift's `= ""` defaults — declaring these `Optional`
    /// is the only way to make them omittable in JSON.
    public struct SeedMethod: Sendable, Codable {
        /// Stable id used as the `methods.id` primary key. Prefer
        /// the form `eval-<slug>` so accidental leftovers in a
        /// developer's local DB are obviously test data.
        public let id: String
        public let name: String
        public let description: String
        public let triggerText: String?
        public let body: String?

        public init(
            id: String,
            name: String,
            description: String,
            triggerText: String? = nil,
            body: String? = nil
        ) {
            self.id = id
            self.name = name
            self.description = description
            self.triggerText = triggerText
            self.body = body
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
    ///
    /// TODO(eval-shape-unification): `tools.mustInclude` (preflight)
    /// and `capabilitySearch.expectedTools.anyOf` are two different
    /// shapes for asserting on tool sets across two sibling domains.
    /// Worth one cleanup pass once both runners have stabilised — pick
    /// the union (`mustInclude` + `mustNotInclude` + `anyOf` +
    /// `minMatches`) and have both domains use it. Don't block the
    /// hybrid PR on this; surfacing the divergence here so the next
    /// contributor sees it.
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
        /// Recall expectation for `domain == "capability_search"` cases.
        /// Drives the index-only path through `CapabilitySearchEvaluator`
        /// — no LLM, fast, deterministic. Used to lock in recall floors
        /// against the embedder + threshold layer that feeds preflight.
        public let capabilitySearch: CapabilitySearchExpectations?
        /// Detection expectation for `domain == "sandbox_diagnostics"`
        /// cases. Pins `inlineCodeEscapeHint` — the self-heal hint that
        /// catches multi-line code mis-escaped into a shell `-c`/`-e`
        /// string — against canned `(command, exit, stderr)` tuples.
        public let sandboxDiagnostics: SandboxDiagnosticsExpectations?

        public init(
            tools: ToolExpectations? = nil,
            companions: CompanionExpectations? = nil,
            schema: SchemaExpectations? = nil,
            toolEnvelope: ToolEnvelopeExpectations? = nil,
            streamingHint: StreamingHintExpectations? = nil,
            prefixHash: PrefixHashExpectations? = nil,
            argumentCoercion: ArgumentCoercionExpectations? = nil,
            requestValidation: RequestValidationExpectations? = nil,
            capabilitySearch: CapabilitySearchExpectations? = nil,
            sandboxDiagnostics: SandboxDiagnosticsExpectations? = nil
        ) {
            self.tools = tools
            self.companions = companions
            self.schema = schema
            self.toolEnvelope = toolEnvelope
            self.streamingHint = streamingHint
            self.prefixHash = prefixHash
            self.argumentCoercion = argumentCoercion
            self.requestValidation = requestValidation
            self.capabilitySearch = capabilitySearch
            self.sandboxDiagnostics = sandboxDiagnostics
        }
    }

    /// Expectation for `domain == "sandbox_diagnostics"` cases. The
    /// runner feeds `(command, exitCode, stderr)` through
    /// `inlineCodeEscapeHint` and asserts whether the hint fired
    /// (`expectHint`). When `hintContains` is set on a positive case the
    /// returned hint must additionally contain that substring — used to
    /// pin that the recovery instruction still names `sandbox_execute_code`.
    public struct SandboxDiagnosticsExpectations: Sendable, Codable {
        public let command: String
        public let exitCode: Int
        public let stderr: String
        public let expectHint: Bool
        public let hintContains: String?

        public init(
            command: String,
            exitCode: Int,
            stderr: String,
            expectHint: Bool,
            hintContains: String? = nil
        ) {
            self.command = command
            self.exitCode = exitCode
            self.stderr = stderr
            self.expectHint = expectHint
            self.hintContains = hintContains
        }
    }

    /// Recall expectation for the `capability_search` domain. Each
    /// non-nil `expected*` matcher must overlap the accepted hits by
    /// at least `minMatches`; `maxAccepted` (when set) caps total
    /// accepted hits — used by abstain-style cases so a permissive
    /// threshold can't silently drown the user in noise.
    public struct CapabilitySearchExpectations: Sendable, Codable {
        public struct AnyOfMatcher: Sendable, Codable {
            public let anyOf: [String]
            public let minMatches: Int

            public init(anyOf: [String], minMatches: Int) {
                self.anyOf = anyOf
                self.minMatches = minMatches
            }
        }

        /// Per-case `topK` override forwarded to
        /// `CapabilitySearchEvaluator.evaluate(query:topK:threshold:)`.
        /// `nil` uses the evaluator's default of 10.
        public let topK: Int?
        /// Per-case threshold. The CLI `--threshold` flag wins when set.
        public let thresholdOverride: Float?
        public let expectedTools: AnyOfMatcher?
        public let expectedMethods: AnyOfMatcher?
        public let expectedSkills: AnyOfMatcher?
        /// Cap on total accepted-hit count across tools+methods+skills.
        /// `nil` = no cap. `0` = abstain-style: ANY accepted hit fails
        /// the case.
        public let maxAccepted: Int?

        public init(
            topK: Int? = nil,
            thresholdOverride: Float? = nil,
            expectedTools: AnyOfMatcher? = nil,
            expectedMethods: AnyOfMatcher? = nil,
            expectedSkills: AnyOfMatcher? = nil,
            maxAccepted: Int? = nil
        ) {
            self.topK = topK
            self.thresholdOverride = thresholdOverride
            self.expectedTools = expectedTools
            self.expectedMethods = expectedMethods
            self.expectedSkills = expectedSkills
            self.maxAccepted = maxAccepted
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
