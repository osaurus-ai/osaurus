//
//  EvalCase.swift
//  OsaurusEvalsKit
//
//  JSON schema for a single behaviour case. Cases live as small JSON
//  files under `Suites/<domain>/` so non-Swift contributors can add new
//  ones with a text editor. Schema design:
//    - `domain` is the eval family (e.g. "capability_search",
//      "capability_claims", "schema"). It selects which runner
//      code-path executes the case.
//    - `fixtures` describes the world the case should run against
//      (required plugins, seeded methods, enabled skills/tools). The
//      runner uses `requirePlugins` to skip cases the local install
//      can't satisfy instead of failing them — a contributor without
//      `osaurus.browser` should still be able to run the rest of the suite.
//    - `expect` is what we'd score against. All matchers are optional
//      so a case can scope to just the components it cares about.
//

import Foundation
import OsaurusCore

public struct EvalCase: Sendable, Codable, Identifiable {
    /// Unique slug, e.g. `capability_search.browser-prefix`. Surfaced in
    /// reports for diffing across runs.
    public let id: String
    /// Selects the runner code path (`capability_search`,
    /// `capability_claims`, `schema`, ...). Each domain's cases live
    /// under a sibling directory (`Suites/CapabilitySearch/`, ...).
    public let domain: String
    /// Optional human label for reports — falls back to `id` when nil.
    public let label: String?
    /// User message the case sends through the runner.
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
        /// Tool names to grant the agent for the duration of a
        /// `capability_claims` case (and restore afterwards). The agent's
        /// enabled set is what the enabled-capabilities manifest is built
        /// from, so a "confirm you have list_messages" case has to enable
        /// `list_messages` first. No-op when the agent is in legacy
        /// global-enabled mode (nil allowlist already grants everything).
        public let enableTools: [String]?
        /// Tool names that must NOT be enabled for the case to be valid —
        /// used by the "impossible-but-distinct" case so a host that
        /// happens to have a matching tool installed skips instead of
        /// silently changing what the case proves. The runner can't
        /// safely disable a globally-enabled tool, so it SKIPS the case
        /// (with a note) when any of these are currently enabled.
        public let ensureToolsDisabled: [String]?
        /// Workspace seed files for `agent_loop` cases. The runner
        /// creates a fresh temp directory per case, writes each entry
        /// (creating intermediate directories), runs the agent loop with
        /// `executionMode: .hostFolder(<temp dir>)`, scores the
        /// `expect.agentLoop` assertions against the resulting tree, and
        /// deletes the directory afterwards. Other domains ignore this.
        public let workspaceFiles: [WorkspaceFile]?

