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
        /// Per-case agent capability flags for `agent_loop` cases. When
        /// present, the runner registers a TEMPORARY agent carrying these
        /// flags (and a `reactive` schedule preset so self-scheduling
        /// isn't quiet-hours-clamped mid-eval), runs the loop under that
        /// agent's id so `AgentConfigSnapshot` / prompt gating / tool
        /// resolution see the flags exactly as production would, then
        /// deletes the agent — including its per-agent database and
        /// scheduler rows (`AgentStore.delete` cleans both). Other
        /// domains ignore this.
        public let agentCapabilities: AgentCapabilitiesFixture?
        /// Live-sandbox fixture for `agent_loop` cases. PRESENCE of this
        /// block switches the case into sandbox execution mode: the
        /// runner installs a temporary eval agent with `autonomousExec`
        /// built from these flags, boots/provisions the Linux VM, seeds
        /// the agent's VM home + secrets, and the evaluator composes with
        /// `executionMode: .sandbox(...)` instead of `.hostFolder`. Cases
        /// are SKIPPED (not failed) when the host has no working sandbox
        /// (`SandboxManager.checkAvailability` fails or setup is
        /// incomplete) — same semantics as `requirePlugins`.
        public let sandbox: SandboxFixture?
        /// Custom agents to pre-register in the isolated config store before a
        /// `default_agent` case runs (and delete afterwards). The
        /// schedule-create cases name an `agent_id`; without a real agent at
        /// that id the consolidated `osaurus_schedule` create returns a typed
        /// not-found error, and a small model can retry against it until it
        /// hits the iteration cap. Seeding a matching custom agent lets create
        /// SUCCEED, so the case proves the happy path (correct frequency
        /// mapping + a real schedule) instead of an error-retry loop. Each
        /// `id` must be a valid UUID; seeding the exact id the query references
        /// is the point. Other domains ignore this field.
        public let seedAgents: [SeedAgent]?
        /// Remote providers to pre-register (non-ephemeral, so the configure
        /// READ tools surface them) in the isolated config store before a
        /// `default_agent` case runs, then remove afterwards. The
        /// provider-rotate-key case names a provider id; without a real
        /// provider at that id `osaurus_provider({action:'set_credentials'})`
        /// returns a typed not-found and the model can only report "no such
        /// provider" instead of demonstrating rotation. Seeding the exact id
        /// the query references turns the case into the real rotation flow.
        /// Seeded providers are added with `enabled:false, autoConnect:false`
        /// so they never attempt a network connect, and the runner installs a
        /// `ProviderCredentialPromptService.bypassUI` shim for the case so a
        /// `set_credentials` call resolves headlessly instead of mounting the
        /// credential NSPanel. Each `id` must be a valid UUID. Other domains
        /// ignore this field.
        public let seedProviders: [SeedProvider]?
        /// SQL executed against the run agent's database BEFORE the loop
        /// starts (requires `agentCapabilities.dbEnabled`). Each entry may be
        /// a multi-statement script (`CREATE TABLE …; INSERT …;`) and runs
        /// through the same `db_execute` path the agent uses, so a case can
        /// stage "yesterday's" rows, a table to soft-delete/restore, or any
        /// baseline state the query then builds on. Runs after the eval agent
        /// is installed and before the model sees the task. Other domains
        /// ignore this.
        ///
        /// Gotcha: a bare `CREATE TABLE t (...)` here is a *raw* table — it
        /// lacks the reserved system columns (`id`, `_created_at`,
        /// `_updated_at`, `_deleted_at`) that `db_create_table` adds. That's
        /// fine for cases that only read it back with `db_query`/`db_execute`,
        /// but the typed tools that stamp/read those columns (`db_import`,
        /// `db_schema`, soft-delete) will fail with `no such column:
        /// _updated_at`. If a case seeds a table the model then drives a typed
        /// tool at, declare the system columns explicitly so the seed matches
        /// a real agent table:
        /// `CREATE TABLE t (id INTEGER PRIMARY KEY AUTOINCREMENT, …,`
        /// `_created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),`
        /// `_updated_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),`
        /// `_deleted_at INTEGER);`
        public let seedSql: [String]?

        public init(
            requirePlugins: [String]? = nil,
            seedMethods: [SeedMethod]? = nil,
            enableSkills: [String]? = nil,
            enableTools: [String]? = nil,
            ensureToolsDisabled: [String]? = nil,
            workspaceFiles: [WorkspaceFile]? = nil,
            agentCapabilities: AgentCapabilitiesFixture? = nil,
            sandbox: SandboxFixture? = nil,
            seedAgents: [SeedAgent]? = nil,
            seedProviders: [SeedProvider]? = nil,
            seedSql: [String]? = nil
        ) {
            self.requirePlugins = requirePlugins
            self.seedMethods = seedMethods
            self.enableSkills = enableSkills
            self.enableTools = enableTools
            self.ensureToolsDisabled = ensureToolsDisabled
            self.workspaceFiles = workspaceFiles
            self.agentCapabilities = agentCapabilities
            self.sandbox = sandbox
            self.seedAgents = seedAgents
            self.seedProviders = seedProviders
            self.seedSql = seedSql
        }
    }

    /// Sandbox-mode fixture for `agent_loop` cases. Every flag maps onto
    /// the eval agent's `AutonomousExecConfig`; omitted fields use the
    /// production defaults for an autonomous-enabled agent (commands
    /// capped at 10/turn, plugin creation on, host secret reads refused,
    /// network on, background jobs off).
    public struct SandboxFixture: Sendable, Codable {
        /// Allow `sandbox_plugin_register` (AutonomousExecConfig.pluginCreate).
        public let pluginCreate: Bool?
        /// Expose `sandbox_exec(background:true)` + `sandbox_process`.
        public let backgroundProcessEnabled: Bool?
        /// Outbound network from the VM (honored at boot — flipping it
        /// per-case does NOT restart an already-running container).
        public let networkEnabled: Bool?
        /// Combined mode only: let host read tools open secret-shaped
        /// files (`.env`, keys) in the read-only host workspace.
        public let allowHostSecretReads: Bool?
        /// `sandbox_exec` per-turn call budget.
        public let maxCommandsPerTurn: Int?
        /// Combined mode: the case's temp workspace (with
        /// `workspaceFiles`) becomes the READ-ONLY host context —
        /// `file_read` / `file_search` stay host-side while writes and
        /// execution happen in the VM (`ExecutionMode.sandbox(hostRead:)`).
        /// Default false → pure sandbox mode (no host folder tools).
        public let hostFolder: Bool?
        /// Files written into the eval agent's VM home BEFORE the run
        /// (via guest-side exec, so ownership matches the agent user).
        /// `path` is relative to the agent home.
        public let seedFiles: [WorkspaceFile]?
        /// Secrets pre-seeded into `AgentSecretsKeychain` for the eval
        /// agent (deleted after the case). Headless note: cases must use
        /// this (or pass `value` to `sandbox_secret_set`) — the no-value
        /// prompt flow can only be answered from ChatView.
        public let seedSecrets: [SeedSecret]?

        public init(
            pluginCreate: Bool? = nil,
            backgroundProcessEnabled: Bool? = nil,
            networkEnabled: Bool? = nil,
            allowHostSecretReads: Bool? = nil,
            maxCommandsPerTurn: Int? = nil,
            hostFolder: Bool? = nil,
            seedFiles: [WorkspaceFile]? = nil,
            seedSecrets: [SeedSecret]? = nil
        ) {
            self.pluginCreate = pluginCreate
            self.backgroundProcessEnabled = backgroundProcessEnabled
            self.networkEnabled = networkEnabled
            self.allowHostSecretReads = allowHostSecretReads
            self.maxCommandsPerTurn = maxCommandsPerTurn
            self.hostFolder = hostFolder
            self.seedFiles = seedFiles
            self.seedSecrets = seedSecrets
        }
    }

    /// One secret to seed into the eval agent's keychain for a sandbox
    /// case run. `key` is the env-var name the model checks/uses.
    public struct SeedSecret: Sendable, Codable {
        public let key: String
        public let value: String

        public init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }

    /// Opt-in capability flags for the temporary eval agent an
    /// `agent_loop` case runs under. Every field defaults to the
    /// production default (off) when omitted, so existing cases keep
    /// running under a plain ephemeral agent.
    public struct AgentCapabilitiesFixture: Sendable, Codable {
        /// Expose the `db_*` agent-database tool family.
        public let dbEnabled: Bool?
        /// Expose `schedule_next_run` / `cancel_next_run` / `notify`.
        public let selfSchedulingEnabled: Bool?
        /// Expose the `render_chart` tool.
        public let renderChartEnabled: Bool?
        /// Expose the `speak` tool.
        public let speakEnabled: Bool?
        /// Expose the `search_memory` recall tool.
        public let searchMemoryEnabled: Bool?
        /// Expose `applescript` / `mac_query` delegation tools (requires an
        /// installed AppleScript model at run time).
        public let appleScriptEnabled: Bool?

        public init(
            dbEnabled: Bool? = nil,
            selfSchedulingEnabled: Bool? = nil,
            renderChartEnabled: Bool? = nil,
            speakEnabled: Bool? = nil,
            searchMemoryEnabled: Bool? = nil,
            appleScriptEnabled: Bool? = nil
        ) {
            self.dbEnabled = dbEnabled
            self.selfSchedulingEnabled = selfSchedulingEnabled
            self.renderChartEnabled = renderChartEnabled
            self.speakEnabled = speakEnabled
            self.searchMemoryEnabled = searchMemoryEnabled
            self.appleScriptEnabled = appleScriptEnabled
        }

        /// True when any flag is explicitly enabled — the runner only
        /// pays the temp-agent setup cost when something is on.
        public var requestsAnyCapability: Bool {
            (dbEnabled ?? false) || (selfSchedulingEnabled ?? false)
                || (renderChartEnabled ?? false) || (speakEnabled ?? false)
                || (searchMemoryEnabled ?? false) || (appleScriptEnabled ?? false)
        }
    }

    /// One file to seed into the per-case temp workspace for
    /// `agent_loop` cases. `path` is relative to the workspace root and
    /// may contain directories (`src/main.swift`).
    public struct WorkspaceFile: Sendable, Codable {
        public let path: String
        /// Inline file body. Optional now that a file can pull its bytes
        /// from a committed fixture via `contentsFromFixture` — that keeps a
        /// 500-row CSV out of the case JSON. `contents` wins when both are
        /// set; an empty file results when neither is.
        public let contents: String?
        /// Relative path to a committed fixture whose bytes become this
        /// file's contents. Resolved by the agent_loop runner under
        /// `Packages/OsaurusEvals/Fixtures/` (with a `Fixtures/AgentDB/`
        /// fallback), so large import fixtures live next to the suite
        /// instead of inline.
        public let contentsFromFixture: String?

        public init(
            path: String,
            contents: String? = nil,
            contentsFromFixture: String? = nil
        ) {
            self.path = path
            self.contents = contents
            self.contentsFromFixture = contentsFromFixture
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

    /// A custom agent to pre-register for a `default_agent` case. `id` must be
    /// a valid UUID (the create cases reference it as `agent_id`); `name` is
    /// the display name. The runner seeds it via `AgentStore.save` and removes
    /// it after the case.
    public struct SeedAgent: Sendable, Codable {
        public let id: String
        public let name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// A remote provider to pre-register for a `default_agent` case. `id` must
    /// be a valid UUID (the rotate case references it as the provider id);
    /// `name` is the display name shown by the read tools (e.g. "OpenAI").
    /// `host` is optional (a placeholder endpoint is used when omitted) — the
    /// case never makes a real network call because the provider is seeded
    /// `enabled:false, autoConnect:false`. The runner seeds it via
    /// `RemoteProviderManager.addProvider(_:apiKey:isEphemeral:false)` so it
    /// survives the eval's ephemeral-provider read filter, and removes it
    /// after the case.
    public struct SeedProvider: Sendable, Codable {
        public let id: String
        public let name: String
        public let host: String?

        public init(id: String, name: String, host: String? = nil) {
            self.id = id
            self.name = name
            self.host = host
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
        /// Transcript-grounding expectation for `domain == "tool_result_grounding"`.
        /// Pure-data: replays a frozen tool-call/result/final-answer transcript
        /// and scores whether the final answer is grounded in the named tool
        /// result rather than tool-call arguments.
        public let toolResultGrounding: ToolResultGroundingExpectations?
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
        /// Decision expectation for `domain == "computer_use"` cases.
        /// Pure-data: feeds a scripted action + resolution context through
        /// the harness's `EffectClassifier` and `AutonomyPolicy` and pins
        /// the resulting effect class + gate disposition. No driver, no
        /// permissions, no LLM — CI-safe like `schema` / `request_validation`.
        public let computerUse: ComputerUseExpectations?
        /// Model-driven expectation for `domain == "computer_use_loop"` cases.
        /// Unlike `computerUse` (a pure-data gate check), this drives the real
        /// `ComputerUseLoop` against a deterministic in-memory
        /// `ScriptedCUDriver`: the chosen model perceives a scripted AX tree,
        /// proposes `agent_action`s, and the driver mutates state in response.
        /// The case is scored on the OUTCOME (did the goal state get reached)
        /// plus the loop's telemetry — the lane for "can a small local model
        /// actually drive Computer Use", with no real Accessibility / Screen
        /// Recording and no flaky on-screen UI.
        public let computerUseLoop: ComputerUseLoopExpectations?
        /// Behaviour expectation for `domain == "default_agent"` cases. Drives
        /// `DefaultAgentConfigurationEvaluator` (the multi-turn loop pinned to
        /// the built-in Default configuration agent) and scores deterministic
        /// transcript assertions — which `osaurus_*` tool the model calls,
        /// the arguments it passes (`argsMustContain`), and which tools it must
        /// NOT touch — plus an optional LLM-judge rubric.
        public let defaultAgent: DefaultAgentExpectations?
        /// Distillation expectation for `domain == "screen_context"` cases.
        /// Pure-data: replays a captured/synthetic accessibility tree
        /// (`ScreenContextFixture`) through `ScreenContextDistiller` via the
        /// `FixtureCUDriver` and scores deterministic matchers against the
        /// rendered `[Screen Context]` block (plus an optional LLM-judge
        /// rubric). The deterministic matchers run with NO model, so the lane
        /// is CI-safe like `computer_use` / `schema`.
        public let screenContext: ScreenContextExpectations?
        /// Outcome expectation for `domain == "subagent"` cases. Drives the
        /// shared `SubagentSession` host through `SubagentJobEvaluator` in one
        /// of three lanes (`scripted` model-free, live `spawn`, live `image`)
        /// and scores the compact result envelope + the unified feed. The
        /// scripted lane is CI-safe (no model); the spawn/image lanes skip
        /// gracefully when the host has no spawnable agent / image model.
        public let subagent: SubagentExpectations?
        /// Capability expectation for `domain == "apple_script"` cases. Drives
        /// the production `AppleScriptLoop` through `AppleScriptEvaluator` in one
        /// of three lanes (`scripted` model-free, `live` real-model + mock
        /// executor, `liveProof` real-model + real executor) and scores the run:
        /// status / outcome, placeholder use, generated-script matchers, captured
        /// values, blocked writes, effect classes, mock-world (or real) final
        /// state, step / token ceilings, and an optional LLM-judge rubric. The
        /// scripted lane is CI-safe (no model); the `live` / `liveProof` lanes
        /// skip gracefully when no AppleScript model is installed.
        public let appleScript: AppleScriptExpectations?
        /// Calibration expectation for `domain == "judge_calibration"` cases:
        /// a frozen assistant reply + rubric conditions whose correct verdicts
        /// are KNOWN. The runner grades the reply with the resolved judge and
        /// scores the JUDGE against the known verdicts — the lane that makes a
        /// judge-model change itself measurable (and catches a judge that
        /// rubber-stamps or invents requirements).
        public let judgeCalibration: JudgeCalibrationExpectations?
        /// Micro-benchmark expectation for `domain == "micro_perf"` cases:
        /// a fixed prompt decoded to a fixed length N times with median ±
        /// stdev reporting — the stable perf row for `history.jsonl` trends
        /// (behaviour cases ride varying prompt sizes and can't be one).
        public let microPerf: MicroPerfExpectations?

        public init(
            schema: SchemaExpectations? = nil,
            toolEnvelope: ToolEnvelopeExpectations? = nil,
            toolResultGrounding: ToolResultGroundingExpectations? = nil,
            streamingHint: StreamingHintExpectations? = nil,
            prefixHash: PrefixHashExpectations? = nil,
            argumentCoercion: ArgumentCoercionExpectations? = nil,
            requestValidation: RequestValidationExpectations? = nil,
            capabilitySearch: CapabilitySearchExpectations? = nil,
            sandboxDiagnostics: SandboxDiagnosticsExpectations? = nil,
            capabilityClaims: CapabilityClaimsExpectations? = nil,
            agentLoop: AgentLoopExpectations? = nil,
            computerUse: ComputerUseExpectations? = nil,
            computerUseLoop: ComputerUseLoopExpectations? = nil,
            defaultAgent: DefaultAgentExpectations? = nil,
            screenContext: ScreenContextExpectations? = nil,
            subagent: SubagentExpectations? = nil,
            appleScript: AppleScriptExpectations? = nil,
            judgeCalibration: JudgeCalibrationExpectations? = nil,
            microPerf: MicroPerfExpectations? = nil
        ) {
            self.schema = schema
            self.toolEnvelope = toolEnvelope
            self.toolResultGrounding = toolResultGrounding
            self.streamingHint = streamingHint
            self.prefixHash = prefixHash
            self.argumentCoercion = argumentCoercion
            self.requestValidation = requestValidation
            self.capabilitySearch = capabilitySearch
            self.sandboxDiagnostics = sandboxDiagnostics
            self.capabilityClaims = capabilityClaims
            self.agentLoop = agentLoop
            self.computerUse = computerUse
            self.computerUseLoop = computerUseLoop
            self.defaultAgent = defaultAgent
            self.screenContext = screenContext
            self.subagent = subagent
            self.appleScript = appleScript
            self.judgeCalibration = judgeCalibration
            self.microPerf = microPerf
        }
    }

    /// Expectation for `domain == "judge_calibration"` cases. Unlike every
    /// other LLM domain — where the judge grades the RUN MODEL's output —
    /// this lane inverts the roles: `finalText` is a frozen, hand-written
    /// assistant reply, `conditions` is the rubric handed to the judge, and
    /// `expectedVerdicts` is the ground truth a competent grader must
    /// produce. The case passes iff the resolved judge (JUDGE_MODEL / strong
    /// `*_API_KEY` / self-judge fallback) reproduces every expected verdict,
    /// so the score measures the JUDGE, making "swap the judge model" a
    /// diffable change instead of an invisible trust shift.
    public struct JudgeCalibrationExpectations: Sendable, Codable {
        /// Frozen assistant reply the judge grades. Authored so each
        /// condition's correct verdict is unambiguous to a careful human.
        public let finalText: String
        /// Rubric conditions passed to the judge, in order.
        public let conditions: [String]
        /// Ground-truth verdict per condition (index-aligned with
        /// `conditions`; decode validation enforces equal counts).
        public let expectedVerdicts: [Bool]

        public init(finalText: String, conditions: [String], expectedVerdicts: [Bool]) {
            self.finalText = finalText
            self.conditions = conditions
            self.expectedVerdicts = expectedVerdicts
        }
    }

    /// Expectation for `domain == "micro_perf"` cases — the dedicated
    /// perf lane. Behaviour suites measure tok/s as a ride-along over
    /// varying prompt/decode sizes, which is too noisy to trend; this lane
    /// pins BOTH sides (fixed prompt = `query` × `promptRepeat`, fixed
    /// decode = `maxTokens`), runs `reps` measured generations after one
    /// unmeasured warm-up, and reports median ± stdev — the stable row for
    /// `history.jsonl`. No tools, no judge, temperature 0.
    public struct MicroPerfExpectations: Sendable, Codable {
        /// Measured generations (excludes the unmeasured warm-up rep).
        /// Decode-validated ≥ 2 so median/stdev are meaningful.
        public let reps: Int
        /// Fixed decode cap (`max_tokens`) for every rep. Pair with a
        /// prompt that always saturates it (e.g. "count to 500") so decode
        /// length is genuinely fixed rather than EOS-variable.
        public let maxTokens: Int
        /// Repeat `query` this many times (joined by a space) to build the
        /// effective prompt — a fixture-friendly way to author a long
        /// fixed-prefill case without committing kilobytes of filler.
        /// Default 1.
        public let promptRepeat: Int?
        /// Optional floor: fail the row when the MEDIAN decode speed drops
        /// below this. Unset = measurement-only row (recommended: absolute
        /// floors are machine-specific; the diff/history trend is the gate).
        public let minDecodeTokensPerSecond: Double?
        /// Optional ceiling on the MEDIAN time-to-first-token (ms).
        public let maxTtftMs: Double?

        public init(
            reps: Int,
            maxTokens: Int,
            promptRepeat: Int? = nil,
            minDecodeTokensPerSecond: Double? = nil,
            maxTtftMs: Double? = nil
        ) {
            self.reps = reps
            self.maxTokens = maxTokens
            self.promptRepeat = promptRepeat
            self.minDecodeTokensPerSecond = minDecodeTokensPerSecond
            self.maxTtftMs = maxTtftMs
        }
    }

    /// Expectation for `domain == "tool_result_grounding"` cases. The runner
    /// does not call a model. It scores a committed transcript fixture so proof
    /// artifacts can state: a tool was called, a result was returned, the final
    /// answer happened after that result, and specific answer fragments came
    /// from the result payload rather than from call arguments.
    public struct ToolResultGroundingExpectations: Sendable, Codable {
        public let events: [Event]
        public let assertions: [Assertion]
        /// Default true: the scored assistant answer must appear after at least
        /// one tool result. Set false only for negative/unit fixtures.
        public let requireFinalAfterToolResults: Bool?
        /// Default true: every tool result must match a prior tool call by id.
        public let requireMatchedResults: Bool?

        public init(
            events: [Event],
            assertions: [Assertion],
            requireFinalAfterToolResults: Bool? = nil,
            requireMatchedResults: Bool? = nil
        ) {
            self.events = events
            self.assertions = assertions
            self.requireFinalAfterToolResults = requireFinalAfterToolResults
            self.requireMatchedResults = requireMatchedResults
        }

        public struct Event: Sendable, Codable {
            public let kind: String
            public let callId: String?
            public let tool: String?
            public let arguments: String?
            public let content: String?

            public init(
                kind: String,
                callId: String? = nil,
                tool: String? = nil,
                arguments: String? = nil,
                content: String? = nil
            ) {
                self.kind = kind
                self.callId = callId
                self.tool = tool
                self.arguments = arguments
                self.content = content
            }
        }

        public struct Assertion: Sendable, Codable {
            /// The tool result that grounds this assertion.
            public let callId: String
            /// Every fragment must appear in the final answer and in the named
            /// result payload. This makes "answer copied from arguments" fail.
            public let answerMustContain: [String]?
            /// Every fragment must be absent from the final answer.
            public let answerMustNotContain: [String]?
            /// Every fragment must appear in the named result payload.
            public let resultMustContain: [String]?
            /// Every fragment must be absent from the original tool arguments.
            public let argumentsMustNotContain: [String]?

            public init(
                callId: String,
                answerMustContain: [String]? = nil,
                answerMustNotContain: [String]? = nil,
                resultMustContain: [String]? = nil,
                argumentsMustNotContain: [String]? = nil
            ) {
                self.callId = callId
                self.answerMustContain = answerMustContain
                self.answerMustNotContain = answerMustNotContain
                self.resultMustContain = resultMustContain
                self.argumentsMustNotContain = argumentsMustNotContain
            }
        }
    }

    /// Expectation for `domain == "screen_context"` cases. Carries the scene
    /// (a `ScreenContextFixture`, referenced by `fixture` path or inlined as
    /// `scene`) plus matchers scored against the distiller's rendered block:
    ///   - **Deterministic** (CI-safe, no model): `mustContain` /
    ///     `mustNotContain` substring gates, `noiseRegexMustNotMatch` (a regex
    ///     that must NOT match — e.g. a bare-version-token line), the focused
    ///     field's `focusedRoleEquals` / `selectedTextContains` /
    ///     `viewingContains`, the `gistContains` "Doing:" check, and
    ///     `orderedContains` (A appears before B — pins the editor-beats-chrome
    ///     ranking).
    ///   - **LLM judge** (optional, off-CI): every `rubric` condition graded
    ///     against the rendered block.
    /// A case passes only when every present matcher passes.
    public struct ScreenContextExpectations: Sendable, Codable {
        /// Relative path to a fixture JSON, resolved under
        /// `Packages/OsaurusEvals/Fixtures/ScreenContext/`. Mutually exclusive
        /// with `scene` (inline wins when both are present).
        public let fixture: String?
        /// An inline fixture — handy for committed synthetic cases that don't
        /// want a separate file. Takes precedence over `fixture`.
        public let scene: ScreenContextFixture?
        /// Substrings the rendered block MUST contain.
        public let mustContain: [String]?
        /// Substrings the rendered block must NOT contain (the noise gate).
        public let mustNotContain: [String]?
        /// Regular expressions (matched multi-line) that must NOT match the
        /// rendered block — e.g. `(?m)^- \d+\.\d+\.\d+$` for a standalone
        /// version-number bullet.
        public let noiseRegexMustNotMatch: [String]?
        /// The focused element's friendly role must equal this (e.g. `text area`).
        public let focusedRoleEquals: String?
        /// The focused element's selected text must contain this substring.
        public let selectedTextContains: String?
        /// Substrings the focused element's "Viewing:" slice must contain.
        public let viewingContains: [String]?
        /// Substrings the activity gist ("Doing:" line) must contain.
        public let gistContains: [String]?
        /// Ordered-subsequence assertions over the rendered block: for each
        /// inner array, every element must appear, in order (the first strictly
        /// before the next). Pins ranking, e.g. editor body before sidebar.
        public let orderedContains: [[String]]?
        /// Natural-language conditions for the LLM judge (optional, off-CI).
        public let rubric: [String]?

        public init(
            fixture: String? = nil,
            scene: ScreenContextFixture? = nil,
            mustContain: [String]? = nil,
            mustNotContain: [String]? = nil,
            noiseRegexMustNotMatch: [String]? = nil,
            focusedRoleEquals: String? = nil,
            selectedTextContains: String? = nil,
            viewingContains: [String]? = nil,
            gistContains: [String]? = nil,
            orderedContains: [[String]]? = nil,
            rubric: [String]? = nil
        ) {
            self.fixture = fixture
            self.scene = scene
            self.mustContain = mustContain
            self.mustNotContain = mustNotContain
            self.noiseRegexMustNotMatch = noiseRegexMustNotMatch
            self.focusedRoleEquals = focusedRoleEquals
            self.selectedTextContains = selectedTextContains
            self.viewingContains = viewingContains
            self.gistContains = gistContains
            self.orderedContains = orderedContains
            self.rubric = rubric
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
        /// At least ONE of these tool names must be called (OR semantics).
        /// Use when several tools satisfy the same contract (e.g. shell vs
        /// browser for a fetch attempt).
        public let mustCallAnyTools: [String]?
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
        /// Sandbox-home file assertions for cases with
        /// `fixtures.sandbox`. Same shape as `files`, but paths resolve
        /// against the eval agent's VM home dir READ FROM THE HOST via
        /// the VirtioFS mount (`~/.osaurus/container/workspace/agents/
        /// <agent>/`) — no guest exec needed to score.
        public let sandboxFiles: [FileAssertion]?
        /// Commands run in the workspace after the loop ends; each must
        /// exit with its `expectExitCode`.
        public let commands: [CommandAssertion]?
        /// Substrings the final assistant text must contain (cheap
        /// deterministic check; use `rubric` for semantic grading).
        public let finalTextContains: [String]?
        /// Substrings the final assistant text must NOT contain
        /// (case-insensitive). The prompt-injection lane's canary check:
        /// plant a marker in the adversarial fixture (secret value,
        /// compliance token) and fail the case if it surfaces in the
        /// answer — leak detection with zero judge involvement.
        public let finalTextMustNotContain: [String]?
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
        /// Ordered-subsequence assertion: these tool names must appear in
        /// the transcript IN THIS ORDER (other calls may interleave).
        /// Pins procedures where order matters (todo before edits, backup
        /// before mutate, db insert before query, artifact before complete).
        public let mustCallToolsInOrder: [String]?
        /// Artifact-delivery assertion: at least `minCount` (default 1)
        /// successful `share_artifact` calls whose result parses as a real
        /// artifact envelope (`Artifact shared:` header), optionally
        /// pinning the shared filename and requiring a description.
        public let artifactShared: ArtifactSharedAssertion?
        /// Self-scheduling outcome: a `schedule_next_run` write must have
        /// landed in the scheduler store for the run's agent (checked
        /// post-run via `LocalAgentBridge.nextRun`). Requires
        /// `fixtures.agentCapabilities.selfSchedulingEnabled`.
        public let scheduledRun: ScheduledRunAssertion?
        /// Post-run SQL checks against the run agent's database. Requires
        /// `fixtures.agentCapabilities.dbEnabled`. Each query runs through
        /// the same `LocalAgentBridge` the `db_*` tools use.
        public let dbState: [DbStateAssertion]?
        /// Per-tool transcript hygiene audits (call-count bounds, error
        /// ceilings, argument substrings). The folder-tool discipline lane.
        public let toolUsageAudit: [ToolUsageAudit]?
        /// Optional context-cost ceiling: the run FAILS if the estimated
        /// input (prompt + frozen tool schema, summed across every model
        /// step) exceeds this. Mirrors `computer_use_loop`'s
        /// `scoredMaxModelTokens`; nil → reported, not scored. Pin this on a
        /// case once the optimization loop has established a good value so a
        /// later prompt/tool regression that re-bloats context fails the case
        /// instead of silently costing tokens.
        public let scoredMaxPromptTokens: Int?
        /// Optional total-cost ceiling (input + output, summed across steps).
        /// nil → reported, not scored.
        public let scoredMaxTotalTokens: Int?

        public init(
            maxIterations: Int? = nil,
            mustCallTools: [String]? = nil,
            mustCallAnyTools: [String]? = nil,
            mustNotCallTools: [String]? = nil,
            maxToolCalls: Int? = nil,
            noDuplicateExecutedCalls: Bool? = nil,
            noToolErrors: Bool? = nil,
            minDedupedReplays: Int? = nil,
            noticesContain: [String]? = nil,
            expectCompaction: Bool? = nil,
            allowedExits: [String]? = nil,
            files: [FileAssertion]? = nil,
            sandboxFiles: [FileAssertion]? = nil,
            commands: [CommandAssertion]? = nil,
            finalTextContains: [String]? = nil,
            finalTextMustNotContain: [String]? = nil,
            rubric: [String]? = nil,
            contextWindowOverride: Int? = nil,
            stopOnToolRejection: Bool? = nil,
            todoUpdatedBeforeComplete: Bool? = nil,
            mustCallToolsInOrder: [String]? = nil,
            artifactShared: ArtifactSharedAssertion? = nil,
            scheduledRun: ScheduledRunAssertion? = nil,
            dbState: [DbStateAssertion]? = nil,
            toolUsageAudit: [ToolUsageAudit]? = nil,
            scoredMaxPromptTokens: Int? = nil,
            scoredMaxTotalTokens: Int? = nil
        ) {
            self.maxIterations = maxIterations
            self.mustCallTools = mustCallTools
            self.mustCallAnyTools = mustCallAnyTools
            self.mustNotCallTools = mustNotCallTools
            self.maxToolCalls = maxToolCalls
            self.noDuplicateExecutedCalls = noDuplicateExecutedCalls
            self.noToolErrors = noToolErrors
            self.minDedupedReplays = minDedupedReplays
            self.noticesContain = noticesContain
            self.expectCompaction = expectCompaction
            self.allowedExits = allowedExits
            self.files = files
            self.sandboxFiles = sandboxFiles
            self.commands = commands
            self.finalTextContains = finalTextContains
            self.finalTextMustNotContain = finalTextMustNotContain
            self.rubric = rubric
            self.contextWindowOverride = contextWindowOverride
            self.stopOnToolRejection = stopOnToolRejection
            self.todoUpdatedBeforeComplete = todoUpdatedBeforeComplete
            self.mustCallToolsInOrder = mustCallToolsInOrder
            self.artifactShared = artifactShared
            self.scheduledRun = scheduledRun
            self.dbState = dbState
            self.toolUsageAudit = toolUsageAudit
            self.scoredMaxPromptTokens = scoredMaxPromptTokens
            self.scoredMaxTotalTokens = scoredMaxTotalTokens
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
            /// When true, `contains` matches case-insensitively — for
            /// natural-language contracts ("include the word 'killed'")
            /// where sentence-position capitalization is not a defect.
            /// Default false: exact-content contracts stay strict.
            public let caseInsensitive: Bool?

            public init(
                path: String,
                exists: Bool? = nil,
                contains: String? = nil,
                equals: String? = nil,
                caseInsensitive: Bool? = nil
            ) {
                self.path = path
                self.exists = exists
                self.contains = contains
                self.equals = equals
                self.caseInsensitive = caseInsensitive
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

        /// Artifact-delivery assertion. A qualifying call is a
        /// `share_artifact` transcript entry whose result was NOT an
        /// error envelope and whose result text carries the artifact
        /// header (`Artifact shared:`). `filenameContains` matches the
        /// reported `Filename:` line; `descriptionRequired` demands a
        /// `Description:` line (i.e. the model passed `description`).
        public struct ArtifactSharedAssertion: Sendable, Codable {
            public let minCount: Int?
            public let filenameContains: String?
            public let descriptionRequired: Bool?

            public init(
                minCount: Int? = nil,
                filenameContains: String? = nil,
                descriptionRequired: Bool? = nil
            ) {
                self.minCount = minCount
                self.filenameContains = filenameContains
                self.descriptionRequired = descriptionRequired
            }
        }

        /// Self-scheduling outcome assertion, checked against the
        /// scheduler store after the loop ends (not just the transcript —
        /// a clamped/rejected `schedule_next_run` would still appear in
        /// the transcript but never land a row).
        public struct ScheduledRunAssertion: Sendable, Codable {
            /// Substring the persisted next-run `instructions` must contain.
            public let instructionsContain: String?

            public init(instructionsContain: String? = nil) {
                self.instructionsContain = instructionsContain
            }
        }

        /// One post-run SQL check against the run agent's database.
        /// `expectRowCountAtLeast` floors the returned row count;
        /// `expectRowCountEquals` pins it exactly; `expectFirstValue`
        /// string-compares the first column of the first row (numbers
        /// compared by canonical string form); `expectColumns` pins the
        /// returned column names in order (the shape of a transform/view);
        /// `expectValues` string-compares the FIRST row column-by-column so a
        /// computed aggregate row (e.g. a daily trend) can be asserted whole.
        public struct DbStateAssertion: Sendable, Codable {
            public let sql: String
            public let expectRowCountAtLeast: Int?
            public let expectRowCountEquals: Int?
            public let expectFirstValue: String?
            public let expectColumns: [String]?
            public let expectValues: [String]?

            public init(
                sql: String,
                expectRowCountAtLeast: Int? = nil,
                expectRowCountEquals: Int? = nil,
                expectFirstValue: String? = nil,
                expectColumns: [String]? = nil,
                expectValues: [String]? = nil
            ) {
                self.sql = sql
                self.expectRowCountAtLeast = expectRowCountAtLeast
                self.expectRowCountEquals = expectRowCountEquals
                self.expectFirstValue = expectFirstValue
                self.expectColumns = expectColumns
                self.expectValues = expectValues
            }
        }

        /// Per-tool transcript hygiene audit. Counts include dedupe
        /// replays (they're processed calls the model asked for);
        /// `maxErrors` counts error envelopes returned by the tool.
        /// `argsMustContain` requires at least one call whose arguments
        /// contain the substring; `argsMustNotContain` forbids the
        /// substring across every call to the tool (e.g. `shell_run`
        /// args must never contain `cat ` when `file_read` is the
        /// sanctioned read path).
        public struct ToolUsageAudit: Sendable, Codable {
            public let tool: String
            public let maxCalls: Int?
            public let minCalls: Int?
            public let maxErrors: Int?
            public let argsMustContain: String?
            public let argsMustNotContain: String?

            public init(
                tool: String,
                maxCalls: Int? = nil,
                minCalls: Int? = nil,
                maxErrors: Int? = nil,
                argsMustContain: String? = nil,
                argsMustNotContain: String? = nil
            ) {
                self.tool = tool
                self.maxCalls = maxCalls
                self.minCalls = minCalls
                self.maxErrors = maxErrors
                self.argsMustContain = argsMustContain
                self.argsMustNotContain = argsMustNotContain
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

    /// Expectation for `domain == "default_agent"` cases. The runner drives
    /// the multi-turn agent loop pinned to the built-in Default
    /// (configuration) agent via `DefaultAgentConfigurationEvaluator`, then
    /// scores:
    ///   1. **Deterministic** transcript checks — `mustCallTools` /
    ///      `mustNotCallTools` and per-call `argsMustContain` argument
    ///      assertions (e.g. `osaurus_provider` was called with
    ///      `action: add` and `provider: anthropic`).
    ///   2. **LLM judge** — every `rubric` condition (if any) graded against
    ///      the final assistant text.
    /// A case passes only when every present layer passes. `rubric` is
    /// optional so a pure tool-contract case (no natural-language grading)
    /// can omit it.
    public struct DefaultAgentExpectations: Sendable, Codable {
        /// Natural-language conditions the final answer must satisfy, graded
        /// by the LLM judge. Omit for a pure tool-contract case.
        public let rubric: [String]?
        /// Tool names that MUST be called somewhere in the loop.
        public let mustCallTools: [String]?
        /// Tool names that must NOT be called anywhere in the loop — used to
        /// pin isolation (the Default agent must never reach
        /// `capabilities_discover` / `capabilities_load`, or folder / sandbox /
        /// db / memory tools) and out-of-scope honesty.
        ///
        /// One documented exception, applied in the runner (not here): on a
        /// model that prefers a compact prompt, the Default agent defers its
        /// per-domain configure write tools and lazy-loads the needed one via
        /// `capabilities_load tool/<write>`. The scorer exempts a
        /// `capabilities_load` offender there IFF the run model is compact and
        /// every mid-session load was a configure write — `capabilities_discover`
        /// and loads on large models stay flagged.
        public let mustNotCallTools: [String]?
        /// Per-call argument assertions. Each matcher requires AT LEAST ONE
        /// call to its `tool` whose parsed arguments satisfy every
        /// key→substring pair — robust to whitespace and key order because
        /// the runner parses the arguments JSON rather than substring-matching
        /// the raw string. The canonical way to pin the chosen `action` and
        /// the salient fields of a consolidated configure write.
        public let argsMustContain: [ToolArgsMatcher]?
        /// Cap on model round-trips. nil → evaluator default.
        public let maxIterations: Int?

        public init(
            rubric: [String]? = nil,
            mustCallTools: [String]? = nil,
            mustNotCallTools: [String]? = nil,
            argsMustContain: [ToolArgsMatcher]? = nil,
            maxIterations: Int? = nil
        ) {
            self.rubric = rubric
            self.mustCallTools = mustCallTools
            self.mustNotCallTools = mustNotCallTools
            self.argsMustContain = argsMustContain
            self.maxIterations = maxIterations
        }

        /// One per-call argument assertion: at least one call to `tool` whose
        /// parsed arguments contain every `(key, valueSubstring)` pair in
        /// `args`. The value match is a case-insensitive substring over the
        /// stringified argument value, so `{"action": "add"}` matches whether
        /// the model emitted `add` or `ADD`, and `{"provider": "anthropic"}`
        /// matches a value of `anthropic`.
        public struct ToolArgsMatcher: Sendable, Codable {
            public let tool: String
            public let args: [String: String]

            public init(tool: String, args: [String: String]) {
                self.tool = tool
                self.args = args
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

    /// Expectation for `domain == "computer_use"` cases. Pins the
    /// Computer Use harness's two deterministic gate inputs end-to-end:
    ///   1. `EffectClassifier.classify(...)` — how a scripted action +
    ///      resolution context (resolved role/label, app, optional per-app
    ///      recipe) is ranked (`read`/`navigate`/`edit`/`consequential`).
    ///   2. `AutonomyPolicy.disposition(...)` — what the resolved policy
    ///      (global preset + per-app overrides + optional agent ceiling)
    ///      does with that effect (`allow`/`confirm`/`deny`), plus the
    ///      allowlist gate (`isAppAllowed`).
    /// All inputs are plain data, so the case runs with no driver, no
    /// permissions, and no model — exactly the lane CI can run on every PR
    /// to lock the safe-by-default gate against regressions.
    public struct ComputerUseExpectations: Sendable, Codable {
        // --- Action under test (mirrors `AgentAction`) ---
        /// `AgentVerb` raw value: observe, find, click, type, set_value,
        /// clear, press_key, scroll, open, done, give_up.
        public let verb: String
        /// `target.describe` natural-language phrase (optional).
        public let describe: String?
        /// `target.mark` (optional; presence makes the target non-empty).
        public let mark: Int?
        /// Payload for type / set_value (optional).
        public let text: String?
        /// Key name for press_key (optional).
        public let key: String?
        /// Modifier names for press_key (optional).
        public let modifiers: [String]?
        /// Rationale/narration — scanned for recipient signals (optional).
        public let note: String?

        // --- Resolution context (what `TargetResolver` would surface) ---
        /// The resolved element role, e.g. `AXButton` (optional).
        public let resolvedRole: String?
        /// The resolved element label, e.g. `Send` (optional).
        public let resolvedLabel: String?
        /// The focused app name, e.g. `Safari` (optional).
        public let appName: String?
        /// When true, merge `AppRecipes.signals(for: appName)` into the
        /// classifier (per-app refinements). Default false.
        public let useRecipes: Bool?

        // --- Policy under test (mirrors `AutonomyPolicy` + ceiling) ---
        /// `AutonomyPreset` raw value for the global stance. Default
        /// `balanced` when omitted.
        public let preset: String?
        /// Per-app overrides: app name → `AutonomyPreset` raw value.
        public let perApp: [String: String]?
        /// App allowlist (normalized-compared). Empty/omitted = allow all.
        public let allowlist: [String]?
        /// `AutonomyPreset` raw value to cap the agent at (via
        /// `AutonomyCeiling.cappedAt`). Omitted = no ceiling.
        public let ceiling: String?

        // --- Expectations (any subset; an empty set just records) ---
        /// Expected `EffectClass` raw value from the classifier.
        public let expectEffect: String?
        /// Expected `AutonomyDisposition` raw value from the policy.
        public let expectDisposition: String?
        /// Expected `isAppAllowed` result for the allowlist gate.
        public let expectAllowed: Bool?

        public init(
            verb: String,
            describe: String? = nil,
            mark: Int? = nil,
            text: String? = nil,
            key: String? = nil,
            modifiers: [String]? = nil,
            note: String? = nil,
            resolvedRole: String? = nil,
            resolvedLabel: String? = nil,
            appName: String? = nil,
            useRecipes: Bool? = nil,
            preset: String? = nil,
            perApp: [String: String]? = nil,
            allowlist: [String]? = nil,
            ceiling: String? = nil,
            expectEffect: String? = nil,
            expectDisposition: String? = nil,
            expectAllowed: Bool? = nil
        ) {
            self.verb = verb
            self.describe = describe
            self.mark = mark
            self.text = text
            self.key = key
            self.modifiers = modifiers
            self.note = note
            self.resolvedRole = resolvedRole
            self.resolvedLabel = resolvedLabel
            self.appName = appName
            self.useRecipes = useRecipes
            self.preset = preset
            self.perApp = perApp
            self.allowlist = allowlist
            self.ceiling = ceiling
            self.expectEffect = expectEffect
            self.expectDisposition = expectDisposition
            self.expectAllowed = expectAllowed
        }
    }

    /// Expectation for `domain == "computer_use_loop"` cases. Carries BOTH
    /// the scripted world (`app` + `elements`) the `ScriptedCUDriver` serves
    /// and the success predicate scored against that world after the real
    /// `ComputerUseLoop` finishes. The model only ever sees the rendered
    /// `AgentView` (numbered marks, roles, labels, values) — never the
    /// element ids or this scene definition.
    public struct ComputerUseLoopExpectations: Sendable, Codable {

        /// One scripted element in the fake accessibility tree. `role` mirrors
        /// the compact roles the harness renders (`textfield`, `button`,
        /// `checkbox`, `switch`, `statictext`). Keep every `label` UNIQUE
        /// within a scene: the harness matches elements across snapshots by
        /// `(role|label)` for change detection and resolves `describe`
        /// targets by label substring, so duplicate labels blur both.
        public struct SceneElement: Sendable, Codable {
            /// Harness-internal stable id (never shown to the model). Used by
            /// the success predicate and the driver's action routing.
            public let id: String
            public let role: String
            public let label: String?
            public let value: String?
            public let placeholder: String?
            /// When true, `type` / `set_value` / `clear` mutate this element's
            /// value. Non-editable elements reject edits with feedback the
            /// model can read.
            public let editable: Bool?
            /// When true, the element is absent from captures until a click
            /// effect `reveal`s it — the lever for multi-step flows where a
            /// control only appears after an earlier action.
            public let hidden: Bool?
            /// What a click on this element does (buttons / toggles). Omitted
            /// for plain fields and static text.
            public let onClick: ClickEffect?
            /// Lowest capture tier at which this element is visible: `ax`
            /// (default), `som`, or `vision`. An element gated to `som`/`vision`
            /// is INVISIBLE in a plain AX capture — the Electron / custom-drawn
            /// shape that forces the loop's empty-AX → vision escalation. A scene
            /// whose actionable controls are all `som`-gated starts empty at AX.
            public let minTier: String?
            /// Element-addressed clicks on this element fail as a stale/removed
            /// ref this many times before succeeding (the signature Electron
            /// failure). A COORDINATE click (the loop's fallback) always lands,
            /// so this exercises the coordinate-fallback recovery end to end.
            public let clickFailures: Int?
            /// When a click `reveal`s this element, it stays hidden for this many
            /// further captures (async load) — so the model must `wait`/`observe`
            /// for it to appear rather than seeing it instantly.
            public let revealAfterCaptures: Int?
            /// The element is below the fold: absent until the loop performs a
            /// `scroll`, then it stays visible. Exercises scroll-to-find.
            public let revealOnScroll: Bool?

            public init(
                id: String,
                role: String,
                label: String? = nil,
                value: String? = nil,
                placeholder: String? = nil,
                editable: Bool? = nil,
                hidden: Bool? = nil,
                onClick: ClickEffect? = nil,
                minTier: String? = nil,
                clickFailures: Int? = nil,
                revealAfterCaptures: Int? = nil,
                revealOnScroll: Bool? = nil
            ) {
                self.id = id
                self.role = role
                self.label = label
                self.value = value
                self.placeholder = placeholder
                self.editable = editable
                self.hidden = hidden
                self.onClick = onClick
                self.minTier = minTier
                self.clickFailures = clickFailures
                self.revealAfterCaptures = revealAfterCaptures
                self.revealOnScroll = revealOnScroll
            }
        }

        /// The side effects a click produces in the scripted world. All
        /// optional and applied in order toggle → setValues → reveal.
        public struct ClickEffect: Sendable, Codable {
            /// Flip this element's value between `"off"` and `"on"` (the
            /// checkbox / switch primitive). Initial value should be `"off"`.
            public let toggle: Bool?
            /// Set OTHER elements' values (e.g. a Send button stamping a
            /// status element to `"sent"`).
            public let setValues: [SetValue]?
            /// Un-hide element ids (multi-step reveal).
            public let reveal: [String]?

            public init(
                toggle: Bool? = nil,
                setValues: [SetValue]? = nil,
                reveal: [String]? = nil
            ) {
                self.toggle = toggle
                self.setValues = setValues
                self.reveal = reveal
            }
        }

        public struct SetValue: Sendable, Codable {
            public let id: String
            public let value: String

            public init(id: String, value: String) {
                self.id = id
                self.value = value
            }
        }

        /// A check against one element's FINAL value in the scripted world.
        /// `equals` is exact (trimmed); `contains` is a case-insensitive
        /// substring. Provide at most one.
        public struct ValuePredicate: Sendable, Codable {
            public let id: String
            public let contains: String?
            public let equals: String?

            public init(id: String, contains: String? = nil, equals: String? = nil) {
                self.id = id
                self.contains = contains
                self.equals = equals
            }
        }

        /// App name the scene presents (focused on entry, so the model can
        /// act without `open`).
        public let app: String
        /// The scripted accessibility tree, in render order (mark = index+1).
        public let elements: [SceneElement]
        /// Productive-step budget. nil → 16. The loop also terminates on the
        /// invalid-action and dead-end ceilings regardless.
        public let maxSteps: Int?
        /// `AutonomyPreset` raw value for the gate. nil → `autonomous`, which
        /// auto-runs every effect so the case isolates the MODEL's planning
        /// from gate friction. Set `balanced` (etc.) to also exercise the
        /// confirm path (the harness auto-approves confirmations in evals).
        public let preset: String?
        /// `RunOutcome` short names that count as acceptable
        /// (`done`/`gaveUp`/`stepCapReached`/`deadEnd`/`interrupted`/`failed`).
        /// nil → `["done"]` (the model must self-declare success).
        public let expectOutcome: [String]?
        /// Final-state value predicates — the substantive "did it work" check.
        public let successValues: [ValuePredicate]?
        /// Element ids that must have been clicked at least once during the run.
        public let successClicked: [String]?
        /// Element ids that must NOT be clicked — the precision / safety lever
        /// (e.g. "Archive, do not Delete"). Any click on these fails the case.
        public let failIfClicked: [String]?
        /// Case-insensitive substrings the run's terminal summary (the model's
        /// `done`/`give_up` reason) must contain. The way to score a
        /// read-and-report scenario whose answer never lands in the tree —
        /// the model has to surface the value in its closing reason.
        public let finalSummaryContains: [String]?
        /// Ceiling on invalid `agent_action` re-asks (the JSON-discipline
        /// signal). nil → not scored, but always reported.
        public let maxInvalidActions: Int?
        /// Step-efficiency floor/ceiling, scored against the loop's productive
        /// step count. `scoredMaxSteps` catches a model that thrashes its way
        /// to the goal; `scoredMinSteps` catches a scene that's trivially
        /// solvable in fewer steps than intended (a scene-design smell). Both
        /// nil → efficiency is reported but not scored.
        public let scoredMinSteps: Int?
        public let scoredMaxSteps: Int?
        /// Verbs that must appear, IN THIS RELATIVE ORDER, in the executed verb
        /// trace (subsequence match, not contiguous). Encodes a required plan
        /// shape, e.g. `["scroll","click"]` (scroll into view, then click) or
        /// `["click","wait","set_value"]` (reveal, await async, then fill).
        public let expectVerbsInOrder: [String]?
        /// Ceiling on total model tokens (prompt + completion, summed across
        /// every model step) the run may spend. The cost lever for the
        /// live-model lane — a model that reaches the goal but burns the budget
        /// to get there fails. `0` for scripted runs (no model call), so this
        /// is effectively only scored on live cases. nil → reported, not scored.
        public let scoredMaxModelTokens: Int?
        /// When true, failure notes report lengths instead of raw final values
        /// and summaries. Use for fixtures with form contents or user-like data.
        public let redactEvidenceValues: Bool?
        /// Optional scripted model: a sequence of `agent_action` arguments-JSON
        /// strings that DRIVE the loop deterministically in place of a live
        /// model (via the `AgentStepProvider` seam). Lets failure-recovery and
        /// gate/verb scenarios run in CI with no model. When present, the model
        /// is never called; when nil, the case uses the live `modelId`.
        public let scriptedActions: [String]?

        public init(
            app: String,
            elements: [SceneElement],
            maxSteps: Int? = nil,
            preset: String? = nil,
            expectOutcome: [String]? = nil,
            successValues: [ValuePredicate]? = nil,
            successClicked: [String]? = nil,
            failIfClicked: [String]? = nil,
            finalSummaryContains: [String]? = nil,
            maxInvalidActions: Int? = nil,
            scoredMinSteps: Int? = nil,
            scoredMaxSteps: Int? = nil,
            expectVerbsInOrder: [String]? = nil,
            scoredMaxModelTokens: Int? = nil,
            redactEvidenceValues: Bool? = nil,
            scriptedActions: [String]? = nil
        ) {
            self.app = app
            self.elements = elements
            self.maxSteps = maxSteps
            self.preset = preset
            self.expectOutcome = expectOutcome
            self.successValues = successValues
            self.successClicked = successClicked
            self.failIfClicked = failIfClicked
            self.finalSummaryContains = finalSummaryContains
            self.maxInvalidActions = maxInvalidActions
            self.scoredMinSteps = scoredMinSteps
            self.scoredMaxSteps = scoredMaxSteps
            self.expectVerbsInOrder = expectVerbsInOrder
            self.scoredMaxModelTokens = scoredMaxModelTokens
            self.redactEvidenceValues = redactEvidenceValues
            self.scriptedActions = scriptedActions
        }
    }

    /// Expectation for `domain == "subagent"` cases. Selects one of the
    /// lanes via `lane` and scores the resulting `SubagentJobTranscript`:
    ///   - `scripted` — model-free. A `ScriptedSubagentKind` drives the real
    ///     `SubagentSession` host so the WHOLE lifecycle (resolve →
    ///     permission → handoff → run → normalize → cleanup), the unified
    ///     recursion guard, and the feed lifecycle run in CI with no tokens.
    ///   - `spawn` — live. Invokes the real `spawn_agent` path (host +
    ///     `TextSubagentKind`) against a user-configured spawnable agent.
    ///   - `spawn_model` — live. Invokes the real `spawn_model` path (host +
    ///     `TextSubagentKind`) against a bare spawnable model id, no agent.
    ///   - `image` — live. Invokes the real `ImageTool` (host +
    ///     `ImageSubagentKind`); `sourcePaths` non-empty selects edit mode.
    /// Live lanes SKIP (not fail) when the host can't satisfy them (no
    /// spawnable agent/model / image delegation off / model not ready),
    /// mirroring `requirePlugins`. Every present matcher must pass.
    public struct SubagentExpectations: Sendable, Codable {
        /// `"scripted"` | `"spawn"` | `"spawn_model"` | `"image"`. Selects the lane.
        public let lane: String

        // --- scripted lane inputs ---
        /// Opt the scripted kind into the residency-handoff middleware.
        public let needsHandoff: Bool?
        /// Permission verdict: `"allow"` | `"deny"` | `"userDeny"`.
        public let decision: String?
        /// Typed failure thrown at resolve time (reject-before-evict). One of
        /// the `SubagentError` cases: `denied` / `userDenied` / `unavailable` /
        /// `invalidArgs` / `timedOut` / `iterationCap` / `toolRejected` /
        /// `overBudget` / `emptyExhausted` / `executionFailed`.
        public let resolveFailure: String?
        /// Typed failure thrown inside `run` (same value set as above).
        public let runFailure: String?
        /// When true, the scripted run attempts a nested subagent so the
        /// unified recursion guard refuses it (paired with `expectNestedRefused`).
        public let recurse: Bool?
        /// Lifecycle phases the scripted kind emits onto the feed.
        public let phases: [String]?
        /// Scripted lane: run this many copies CONCURRENTLY through the host
        /// (one parallel tool batch). ≥2 selects the parallel-batch path; the
        /// transcript then reports `maxConcurrent` + `runsCompleted`. Pair
        /// with `needsHandoff` (local-exclusive → must serialize) or `remote`
        /// (fan-out → must overlap).
        public let parallel: Int?
        /// Scripted lane: resolve as a REMOTE model (`isLocal: false`) so the
        /// admission class is `.remote` — the parallel fan-out input.
        public let remote: Bool?
        /// Scripted lane: hold `run()` open this long (polling the interrupt
        /// token every ~20 ms) so interrupts / sibling overlap can land.
        public let runDelayMs: Int?
        /// Scripted parallel lane: rendezvous — each run waits (bounded) until
        /// ALL siblings have entered, so fan-out overlap is observed by
        /// construction. Only set for concurrent-capable classes (`remote`);
        /// a serialized batch would just burn the bounded wait.
        public let rendezvous: Bool?
        /// Scripted lane: attach canned `usage` + `context` accounting to the
        /// success payload — deterministic CI coverage for the usage /
        /// context-saved scoring plumbing the live spawn lanes ride.
        public let includeUsageAccounting: Bool?
        /// Scripted + live spawn lanes: trip the run's stop button (the real
        /// `SubagentInterruptCenter` path) after this many milliseconds — the
        /// interrupt-mid-generation lane. Expect `user_denied` + "stopped".
        public let interruptAfterMs: Int?

        // --- live spawn lane inputs ---
        /// Spawnable agent name for the `spawn` lane.
        public let agent: String?
        /// Task/query handed to the spawned agent.
        public let input: String?
        /// When true, the runner seeds a spawnable agent named `agent` (an
        /// Agent + the Default agent's global spawnable pool) for the duration
        /// of the run and restores it after, so the case RUNS across models on
        /// any host instead of skipping. Leave false/nil for negative guards
        /// (e.g. "not spawnable → rejected") that must NOT be seeded.
        public let seedSpawnableAgent: Bool?

        // --- live spawn_model lane inputs ---
        /// When true, the runner seeds the target model (explicit `model` else
        /// the run model) into the Default agent's global spawnable MODEL pool
        /// for the duration of the run and restores it after, so the
        /// `spawn_model` case RUNS across models on any host instead of skipping.
        /// Leave false/nil for negative guards (e.g. "model not spawnable →
        /// rejected") that must NOT be seeded. `input` is the task; `model` (when
        /// set) pins the target id, otherwise the run model is used.
        public let seedSpawnableModel: Bool?
        /// Tool-capable spawn lane: grant the child this tool reach for the
        /// run (`"readOnly"` → curated read-only toolset; nil/`"none"` →
        /// text-only). Applied with the seeding snapshot/restore, so a
        /// developer's real config is untouched.
        public let seedSpawnToolAccess: String?

        // --- live spawn_model_residency lane inputs ---
        /// The chat/core ORCHESTRATOR model the residency decision is made
        /// against. A LOCAL id (installed) models a resident local orchestrator;
        /// a remote id models a cloud orchestrator (nothing local to evict).
        /// Paired with `model` (the spawn target) to exercise one of the four
        /// directions end-to-end (the only lane that proves the real swap).
        public let orchestrator: String?
        /// Toggle the "Local Orchestrator Handoff" switch for the run. `false`
        /// + a DIFFERENT local target ⇒ reject-before-evict (the gate); `true`
        /// ⇒ the unload/reload swap is allowed. nil → true.
        public let handoffEnabled: Bool?
        /// Preload the LOCAL orchestrator so it is actually GPU-resident before
        /// the spawn (so a different local target triggers the real swap). Set
        /// `false` for a remote orchestrator (nothing local to make resident).
        /// nil → false.
        public let ensureResident: Bool?
        /// Residency matrix lane: repeat the FULL production run this many
        /// times back-to-back (rapid unload/reload cycles — the crash-safety
        /// stressor). Every cycle must satisfy the per-cycle checks. nil → 1.
        public let cycles: Int?
        /// Residency matrix lane: a distinctive token appended to the input
        /// with an instruction to echo it verbatim. EVERY cycle's digest must
        /// contain it — the sentinel context-recall proof across the handoff.
        public let sentinel: String?

        // --- residency matrix expectations ---
        /// Assert no NEW osaurus-related crash reports (`.ips`/`.crash` under
        /// ~/Library/Logs/DiagnosticReports) appeared during the case — the
        /// before/after crash-count gate from the manual proof campaigns.
        public let expectNoNewCrashReports: Bool?
        /// Assert the local orchestrator is verified GPU-resident again after
        /// EVERY cycle (restore actually happened / in-place never dropped it).
        /// Only meaningful with `ensureResident: true`.
        public let expectRestoredResident: Bool?
        /// Assert no raw parser/template/tool markers (`<think>`, `<|`,
        /// `<tool_call>`, `<start_of_turn>`, …) leak into any cycle's digest.
        public let expectNoMarkerLeaks: Bool?

        // --- live image lane inputs ---
        /// Prompt for the `image` lane (also the edit instruction).
        public let prompt: String?
        /// One to four local source image paths — non-empty selects edit mode.
        public let sourcePaths: [String]?
        /// Optional local image model id override.
        public let model: String?

        // --- live computer_use lane inputs (reuse the CU scene schema) ---
        /// App name the scripted scene presents (focused on entry).
        public let app: String?
        /// The scripted accessibility tree the in-memory driver renders.
        public let elements: [ComputerUseLoopExpectations.SceneElement]?
        /// `AutonomyPreset` raw value for the gate. nil → `autonomous`.
        public let preset: String?
        /// Productive-step budget for the loop. nil → 16.
        public let maxSteps: Int?
        /// Optional scripted model: `agent_action` arguments-JSON strings that
        /// drive the loop deterministically (no model call). When present, the
        /// case runs for EVERY model (CI-safe); when nil/empty, the live
        /// `modelId` drives it (and tiny-context models SKIP). The run outcome
        /// is scored via `expectSuccess`/`expectEnvelopeKind` (the host
        /// collapses `done`→success, `interrupted`→user_denied, every other
        /// non-completion→execution_error).
        public let scriptedActions: [String]?
        /// Final-state value predicates against the scripted world — the
        /// substantive "did it work" check (read back from the driver).
        public let successValues: [ComputerUseLoopExpectations.ValuePredicate]?
        /// Element ids that must have been clicked at least once.
        public let successClicked: [String]?
        /// Element ids that must NOT be clicked — the precision/safety lever.
        public let failIfClicked: [String]?
        /// Verbs that must appear IN THIS RELATIVE ORDER in the executed trace
        /// (subsequence). Encodes a required plan shape.
        public let expectVerbsInOrder: [String]?

        // --- expectations (any subset; an empty set just records) ---
        /// Whether the run must end in a success envelope.
        public let expectSuccess: Bool?
        /// Expected envelope kind: `"success"` or a failure discriminator
        /// (`rejected` / `user_denied` / `unavailable` / `invalid_args` /
        /// `timeout` / `execution_error`).
        public let expectEnvelopeKind: String?
        /// Expected result payload discriminator (`spawn_result` /
        /// `native_image_generation_job` / the scripted kind's `resultKind`).
        public let expectResultKind: String?
        /// Case-insensitive substrings the terminal summary must contain.
        public let summaryContains: [String]?
        /// Feed event kinds that must all appear (e.g. `["phase"]`).
        public let expectFeedKinds: [String]?
        /// Feed phase titles that must appear IN ORDER (subsequence) — the
        /// live-progress proof.
        public let expectPhasesInOrder: [String]?
        /// Scripted lane: assert the residency handoff wrapped the run.
        public let expectHandoffWrapped: Bool?
        /// Scripted lane: assert the nested subagent attempt was refused.
        public let expectNestedRefused: Bool?
        /// Image lane: expected mode (`"generate"` | `"edit"`).
        public let expectImageMode: String?
        /// Image lane: minimum number of images on success.
        public let minImages: Int?
        /// Parallel-batch lane: exact peak overlap of run bodies. `1` pins
        /// serialization (two local handoffs never overlap — the batch-race
        /// guard); `2` pins remote fan-out (both actually ran concurrently).
        public let expectMaxConcurrent: Int?
        /// Parallel-batch lane: exact number of runs that must succeed (the
        /// queued run completes rather than being refused or deadlocking).
        public let expectRunsCompleted: Int?
        /// Assert worker usage was recorded: `prompt_tokens` +
        /// `completion_tokens` present and > 0 (per the proof rule that a
        /// generation row without token accounting is not a pass).
        public let expectUsageRecorded: Bool?
        /// Assert context-saved accounting is present (`worker_tokens` > 0,
        /// `digest_tokens` > 0, `context_saved_tokens` recorded) — the
        /// measurable "delegation saved the parent context" row.
        public let expectContextAccounting: Bool?
        /// Minimum `context_saved_tokens` the delegation must have saved.
        public let minContextSavedTokens: Int?
        /// Residency phase names that must appear in the recorded phase
        /// timings (e.g. `unloading_chat_models`, `restoring_chat_models`) —
        /// the handoff-latency telemetry proof.
        public let expectResidencyPhases: [String]?
        /// Per-phase duration ceilings (seconds) on the recorded residency
        /// phase timings — MicroPerf-style latency assertions. A phase listed
        /// here must be present AND under its ceiling.
        public let maxPhaseSeconds: [String: Double]?
        /// Assert the post-run cache counters were captured for a local run
        /// (`prefix_hits` / `disk_l2_*`) — the resume prefix-hit signal.
        public let expectPostRunCache: Bool?

        public init(
            lane: String,
            needsHandoff: Bool? = nil,
            decision: String? = nil,
            resolveFailure: String? = nil,
            runFailure: String? = nil,
            recurse: Bool? = nil,
            phases: [String]? = nil,
            parallel: Int? = nil,
            remote: Bool? = nil,
            runDelayMs: Int? = nil,
            rendezvous: Bool? = nil,
            includeUsageAccounting: Bool? = nil,
            interruptAfterMs: Int? = nil,
            agent: String? = nil,
            input: String? = nil,
            seedSpawnableAgent: Bool? = nil,
            seedSpawnableModel: Bool? = nil,
            seedSpawnToolAccess: String? = nil,
            orchestrator: String? = nil,
            handoffEnabled: Bool? = nil,
            ensureResident: Bool? = nil,
            cycles: Int? = nil,
            sentinel: String? = nil,
            expectNoNewCrashReports: Bool? = nil,
            expectRestoredResident: Bool? = nil,
            expectNoMarkerLeaks: Bool? = nil,
            prompt: String? = nil,
            sourcePaths: [String]? = nil,
            model: String? = nil,
            app: String? = nil,
            elements: [ComputerUseLoopExpectations.SceneElement]? = nil,
            preset: String? = nil,
            maxSteps: Int? = nil,
            scriptedActions: [String]? = nil,
            successValues: [ComputerUseLoopExpectations.ValuePredicate]? = nil,
            successClicked: [String]? = nil,
            failIfClicked: [String]? = nil,
            expectVerbsInOrder: [String]? = nil,
            expectSuccess: Bool? = nil,
            expectEnvelopeKind: String? = nil,
            expectResultKind: String? = nil,
            summaryContains: [String]? = nil,
            expectFeedKinds: [String]? = nil,
            expectPhasesInOrder: [String]? = nil,
            expectHandoffWrapped: Bool? = nil,
            expectNestedRefused: Bool? = nil,
            expectImageMode: String? = nil,
            minImages: Int? = nil,
            expectMaxConcurrent: Int? = nil,
            expectRunsCompleted: Int? = nil,
            expectUsageRecorded: Bool? = nil,
            expectContextAccounting: Bool? = nil,
            minContextSavedTokens: Int? = nil,
            expectResidencyPhases: [String]? = nil,
            maxPhaseSeconds: [String: Double]? = nil,
            expectPostRunCache: Bool? = nil
        ) {
            self.lane = lane
            self.needsHandoff = needsHandoff
            self.decision = decision
            self.resolveFailure = resolveFailure
            self.runFailure = runFailure
            self.recurse = recurse
            self.phases = phases
            self.parallel = parallel
            self.remote = remote
            self.runDelayMs = runDelayMs
            self.rendezvous = rendezvous
            self.includeUsageAccounting = includeUsageAccounting
            self.interruptAfterMs = interruptAfterMs
            self.agent = agent
            self.input = input
            self.seedSpawnableAgent = seedSpawnableAgent
            self.seedSpawnableModel = seedSpawnableModel
            self.seedSpawnToolAccess = seedSpawnToolAccess
            self.orchestrator = orchestrator
            self.handoffEnabled = handoffEnabled
            self.ensureResident = ensureResident
            self.cycles = cycles
            self.sentinel = sentinel
            self.expectNoNewCrashReports = expectNoNewCrashReports
            self.expectRestoredResident = expectRestoredResident
            self.expectNoMarkerLeaks = expectNoMarkerLeaks
            self.prompt = prompt
            self.sourcePaths = sourcePaths
            self.model = model
            self.app = app
            self.elements = elements
            self.preset = preset
            self.maxSteps = maxSteps
            self.scriptedActions = scriptedActions
            self.successValues = successValues
            self.successClicked = successClicked
            self.failIfClicked = failIfClicked
            self.expectVerbsInOrder = expectVerbsInOrder
            self.expectSuccess = expectSuccess
            self.expectEnvelopeKind = expectEnvelopeKind
            self.expectResultKind = expectResultKind
            self.summaryContains = summaryContains
            self.expectFeedKinds = expectFeedKinds
            self.expectPhasesInOrder = expectPhasesInOrder
            self.expectHandoffWrapped = expectHandoffWrapped
            self.expectNestedRefused = expectNestedRefused
            self.expectImageMode = expectImageMode
            self.minImages = minImages
            self.expectMaxConcurrent = expectMaxConcurrent
            self.expectRunsCompleted = expectRunsCompleted
            self.expectUsageRecorded = expectUsageRecorded
            self.expectContextAccounting = expectContextAccounting
            self.minContextSavedTokens = minContextSavedTokens
            self.expectResidencyPhases = expectResidencyPhases
            self.maxPhaseSeconds = maxPhaseSeconds
            self.expectPostRunCache = expectPostRunCache
        }
    }

    /// Expectation for `domain == "apple_script"` cases. Selects a lane via
    /// `lane` and scores the resulting `AppleScriptEvalTranscript`:
    ///   - `scripted`  — model-free. A canned sequence of `run_applescript`
    ///     arguments drives the REAL `AppleScriptLoop` (gate / literal
    ///     expansion / effect classification / verification) against a mock
    ///     executor, so the whole mechanic runs in CI with no tokens.
    ///   - `live`      — the real on-device AppleScript model proposes scripts;
    ///     a mock executor (canned results or a keyed "app world") answers, so
    ///     there are NO OS side effects. The capability / edge lane.
    ///   - `liveProof` — the real model + the REAL `AppleScriptExecutor` against
    ///     actual app state (permission-gated, run locally) — verbatim ground
    ///     truth.
    /// The `live` / `liveProof` lanes SKIP (not fail) when no AppleScript model
    /// is installed. Every present matcher must pass; an empty matcher set just
    /// records the transcript.
    public struct AppleScriptExpectations: Sendable, Codable {

        // MARK: - Lane + run inputs

        /// `"scripted"` (default) | `"live"` | `"liveProof"`.
        public let lane: String?
        /// `"automate"` (default) | `"query"` — the loop's run mode.
        public let mode: String?
        /// `AppleScriptExecutionMode` raw value: `"confirmEach"` |
        /// `"autoRunWithWarning"` (the eval default). `confirmEach` also
        /// exercises the confirm gate, auto-answered by `confirmApproves`.
        public let executionMode: String?
        /// A single verbatim literal, inserted via the `{{content}}` placeholder.
        public let content: String?
        /// Several named verbatim literals `{ name: text }`, each inserted via
        /// its own `{{name}}` placeholder (the multi-literal contract). Wins over
        /// `content` on a shared `content` key.
        public let contents: [String: String]?
        /// The confirm-each answer for `automate` runs. nil → approve.
        public let confirmApproves: Bool?
        /// Productive-step budget for the loop. nil → 12.
        public let maxSteps: Int?
        /// Wall-clock budget for the whole run, seconds. nil → 240. Long
        /// multi-step cases (slow models, 6+ sequential scripts) need more.
        public let wallClockSeconds: Double?
        /// Per-model-step inference budget, seconds. nil → the loop default
        /// (90). A slow model's step gets cancelled + retried at this bound,
        /// so multi-step cases against slow models must raise it.
        public let modelStepTimeoutSeconds: Double?
        /// EXPLICIT sampling-temperature override (e.g. `0` for a greedy
        /// isolation A/B). nil → the model bundle's own generation defaults.
        /// This is a case-declared override recorded with the run — never a
        /// hidden synthetic default.
        public let samplingTemperature: Double?
        /// Scripted lane only: `run_applescript` arguments-JSON strings, one per
        /// step, that drive the loop with no model call. Ignored on live lanes.
        public let scriptedCalls: [String]?
        /// Optional desktop-context string injected into the run (e.g. a
        /// frontmost / running-apps snapshot), so a case can prove the model
        /// uses the injected context. Honored only when the harness
        /// `includeDesktopContext` is on (the shipped default). nil → none.
        public let environmentContext: String?

        // MARK: - Executor

        /// How the loop's `execute:` seam is satisfied. nil → a mock that
        /// returns success for every script (pure mechanics). `liveProof` always
        /// forces the real executor regardless of this.
        public let executor: ExecutorSpec?

        // MARK: - Harness levers (the sweep variables)

        public let harness: HarnessSpec?

        // MARK: - Assertions (any subset; an empty set just records)

        /// Aggregate task status that must be reached: `"succeeded"` |
        /// `"partial"` | `"failed"`.
        public let expectStatus: String?
        /// Acceptable loop outcomes: `"done"` | `"stepCapReached"` |
        /// `"interrupted"` | `"failed"`. nil → not scored.
        public let expectOutcome: [String]?
        /// Literal names that MUST appear as `{{name}}` in at least one script
        /// the model emitted (proven from the pre-expansion proposal) — the
        /// "insert verbatim, don't re-type" check.
        public let mustUsePlaceholders: [String]?
        /// Case-sensitive substrings at least one EXECUTED (expanded) script must
        /// contain.
        public let scriptMustContain: [String]?
        /// Substrings NO executed script may contain (e.g. a destructive verb).
        public let scriptMustNotContain: [String]?
        /// Regexes at least one executed script must match.
        public let scriptMustMatch: [String]?
        /// Case-insensitive substrings the captured value (`lastOutput`) must
        /// contain — the `mac_query` / read-back result check.
        public let valuesContain: [String]?
        /// Assert a write was blocked and never executed (query-mode safety).
        public let expectBlockedWrite: Bool?
        /// Effect classes that must appear across the model's proposals:
        /// `"read"` | `"edit"` | `"consequential"`.
        public let expectEffects: [String]?
        /// Effect classes that must NOT appear (e.g. `"consequential"` when no
        /// destructive verb was requested).
        public let forbidEffects: [String]?
        /// Final-state predicates against the mock world. Keys: `"note:<name>"`,
        /// `"volume"`. Empty on the real / canned executors (records only).
        public let finalState: [StatePredicate]?
        /// Efficiency ceiling: scripts executed must be ≤ this. nil → reported
        /// only.
        public let scoredMaxSteps: Int?
        /// Cost ceiling: total model tokens must be ≤ this. nil → reported only.
        public let scoredMaxModelTokens: Int?
        /// LLM-judge rubric — Grok grades whether the generated script correctly
        /// accomplishes the task (robust to script variety, unlike string
        /// matching). Only run on `live` / `liveProof`; skipped (recorded) when
        /// the resolved judge would be the run model itself.
        public let rubric: [String]?

        /// How the loop's `execute:` seam is backed for a case.
        public struct ExecutorSpec: Sendable, Codable {
            /// `"mock"` (default) | `"real"`.
            public let kind: String?
            /// Mock: canned per-step results (repeats the last once exhausted).
            /// Empty / nil → success for every script.
            public let mockResults: [ResultSpec]?
            /// Mock: seed a keyed "app world" (note bodies, volume) that records
            /// writes and answers reads, for `finalState` assertions. Takes
            /// precedence over `mockResults` when present.
            public let mockWorld: WorldSeed?
            /// Real executor only: a tiny READ-ONLY probe script against the
            /// same app the task automates, run with a short bound before the
            /// model loop. If it can't answer (pending/denied Automation
            /// consent on an unattended host) the case SKIPs honestly instead
            /// of parking the suite on the consent dialog until the per-case
            /// watchdog kills the whole process (observed live: 600s trip +
            /// 14 downstream cases lost, for every model).
            public let probe: String?

            public init(
                kind: String? = nil,
                mockResults: [ResultSpec]? = nil,
                mockWorld: WorldSeed? = nil,
                probe: String? = nil
            ) {
                self.kind = kind
                self.mockResults = mockResults
                self.mockWorld = mockWorld
                self.probe = probe
            }

            /// One canned execution result the mock hands back.
            public struct ResultSpec: Sendable, Codable {
                /// `AppleScriptExecutionResult.Status` raw value: `"success"` |
                /// `"compileError"` | `"runtimeError"` | `"permissionRequired"` |
                /// `"timedOut"` (snake_case aliases accepted). nil → success.
                public let status: String?
                public let output: String?
                public let errorNumber: Int?
                public let errorMessage: String?

                public init(
                    status: String? = nil,
                    output: String? = nil,
                    errorNumber: Int? = nil,
                    errorMessage: String? = nil
                ) {
                    self.status = status
                    self.output = output
                    self.errorNumber = errorNumber
                    self.errorMessage = errorMessage
                }
            }

            /// Seed state for the mock "app world".
            public struct WorldSeed: Sendable, Codable {
                /// Note name → seeded body.
                public let notes: [String: String]?
                /// Seeded system output volume (0–100).
                public let volume: Int?
                /// Seeded front Safari document URL.
                public let safariURL: String?
                /// Seeded Mail inbox unread count.
                public let mailUnread: Int?
                /// Seeded frontmost application process name (System Events).
                public let frontmostApp: String?
                /// Seeded Finder folder names (each reads as existing).
                public let folders: [String]?

                public init(
                    notes: [String: String]? = nil,
                    volume: Int? = nil,
                    safariURL: String? = nil,
                    mailUnread: Int? = nil,
                    frontmostApp: String? = nil,
                    folders: [String]? = nil
                ) {
                    self.notes = notes
                    self.volume = volume
                    self.safariURL = safariURL
                    self.mailUnread = mailUnread
                    self.frontmostApp = frontmostApp
                    self.folders = folders
                }
            }
        }

        /// `AppleScriptHarnessOptions` toggles surfaced to the suite so a case /
        /// sweep can A/B the harness against the fixed model. nil fields keep
        /// today's shipped production behavior.
        public struct HarnessSpec: Sendable, Codable {
            public let verifyReadBack: Bool?
            public let includeDesktopContext: Bool?
            /// Inject the target app's distilled scripting dictionary (sdef).
            public let includeDictionaryContext: Bool?
            /// Inject the curated per-app AppleScript idiom tips.
            public let includeAppRecipes: Bool?
            /// `"standard"` | `"concise"`.
            public let promptVariant: String?
            /// `"namePreview"` | `"nameOnly"` | `"minimal"`.
            public let literalAnnouncementStyle: String?

            public init(
                verifyReadBack: Bool? = nil,
                includeDesktopContext: Bool? = nil,
                includeDictionaryContext: Bool? = nil,
                includeAppRecipes: Bool? = nil,
                promptVariant: String? = nil,
                literalAnnouncementStyle: String? = nil
            ) {
                self.verifyReadBack = verifyReadBack
                self.includeDesktopContext = includeDesktopContext
                self.includeDictionaryContext = includeDictionaryContext
                self.includeAppRecipes = includeAppRecipes
                self.promptVariant = promptVariant
                self.literalAnnouncementStyle = literalAnnouncementStyle
            }
        }

        /// A final-state assertion against one mock-world key.
        public struct StatePredicate: Sendable, Codable {
            /// `"note:<name>"` or `"volume"`.
            public let key: String
            public let equals: String?
            public let contains: String?

            public init(key: String, equals: String? = nil, contains: String? = nil) {
                self.key = key
                self.equals = equals
                self.contains = contains
            }
        }

        public init(
            lane: String? = nil,
            mode: String? = nil,
            executionMode: String? = nil,
            content: String? = nil,
            contents: [String: String]? = nil,
            confirmApproves: Bool? = nil,
            maxSteps: Int? = nil,
            wallClockSeconds: Double? = nil,
            modelStepTimeoutSeconds: Double? = nil,
            samplingTemperature: Double? = nil,
            scriptedCalls: [String]? = nil,
            environmentContext: String? = nil,
            executor: ExecutorSpec? = nil,
            harness: HarnessSpec? = nil,
            expectStatus: String? = nil,
            expectOutcome: [String]? = nil,
            mustUsePlaceholders: [String]? = nil,
            scriptMustContain: [String]? = nil,
            scriptMustNotContain: [String]? = nil,
            scriptMustMatch: [String]? = nil,
            valuesContain: [String]? = nil,
            expectBlockedWrite: Bool? = nil,
            expectEffects: [String]? = nil,
            forbidEffects: [String]? = nil,
            finalState: [StatePredicate]? = nil,
            scoredMaxSteps: Int? = nil,
            scoredMaxModelTokens: Int? = nil,
            rubric: [String]? = nil
        ) {
            self.lane = lane
            self.mode = mode
            self.executionMode = executionMode
            self.content = content
            self.contents = contents
            self.confirmApproves = confirmApproves
            self.maxSteps = maxSteps
            self.wallClockSeconds = wallClockSeconds
            self.modelStepTimeoutSeconds = modelStepTimeoutSeconds
            self.samplingTemperature = samplingTemperature
            self.scriptedCalls = scriptedCalls
            self.environmentContext = environmentContext
            self.executor = executor
            self.harness = harness
            self.expectStatus = expectStatus
            self.expectOutcome = expectOutcome
            self.mustUsePlaceholders = mustUsePlaceholders
            self.scriptMustContain = scriptMustContain
            self.scriptMustNotContain = scriptMustNotContain
            self.scriptMustMatch = scriptMustMatch
            self.valuesContain = valuesContain
            self.expectBlockedWrite = expectBlockedWrite
            self.expectEffects = expectEffects
            self.forbidEffects = forbidEffects
            self.finalState = finalState
            self.scoredMaxSteps = scoredMaxSteps
            self.scoredMaxModelTokens = scoredMaxModelTokens
            self.rubric = rubric
        }
    }

}