        public init(
            requirePlugins: [String]? = nil,
            seedMethods: [SeedMethod]? = nil,
            enableSkills: [String]? = nil,
            enableTools: [String]? = nil,
            ensureToolsDisabled: [String]? = nil,
            workspaceFiles: [WorkspaceFile]? = nil
        ) {
            self.requirePlugins = requirePlugins
            self.seedMethods = seedMethods
            self.enableSkills = enableSkills
            self.enableTools = enableTools
            self.ensureToolsDisabled = ensureToolsDisabled
            self.workspaceFiles = workspaceFiles
        }
    }

    /// One file to seed into the per-case temp workspace for
    /// `agent_loop` cases. `path` is relative to the workspace root and
    /// may contain directories (`src/main.swift`).
    public struct WorkspaceFile: Sendable, Codable {
        public let path: String
        public let contents: String

        public init(path: String, contents: String) {
            self.path = path
            self.contents = contents
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

    /// What we score against. All sub-fields are optional so a case can
    /// scope its assertions narrowly. An empty `Expectations` is valid
    /// — it acts as a smoke-test that just records the case without
    /// scoring anything (useful while bootstrapping a new case).
    public struct Expectations: Sendable, Codable {
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
        /// against the embedder + threshold layer that backs
        /// `capabilities_discover`.
        public let capabilitySearch: CapabilitySearchExpectations?
        /// Detection expectation for `domain == "sandbox_diagnostics"`
        /// cases. Pins `inlineCodeEscapeHint` — the self-heal hint that
        /// catches multi-line code mis-escaped into a shell `-c`/`-e`
        /// string — against canned `(command, exit, stderr)` tuples.
        public let sandboxDiagnostics: SandboxDiagnosticsExpectations?
        /// Behaviour expectation for `domain == "capability_claims"`
        /// cases. Combines deterministic transcript assertions (which
        /// tools the agent loop must / must not call, skill-first
        /// ordering) with an LLM-judge rubric the final answer is graded
        /// against. Drives `CapabilityClaimsEvaluator`.
        public let capabilityClaims: CapabilityClaimsExpectations?
        /// Outcome expectation for `domain == "agent_loop"` cases.
        /// Drives `AgentLoopEvaluator` against a fixture-seeded temp
        /// workspace and scores transcript assertions + workspace
        /// outcomes (file contents, command exit codes) plus an
        /// optional LLM-judge rubric.
        public let agentLoop: AgentLoopExpectations?

        public init(
            schema: SchemaExpectations? = nil,
            toolEnvelope: ToolEnvelopeExpectations? = nil,
            streamingHint: StreamingHintExpectations? = nil,
            prefixHash: PrefixHashExpectations? = nil,
            argumentCoercion: ArgumentCoercionExpectations? = nil,
            requestValidation: RequestValidationExpectations? = nil,
            capabilitySearch: CapabilitySearchExpectations? = nil,
            sandboxDiagnostics: SandboxDiagnosticsExpectations? = nil,
            capabilityClaims: CapabilityClaimsExpectations? = nil,
            agentLoop: AgentLoopExpectations? = nil
        ) {
            self.schema = schema
            self.toolEnvelope = toolEnvelope
            self.streamingHint = streamingHint
            self.prefixHash = prefixHash
            self.argumentCoercion = argumentCoercion
            self.requestValidation = requestValidation
            self.capabilitySearch = capabilitySearch
            self.sandboxDiagnostics = sandboxDiagnostics
            self.capabilityClaims = capabilityClaims
            self.agentLoop = agentLoop
        }
    }

    /// Expectation for `domain == "agent_loop"` cases. The runner seeds
    /// a temp workspace from `fixtures.workspaceFiles`, drives the
    /// canonical `AgentToolLoop` via `AgentLoopEvaluator`, then scores:
    ///   1. **Transcript** — `mustCallTools` / `mustNotCallTools`,
    ///      `maxToolCalls`, duplicate-call discipline.
    ///   2. **Workspace outcomes** — `files` content assertions and
    ///      `commands` exit-code assertions run in the workspace after
    ///      the loop ends.
    ///   3. **LLM judge** (optional) — `rubric` conditions graded
    ///      against the final assistant text.
    /// A case passes only when every present layer passes.
    public struct AgentLoopExpectations: Sendable, Codable {
        /// Loop budget (model steps). nil → evaluator default (10).
        public let maxIterations: Int?
        /// Tool names that MUST be called somewhere in the run.
        public let mustCallTools: [String]?
        /// Tool names that must NOT be called anywhere in the run.
        public let mustNotCallTools: [String]?
        /// Cap on total processed tool calls (executed + deduped). Pins
        /// listing-navigation discipline ("don't browse the whole tree").
        public let maxToolCalls: Int?
        /// When true, no identical (name, arguments) pair may EXECUTE
        /// more than once — replays through the loop's dedupe are fine
        /// (that's the mechanism working). Duplicate keys use the loop's
        /// own argument canonicalisation (sorted-key JSON), so spelling
        /// variants of the same arguments compare equal. Pins
        /// duplicate-call avoidance.
        public let noDuplicateExecutedCalls: Bool?
        /// Opt-in: when true, no processed tool call may return an error
        /// envelope. Off by default — recovery cases legitimately route
        /// through tool errors.
        public let noToolErrors: Bool?
        /// Minimum number of dedupe REPLAYS (`wasDeduped`) the transcript
        /// must contain. Asserts the loop's dedupe actually fired, not
        /// just that nothing executed twice.
        public let minDedupedReplays: Int?
        /// Substrings that must appear in at least one driver-staged
        /// notice (budget warning / dedupe notice / next-step nudge).
        /// Asserts a nudge FIRED, independent of whether the model obeyed.
        public let noticesContain: [String]?
        /// When true, the run must have actually compacted history (the
        /// sticky watermark recorded a summarize/drop). Strengthens
        /// compaction-stress beyond "the answer came out right".
        public let expectCompaction: Bool?
        /// Exits that pass. Default: `["finalResponse"]`. A
        /// wrap-up-on-budget case can accept `iterationCapReached`.
        public let allowedExits: [String]?
        /// Workspace file assertions, checked after the loop ends.
        public let files: [FileAssertion]?
        /// Commands run in the workspace after the loop ends; each must
        /// exit with its `expectExitCode`.
        public let commands: [CommandAssertion]?
        /// Substrings the final assistant text must contain (cheap
        /// deterministic check; use `rubric` for semantic grading).
        public let finalTextContains: [String]?
        /// Natural-language conditions for the LLM judge.
        public let rubric: [String]?
        /// When set, the loop's budget manager is built against this
        /// context window instead of the model's real one — the
        /// compaction-stress lever.
        public let contextWindowOverride: Int?
        /// Loop policy: when true the run ends with `toolRejected` on the
        /// first error envelope (the chat surface's policy); default
        /// false keeps the headless policy (hand the model the error and
        /// keep looping). Lets cases pin BOTH behaviours.
        public let stopOnToolRejection: Bool?
        /// Todo discipline: when true, some `todo` call with at least one
        /// checked (`[x]`) box must appear BEFORE the first `complete`
        /// call (or before the run ends, when there is no `complete`) —
        /// pins "mark items done as you go", not just "made a list once".
        public let todoUpdatedBeforeComplete: Bool?

        public init(
            maxIterations: Int? = nil,
            mustCallTools: [String]? = nil,
            mustNotCallTools: [String]? = nil,
            maxToolCalls: Int? = nil,
            noDuplicateExecutedCalls: Bool? = nil,
            noToolErrors: Bool? = nil,
            minDedupedReplays: Int? = nil,
            noticesContain: [String]? = nil,
            expectCompaction: Bool? = nil,
            allowedExits: [String]? = nil,
            files: [FileAssertion]? = nil,
            commands: [CommandAssertion]? = nil,
            finalTextContains: [String]? = nil,
            rubric: [String]? = nil,
            contextWindowOverride: Int? = nil,
            stopOnToolRejection: Bool? = nil,
            todoUpdatedBeforeComplete: Bool? = nil
        ) {
            self.maxIterations = maxIterations
            self.mustCallTools = mustCallTools
            self.mustNotCallTools = mustNotCallTools
            self.maxToolCalls = maxToolCalls
            self.noDuplicateExecutedCalls = noDuplicateExecutedCalls
            self.noToolErrors = noToolErrors
            self.minDedupedReplays = minDedupedReplays
            self.noticesContain = noticesContain
            self.expectCompaction = expectCompaction
            self.allowedExits = allowedExits
            self.files = files
            self.commands = commands
            self.finalTextContains = finalTextContains
            self.rubric = rubric
            self.contextWindowOverride = contextWindowOverride
            self.stopOnToolRejection = stopOnToolRejection
            self.todoUpdatedBeforeComplete = todoUpdatedBeforeComplete
        }

        /// One workspace-file assertion. `path` is relative to the
        /// workspace root. `exists` defaults to true; set false to
        /// assert a file was NOT created. `contains` / `equals` imply
        /// existence.
        public struct FileAssertion: Sendable, Codable {
            public let path: String
            public let exists: Bool?
            public let contains: String?
            public let equals: String?

            public init(
                path: String,
                exists: Bool? = nil,
                contains: String? = nil,
                equals: String? = nil
            ) {
                self.path = path
                self.exists = exists
                self.contains = contains
                self.equals = equals
            }
        }

        /// One post-run command assertion. `command` runs via
        /// `/bin/zsh -c` with the workspace as the working directory.
        public struct CommandAssertion: Sendable, Codable {
            public let command: String
            public let expectExitCode: Int

            public init(command: String, expectExitCode: Int) {
                self.command = command
                self.expectExitCode = expectExitCode
            }
        }
    }

    /// Expectation for `domain == "capability_claims"` cases. The runner
    /// runs the multi-turn agent loop via `CapabilityClaimsEvaluator`,
    /// then scores two ways:
    ///   1. **Deterministic** transcript checks — `mustCallTools` /
    ///      `mustNotCallTools` and the optional skill-first ordering.
    ///   2. **LLM judge** — every `rubric` condition graded against the
    ///      final assistant text. ALL must pass.
    /// A case passes only when both layers pass.
    public struct CapabilityClaimsExpectations: Sendable, Codable {
        /// Natural-language conditions the final answer must satisfy,
        /// graded by the LLM judge. e.g. "Confirms it has a
        /// list_messages tool", "Does not claim it can trade stocks".
        public let rubric: [String]
        /// Tool names that MUST be called somewhere in the loop.
        public let mustCallTools: [String]?
        /// Tool names that must NOT be called anywhere in the loop.
        public let mustNotCallTools: [String]?
        /// Skill-first ordering assertion: `skill` must be loaded (via a
        /// `capabilities_load` call carrying `skill/<name>`) before any
        /// tool in `beforeTools` is called.
        public let loadSkillFirst: SkillFirstMatcher?
        /// Cap on model round-trips. nil → evaluator default.
        public let maxIterations: Int?

        public init(
            rubric: [String],
            mustCallTools: [String]? = nil,
            mustNotCallTools: [String]? = nil,
            loadSkillFirst: SkillFirstMatcher? = nil,
            maxIterations: Int? = nil
        ) {
            self.rubric = rubric
            self.mustCallTools = mustCallTools
            self.mustNotCallTools = mustNotCallTools
            self.loadSkillFirst = loadSkillFirst
            self.maxIterations = maxIterations
        }

        public struct SkillFirstMatcher: Sendable, Codable {
            /// Skill name expected in a `capabilities_load` call's
            /// `skill/<name>` id before any gated tool runs.
            public let skill: String
            /// Tool names that must only run after the skill is loaded.
            public let beforeTools: [String]

            public init(skill: String, beforeTools: [String]) {
                self.skill = skill
                self.beforeTools = beforeTools
            }
        }
    }

    /// Expectation for `domain == "sandbox_diagnostics"` cases. The
    /// runner feeds `(command, exitCode, stderr)` through
    /// `inlineCodeEscapeHint` and asserts whether the hint fired
    /// (`expectHint`). When `hintContains` is set on a positive case the
    /// returned hint must additionally contain that substring — used to
    /// pin that the recovery instruction still names `sandbox_write_file`.
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

}
