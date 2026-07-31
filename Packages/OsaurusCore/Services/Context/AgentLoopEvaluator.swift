//
//  AgentLoopEvaluator.swift
//  osaurus
//
//  Public facade that drives the canonical `AgentToolLoop` for the
//  OsaurusEvals `agent_loop` domain. Unlike `CapabilityClaimsEvaluator`
//  (which probes capability *claims* with `executionMode: .none`), this
//  evaluator seeds a real host-folder workspace, composes with
//  `executionMode: .hostFolder(...)`, and drives the SAME loop driver the
//  chat/HTTP/plugin surfaces use — `AgentTaskState` dedupe, next-step
//  bias, iteration budget notices, and budget-managed compaction included
//  — so eval cases exercise the production harness end to end.
//

import Foundation

// MARK: - Public transcript

/// Decode-friendly record of one agent-loop eval run.
public struct AgentLoopTranscript: Sendable, Codable {
    /// Structured observation extracted from a successful `spawn_batch`
    /// result. Keeping this alongside the bounded result preview lets evals
    /// score every child row without retaining arbitrarily large tool output.
    public struct SpawnBatchObservation: Sendable, Codable, Equatable {
        public struct ChildRow: Sendable, Codable, Equatable {
            public let id: String?
            public let targetType: String?
            public let target: String?
            public let ok: Bool?
            public let model: String?
            public let summary: String?

            public init(
                id: String?,
                targetType: String?,
                target: String?,
                ok: Bool?,
                model: String?,
                summary: String?
            ) {
                self.id = id
                self.targetType = targetType
                self.target = target
                self.ok = ok
                self.model = model
                self.summary = summary
            }
        }

        public struct ExecutionWave: Sendable, Codable, Equatable {
            public let wave: Int?
            public let remoteJobs: Int?
            public let effectiveLocalSlots: Int?
            public let localSubwaves: [Int]?
            public let limitingFactors: [String]?

            public init(
                wave: Int?,
                remoteJobs: Int?,
                effectiveLocalSlots: Int?,
                localSubwaves: [Int]?,
                limitingFactors: [String]?
            ) {
                self.wave = wave
                self.remoteJobs = remoteJobs
                self.effectiveLocalSlots = effectiveLocalSlots
                self.localSubwaves = localSubwaves
                self.limitingFactors = limitingFactors
            }

            public var isWellFormed: Bool {
                wave != nil
                    && remoteJobs != nil
                    && effectiveLocalSlots != nil
                    && localSubwaves != nil
                    && limitingFactors != nil
            }
        }

        public let resultKind: String
        public let maxParallel: Int?
        public let reportedSucceeded: Int?
        public let reportedFailed: Int?
        public let observedSucceeded: Int
        public let observedFailed: Int
        public let orderedJobIds: [String]
        /// Ordered, structured child truth retained from the production
        /// aggregate. Unlike the parent final text, these fields prove which
        /// target actually ran, which model resolved, and what that child
        /// returned.
        public let childRows: [ChildRow]
        public let aggregateStatus: String?
        /// nil means the result predates execution diagnostics or omitted
        /// them. An empty array means an execution object was present but
        /// reported no parseable waves.
        public let executionWaves: [ExecutionWave]?
        public let everyExecutionWaveWellFormed: Bool?
        public let cacheAvailable: Bool?
        /// True only when every result row has a non-empty id, an `ok` value,
        /// and a nested tool envelope whose `ok` agrees with the row.
        public let everyRowSettled: Bool

        public init(
            resultKind: String,
            maxParallel: Int?,
            reportedSucceeded: Int?,
            reportedFailed: Int?,
            observedSucceeded: Int,
            observedFailed: Int,
            orderedJobIds: [String],
            childRows: [ChildRow] = [],
            everyRowSettled: Bool,
            aggregateStatus: String? = nil,
            executionWaves: [ExecutionWave]? = nil,
            everyExecutionWaveWellFormed: Bool? = nil,
            cacheAvailable: Bool? = nil
        ) {
            self.resultKind = resultKind
            self.maxParallel = maxParallel
            self.reportedSucceeded = reportedSucceeded
            self.reportedFailed = reportedFailed
            self.observedSucceeded = observedSucceeded
            self.observedFailed = observedFailed
            self.orderedJobIds = orderedJobIds
            self.childRows = childRows
            self.everyRowSettled = everyRowSettled
            self.aggregateStatus = aggregateStatus
            self.executionWaves = executionWaves
            self.everyExecutionWaveWellFormed = everyExecutionWaveWellFormed
            self.cacheAvailable = cacheAvailable
        }
    }

    /// One processed tool call, in model order across all iterations.
    public struct ToolInvocation: Sendable, Codable {
        public let name: String
        public let arguments: String
        /// First 300 chars of the result envelope — forensics, not scoring.
        public let resultPreview: String
        /// True when the loop's dedupe replayed a held result instead of
        /// re-executing (the duplicate-call-avoidance signal).
        public let wasDeduped: Bool
        /// True when the result was an error envelope — drives the opt-in
        /// `noToolErrors` scoring assertion without parsing previews.
        public let wasError: Bool
        /// Parsed only for successful `spawn_batch` results.
        public let spawnBatch: SpawnBatchObservation?

        public init(
            name: String,
            arguments: String,
            resultPreview: String,
            wasDeduped: Bool,
            wasError: Bool = false,
            spawnBatch: SpawnBatchObservation? = nil
        ) {
            self.name = name
            self.arguments = arguments
            self.resultPreview = resultPreview
            self.wasDeduped = wasDeduped
            self.wasError = wasError
            self.spawnBatch = spawnBatch
        }
    }

    /// Bounded, per-model-step forensic state. This intentionally records
    /// channel sizes and short previews rather than an unbounded raw stream,
    /// while retaining enough evidence to distinguish visible inline output,
    /// reasoning exhaustion, and an unfinished tool envelope.
    public struct StepDiagnostic: Sendable, Codable, Equatable {
        public let step: Int
        public let stopReason: String?
        public let contentCharacterCount: Int
        public let reasoningCharacterCount: Int
        public let contentPreview: String?
        public let reasoningPreview: String?
        public let sawToolCallProgress: Bool
        public let pendingToolName: String?
        public let toolArgumentCharacters: Int
        /// Runtime-reported generated tokens for this step when available.
        public let completionTokens: Int?
        /// Explicit request value. nil means dispatch policy/bundle defaults
        /// resolved the effective rail downstream.
        public let requestedEnableThinking: Bool?
        /// Honest request-resolution state without inventing a downstream
        /// bundle default when the evaluator did not explicitly override it.
        public let thinkingState: String?

        public init(
            step: Int,
            stopReason: String?,
            contentCharacterCount: Int,
            reasoningCharacterCount: Int,
            contentPreview: String?,
            reasoningPreview: String?,
            sawToolCallProgress: Bool,
            pendingToolName: String?,
            toolArgumentCharacters: Int,
            completionTokens: Int? = nil,
            requestedEnableThinking: Bool?
        ) {
            self.step = step
            self.stopReason = stopReason
            self.contentCharacterCount = contentCharacterCount
            self.reasoningCharacterCount = reasoningCharacterCount
            self.contentPreview = contentPreview
            self.reasoningPreview = reasoningPreview
            self.sawToolCallProgress = sawToolCallProgress
            self.pendingToolName = pendingToolName
            self.toolArgumentCharacters = toolArgumentCharacters
            self.completionTokens = completionTokens
            self.requestedEnableThinking = requestedEnableThinking
            self.thinkingState = requestedEnableThinking.map {
                $0 ? "explicitEnabled" : "explicitDisabled"
            } ?? "runtimeDefault"
        }
    }

    /// Parse the stable aggregate fields and ordered child rows from a
    /// production `spawn_batch` envelope. Failed all-child aggregates retain
    /// their structured result payload so evals can inspect settled rows and
    /// terminal status instead of losing them behind the outer failure.
    public static func spawnBatchObservation(
        from result: String
    ) -> SpawnBatchObservation? {
        guard
            let payload = ToolEnvelope.resultPayload(result) as? [String: Any],
            payload["kind"] as? String == "spawn_batch_result",
            let rows = payload["results"] as? [[String: Any]]
        else { return nil }

        var ids: [String] = []
        var observedSucceeded = 0
        var observedFailed = 0
        var everyRowSettled = true
        var childRows: [SpawnBatchObservation.ChildRow] = []
        for row in rows {
            let nested = row["envelope"] as? [String: Any]
            let nestedResult = nested?["result"] as? [String: Any]
            childRows.append(
                .init(
                    id: row["id"] as? String,
                    targetType: row["target_type"] as? String,
                    target: row["target"] as? String,
                    ok: row["ok"] as? Bool,
                    model: nestedResult?["model"] as? String,
                    summary: nestedResult?["summary"] as? String
                )
            )
            guard let id = row["id"] as? String, !id.isEmpty,
                let ok = row["ok"] as? Bool,
                let nested,
                let nestedOK = nested["ok"] as? Bool,
                nestedOK == ok
            else {
                everyRowSettled = false
                continue
            }
            ids.append(id)
            if ok {
                observedSucceeded += 1
            } else {
                observedFailed += 1
            }
        }
        if ids.count != rows.count {
            everyRowSettled = false
        }

        var executionWaves: [SpawnBatchObservation.ExecutionWave]?
        var everyExecutionWaveWellFormed: Bool?
        var cacheAvailable: Bool?
        if let execution = payload["execution"] as? [String: Any] {
            if let rawWaves = execution["waves"] as? [Any] {
                var parsedWaves: [SpawnBatchObservation.ExecutionWave] = []
                var allWavesWellFormed = true
                for rawWave in rawWaves {
                    guard let wave = rawWave as? [String: Any] else {
                        allWavesWellFormed = false
                        continue
                    }
                    let parsed = SpawnBatchObservation.ExecutionWave(
                        wave: wave["wave"] as? Int,
                        remoteJobs: wave["remote_jobs"] as? Int,
                        effectiveLocalSlots: wave["effective_local_slots"] as? Int,
                        localSubwaves: wave["local_subwaves"] as? [Int],
                        limitingFactors: wave["limited_by"] as? [String]
                    )
                    allWavesWellFormed = allWavesWellFormed && parsed.isWellFormed
                    parsedWaves.append(parsed)
                }
                executionWaves = parsedWaves
                everyExecutionWaveWellFormed =
                    allWavesWellFormed && parsedWaves.count == rawWaves.count
            } else {
                executionWaves = []
                everyExecutionWaveWellFormed = false
            }
            if let cache = execution["cache"] as? [String: Any] {
                cacheAvailable = cache["available"] as? Bool
            }
        } else if payload["execution"] != nil {
            executionWaves = []
            everyExecutionWaveWellFormed = false
        }

        return SpawnBatchObservation(
            resultKind: "spawn_batch_result",
            maxParallel: payload["max_parallel"] as? Int,
            reportedSucceeded: payload["succeeded"] as? Int,
            reportedFailed: payload["failed"] as? Int,
            observedSucceeded: observedSucceeded,
            observedFailed: observedFailed,
            orderedJobIds: ids,
            childRows: childRows,
            everyRowSettled: everyRowSettled,
            aggregateStatus: payload["aggregate_status"] as? String,
            executionWaves: executionWaves,
            everyExecutionWaveWellFormed: everyExecutionWaveWellFormed,
            cacheAvailable: cacheAvailable
        )
    }

    public let toolCalls: [ToolInvocation]
    /// The model's final assistant text (what rubric grading reads).
    public let finalText: String
    /// Iterations charged against the loop budget.
    public let iterations: Int
    /// `AgentToolLoop.Exit` as a string: `finalResponse`,
    /// `iterationCapReached`, `toolRejected`, `cancelled`,
    /// `clarifyRequested` (clarify intercept), `endedBySurface`.
    public let exit: String
    /// First-turn system prompt (post-compose) for forensics.
    public let systemPrompt: String
    /// Names of the tool schemas sent to the model on the first
    /// iteration — forensics for "did the model even see this tool".
    public let toolSchemaNames: [String]
    /// Wall-clock milliseconds spent INSIDE the agent loop (model steps +
    /// tool execution), excluding workspace setup and any judge calls —
    /// the latency the runner should report.
    public let loopDurationMs: Double
    /// Driver-staged transient notices observed across all iterations
    /// (budget warnings, dedupe notices, next-step nudges) in stage order.
    /// Lets cases assert a nudge actually FIRED, not just that the model
    /// behaved.
    public let notices: [String]
    /// One bounded diagnostic per model step, including failed/truncated
    /// generations that never committed a tool invocation.
    public let stepDiagnostics: [StepDiagnostic]
    /// True when the sticky watermark recorded at least one summarize/drop
    /// decision — i.e. history compaction actually occurred during the run
    /// (the compaction-stress assertion).
    public let compacted: Bool
    /// Non-nil when the loop aborted (engine threw, model unroutable).
    public let error: String?
    /// Token-weighted mean decode speed (tokens/sec) across every
    /// streaming model step, from the runtime's authoritative
    /// `StreamingStatsHint`. `nil` for non-streaming or remote runs that
    /// never surfaced a stats hint. The headline "how fast does this
    /// model generate on this Mac" number the optimization loop tracks.
    public let decodeTokensPerSecond: Double?
    /// First measured prompt-processing (prefill) speed (tokens/sec), from
    /// the stats hint's `prefill=` flag. Not strictly the first model step:
    /// an early step that ends in a tool call throws before emitting its
    /// end-of-step stats, so the first reading often lands on a later step.
    /// Drives TTFT on long contexts; KV-prefix reuse shows up as a higher
    /// value once the prefix is warm.
    public let prefillTokensPerSecond: Double?
    /// Time-to-first-token for the first model step, in milliseconds —
    /// wall clock from request dispatch to the first streamed delta.
    /// `nil` for non-streaming runs.
    public let ttftMs: Double?
    /// Wall-clock milliseconds from loop dispatch until the model's first
    /// tool action. nil for text-only runs.
    public let firstActionMs: Double?
    /// Total generated tokens across all model steps (sum of per-step
    /// stats-hint counts). Pairs with `loopDurationMs` for a run-level
    /// throughput sanity check.
    public let completionTokens: Int?
    /// Estimated INPUT (prompt + tool-schema) tokens summed across every
    /// model step — the context-cost signal the optimization loop drives
    /// down. Estimated deterministically at compose time (the exact
    /// messages + frozen tool schema each step), so it is provider-
    /// independent and reproducible: it does not depend on a runtime stats
    /// hint and so is populated for remote frontier runs too. `nil` when no
    /// model step ran.
    public let promptTokensTotal: Int?
    /// Largest single-step input estimate — the context-window high-water
    /// mark for the run (what has to fit the budget at the worst moment).
    public let peakContextTokens: Int?
    /// Number of model steps (loop iterations that called the model).
    public let modelSteps: Int?
    /// Per-contributor context-cost attribution (system-prompt sections,
    /// per-tool schema cost, memory, first/peak/cumulative step inputs,
    /// end-of-run history composition). Built from the SAME composed
    /// context the loop sent, so it reconciles with `promptTokensTotal` /
    /// `peakContextTokens` above. nil on aborted runs that never composed.
    public let contextAttribution: ContextAttribution?

    public init(
        toolCalls: [ToolInvocation],
        finalText: String,
        iterations: Int,
        exit: String,
        systemPrompt: String,
        toolSchemaNames: [String],
        loopDurationMs: Double = 0,
        notices: [String] = [],
        stepDiagnostics: [StepDiagnostic] = [],
        compacted: Bool = false,
        error: String?,
        decodeTokensPerSecond: Double? = nil,
        prefillTokensPerSecond: Double? = nil,
        ttftMs: Double? = nil,
        firstActionMs: Double? = nil,
        completionTokens: Int? = nil,
        promptTokensTotal: Int? = nil,
        peakContextTokens: Int? = nil,
        modelSteps: Int? = nil,
        contextAttribution: ContextAttribution? = nil
    ) {
        self.toolCalls = toolCalls
        self.finalText = finalText
        self.iterations = iterations
        self.exit = exit
        self.systemPrompt = systemPrompt
        self.toolSchemaNames = toolSchemaNames
        self.loopDurationMs = loopDurationMs
        self.notices = notices
        self.stepDiagnostics = stepDiagnostics
        self.compacted = compacted
        self.error = error
        self.decodeTokensPerSecond = decodeTokensPerSecond
        self.prefillTokensPerSecond = prefillTokensPerSecond
        self.ttftMs = ttftMs
        self.firstActionMs = firstActionMs
        self.completionTokens = completionTokens
        self.promptTokensTotal = promptTokensTotal
        self.peakContextTokens = peakContextTokens
        self.modelSteps = modelSteps
        self.contextAttribution = contextAttribution
    }
}

// MARK: - Sandbox mode

/// How an `agent_loop` eval composes when the case runs against the
/// live Linux-VM sandbox. `nil` (the default) keeps the host-folder path.
public enum AgentLoopSandboxMode: Sendable, Equatable {
    /// Pure sandbox: the five public workspace tools route to the VM; no
    /// host folder is registered or bridged.
    case pure
}

// MARK: - Evaluator

/// Entry point for the `agent_loop` behaviour evals. Main-actor-bound
/// because prompt composition, the tool registry, and folder tool
/// registration are.
@MainActor
public enum AgentLoopEvaluator {

    /// Run the canonical agent loop against a seeded `workspace` folder
    /// and return the transcript. Folder tools (`file_read`,
    /// `file_write`, `file_search`, `shell_run`, …) are registered for
    /// the workspace for the duration of the run and unregistered after.
    ///
    /// - Parameters:
    ///   - task: the user message seeding the run.
    ///   - workspace: host folder the agent operates on (fixture-seeded
    ///     temp directory in eval runs).
    ///   - maxIterations: loop budget (model steps).
    ///   - model: model id; defaults to the runner's `ModelOverride`.
    ///   - contextWindowOverride: when set, the budget manager is built
    ///     against this window instead of the model's real one — the
    ///     compaction-stress lever ("long tool outputs on a small window").
    ///   - streaming: when true (default, matching the chat surface) each
    ///     model step uses the streaming path — where the delta routing,
    ///     tool-call assembly, and most local-model parser bugs live.
    ///   - enableThinking: explicit chat-toggle choice copied to every model
    ///     step. nil preserves the production unspecified-agent policy.
    ///   - maxTokens: explicit per-step response cap. nil follows the same
    ///     per-agent/bundle runtime defaults as production Chat.
    ///   - sandbox: non-nil switches the run into live-sandbox mode —
    ///     the container is booted (kept alive across cases; boot is
    ///     expensive, per-agent provisioning is cheap), the agent's
    ///     builtin sandbox tools are registered for the run, and the
    ///     prompt composes with `executionMode: .sandbox(...)`. Requires
    ///     `agentId` to reference a PERSISTED agent whose
    ///     `autonomousExec.enabled == true` (the runner's eval agent) —
    ///     tool registration reads the agent record. Builtin sandbox
    ///     tools are unregistered on exit; the container is NOT stopped.
    ///   - cancelAfterToolCalls: interruption lever for cancellation evals.
    ///     When set, the loop's `isCancelled` hook flips true once this many
    ///     tool calls have been processed, so the run ends with the
    ///     production `.cancelled` exit at the next cancellation checkpoint
    ///     — the same path a user's stop button drives. nil (default)
    ///     never cancels.
    public static func run(
        task: String,
        workspace: URL,
        agentId: UUID? = nil,
        maxIterations: Int = 10,
        model: String? = nil,
        contextWindowOverride: Int? = nil,
        streaming: Bool = true,
        maxTokens: Int? = nil,
        enableThinking: Bool? = nil,
        stopOnToolRejection: Bool = false,
        sandbox: AgentLoopSandboxMode? = nil,
        cancelAfterToolCalls: Int? = nil
    ) async -> AgentLoopTranscript {
        // The Default agent's schema is hard-restricted to the 8-tool
        // configure baseline (folder write tools enter only via
        // `capabilities_load`), which is not the surface these agentic
        // folder evals exercise. When the active agent is the Default
        // agent, run under an ephemeral non-default agent id so the
        // composed schema matches a regular chat agent working in a
        // folder (folder tools in, configure tools stripped).
        let activeId = AgentManager.shared.activeAgent.id
        let resolvedAgentId = agentId ?? (activeId == Agent.defaultId ? UUID() : activeId)
        let resolvedModel =
            model
            ?? ChatConfigurationStore.load().coreModelIdentifier
            ?? "foundation"
        // AgentLoop evals exercise the in-app Chat contract. Publish the same
        // inference provenance as ChatSession so ModelRuntime attributes the
        // resident parent to this invoking surface; otherwise the default
        // `.httpAPI` engine marks it as unrelated protected work and a real
        // different-local spawn handoff is rejected before execution.
        let sessionSource: SessionSource = .chat
        let engine = ChatEngine(source: sessionSource.inferenceSource)

        // Workspace context + folder tools, mirroring the chat path's
        // host-folder mode. Pure sandbox mode composes with NO host folder
        // context — the model's whole file/exec surface is `sandbox_*`.
        // Folder tools are registered process-wide (idempotent) and resolve
        // the eval workspace from the TaskLocal folder root bound around
        // every dispatch below, so a concurrent user folder chat is never
        // redirected at the eval temp directory (and vice versa).
        let wantsHostFolder = sandbox == nil
        var folderContext: FolderContext?
        if wantsHostFolder {
            folderContext = await FolderContextService.shared.buildContext(from: workspace)
            FolderToolManager.shared.ensureFolderToolsRegistered()
        }
        // The eval's folder root, bound per dispatch (nil in pure sandbox
        // mode). `ToolRegistry.execute`'s combined-mode chokepoint reads the
        // same TaskLocal, so read-only scope / secret policy / sandbox read
        // bridge resolve exactly as production would.
        let evalFolderRoot: URL? = wantsHostFolder ? workspace : nil

        // Live-sandbox mode: boot/provision through the SAME registrar
        // the chat surface uses (container start is coalesced + kept
        // alive across cases; per-agent provisioning is idempotent),
        // then verify the real builtin sandbox tools actually landed —
        // a boot/provision failure must surface as an errored case, not
        // as a confusing "model never called sandbox_exec" failure.
        // Teardown unregisters the per-agent builtin tools; the
        // container intentionally stays up (boot can take minutes).
        if sandbox != nil {
            await SandboxToolRegistrar.shared.registerTools(for: resolvedAgentId)
            if let reason = SandboxToolRegistrar.shared.unavailabilityReason(for: resolvedAgentId) {
                ToolRegistry.shared.unregisterAllBuiltinSandboxTools()
                return AgentLoopTranscript(
                    toolCalls: [],
                    finalText: "",
                    iterations: 0,
                    exit: "errored",
                    systemPrompt: "",
                    toolSchemaNames: [],
                    error: "sandbox unavailable (\(reason.kind.rawValue)): \(reason.message)"
                )
            }
        }
        defer {
            if sandbox != nil {
                ToolRegistry.shared.unregisterAllBuiltinSandboxTools()
            }
        }

        // Execution mode the prompt/tool resolution composes under —
        // exactly the three production shapes ChatView can produce.
        let executionMode: ExecutionMode
        switch sandbox {
        case nil:
            // `wantsHostFolder` guarantees folderContext is non-nil here.
            executionMode = .hostFolder(folderContext!)
        case .pure:
            executionMode = .sandbox(hostRead: nil)
        }

        // Buffer hygiene: flush any specs a previous (possibly crashed)
        // run left in the process-wide load buffer so they can't leak
        // into this run's drain bookkeeping.
        _ = await CapabilityLoadBuffer.shared.drain()

        var history: [ChatMessage] = [ChatMessage(role: "user", content: task)]
        let composed = await SystemPromptComposer.composeChatContext(
            agentId: resolvedAgentId,
            executionMode: executionMode,
            model: resolvedModel,
            query: task,
            messages: history,
            additionalToolNames: []
        )
        let systemPrompt = composed.prompt
        // Frozen for the whole run (deferred-schema policy, production
        // parity): `capabilities_load` never patches the request schema.
        let toolSpecs = composed.tools

        // Shared loop budget wiring (same as chat/HTTP/plugin) with a
        // run-scoped sticky watermark.
        let contextWindow: Int
        if let contextWindowOverride {
            contextWindow = contextWindowOverride
        } else {
            contextWindow = await AgentLoopBudget.resolveContextWindow(modelId: resolvedModel)
        }
        // Production Chat sends the effective per-agent override and otherwise
        // leaves max_tokens nil so the active bundle/runtime config remains the
        // source of truth. Evals must not inject a hidden 2K cap: a substantial
        // file_write call can be truncated mid-JSON and falsely look like a
        // harness failure that users with the same agent never see.
        let resolvedMaxTokens =
            maxTokens ?? AgentManager.shared.effectiveMaxTokens(for: resolvedAgentId)
        let budgetManager = AgentLoopBudget.makeBudgetManager(
            contextWindow: contextWindow,
            systemPromptChars: systemPrompt.count,
            toolTokens: composed.toolTokens,
            maxResponseTokens: resolvedMaxTokens
        )
        let watermark = CompactionWatermark()

        // Stable per-run session id: threaded as the request `session_id`
        // so the inference layer's paged-KV prefix cache can reuse the
        // prompt across iterations — the production loops all do, and KV
        // reuse is itself behaviour under test.
        let sessionId = "agent-loop-eval-\(UUID().uuidString)"
        let state = AgentTaskState()
        var transcriptCalls: [AgentLoopTranscript.ToolInvocation] = []
        var noticesSeen: [String] = []
        var stepDiagnostics: [AgentLoopTranscript.StepDiagnostic] = []
        var finalText = ""
        // Per-run generation telemetry, accumulated across model steps
        // from the streaming `StreamingStatsHint`. Token-weighted so a
        // long decode step dominates the mean over a 2-token step. TTFT
        // and prefill speed are recorded from the FIRST step only (the
        // cold prefill); later steps reuse the KV prefix and aren't
        // comparable as a TTFT baseline.
        var decodeTpsWeightedSum = 0.0
        var decodeTpsTokenWeight = 0
        var completionTokensTotal = 0
        var firstStepTtftMs: Double?
        var firstStepPrefillTps: Double?
        let loopStarted = Date()
        var firstActionMs: Double?
        var sawAnyModelStep = false
        // Deterministic context-cost accounting, accumulated per model step
        // from the exact composed prompt + frozen tool schema. Unlike the
        // runtime-only decode/completion counters above, this does not depend
        // on a streaming stats hint, so it is populated for remote frontier
        // runs too — the optimization loop's provider-independent "tokens per
        // task" signal.
        var promptTokensTotal = 0
        var peakContextTokens = 0
        var modelStepCount = 0
        // First model step's input estimate — the cold-prefill cost the
        // attribution block reports separately from the cumulative total.
        var firstStepInputTokens: Int?
        // Set when a successful `complete` intercept ends the run; the
        // summary becomes the final answer (mirrors the chat surface,
        // where the summary renders as the completion banner).
        var completedViaTool = false
        // Set when a successful `clarify` intercept ends the run — mapped
        // to the distinct `clarifyRequested` exit so cases can assert on
        // "the model asked instead of guessing".
        var clarifiedViaTool = false

        /// Snapshot the run's accumulated state into a transcript — the
        /// single construction point for the success and error returns.
        func makeTranscript(
            iterations: Int,
            exit: String,
            loopMs: Double,
            error: String?
        ) -> AgentLoopTranscript {
            AgentLoopTranscript(
                toolCalls: transcriptCalls,
                finalText: finalText,
                iterations: iterations,
                exit: exit,
                systemPrompt: systemPrompt,
                toolSchemaNames: composed.tools.map { $0.function.name },
                loopDurationMs: loopMs,
                notices: noticesSeen,
                stepDiagnostics: stepDiagnostics,
                compacted: watermark.hasCompacted,
                error: error,
                decodeTokensPerSecond: decodeTpsTokenWeight > 0
                    ? decodeTpsWeightedSum / Double(decodeTpsTokenWeight)
                    : nil,
                prefillTokensPerSecond: firstStepPrefillTps,
                ttftMs: firstStepTtftMs,
                firstActionMs: firstActionMs,
                completionTokens: sawAnyModelStep ? completionTokensTotal : nil,
                promptTokensTotal: modelStepCount > 0 ? promptTokensTotal : nil,
                peakContextTokens: modelStepCount > 0 ? peakContextTokens : nil,
                modelSteps: modelStepCount > 0 ? modelStepCount : nil,
                contextAttribution: ContextAttribution.build(
                    manifest: composed.manifest,
                    tools: composed.tools,
                    memorySection: composed.memorySection,
                    staticPrefixHash: composed.cacheHint,
                    firstStepInputTokens: firstStepInputTokens,
                    peakStepInputTokens: modelStepCount > 0 ? peakContextTokens : nil,
                    cumulativeInputTokens: modelStepCount > 0 ? promptTokensTotal : nil,
                    modelSteps: modelStepCount > 0 ? modelStepCount : nil,
                    history: history
                )
            )
        }

        func makeRequest(
            _ messages: [ChatMessage],
            stream: Bool,
            includeTools: Bool = true
        ) -> ChatCompletionRequest {
            var request = ChatCompletionRequest(
                model: resolvedModel,
                messages: messages,
                // Match the real chat surface: nil means the installed
                // bundle's generation_config/JANG defaults win. A hidden
                // greedy override can trap tool-capable models in a
                // deterministic action loop that users never see with their
                // configured sampler.
                temperature: nil,
                max_tokens: resolvedMaxTokens,
                stream: stream,
                top_p: nil,
                frequency_penalty: nil,
                presence_penalty: nil,
                stop: nil,
                n: nil,
                tools: (includeTools && !toolSpecs.isEmpty) ? toolSpecs : nil,
                tool_choice: (includeTools && !toolSpecs.isEmpty) ? .auto : nil,
                session_id: sessionId
            )
            request.samplingParametersAreImplicit = true
            request.enable_thinking = enableThinking
            request.isAgentRequest = includeTools && !toolSpecs.isEmpty
            return request
        }

        func diagnosticPreview(_ value: String) -> String? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return String(trimmed.prefix(2_000))
        }

        func recordStepDiagnostic(
            step: Int,
            stopReason: String?,
            content: String,
            reasoning: String,
            sawToolCallProgress: Bool,
            pendingToolName: String?,
            toolArgumentCharacters: Int,
            completionTokens: Int? = nil
        ) {
            stepDiagnostics.append(
                .init(
                    step: step,
                    stopReason: stopReason,
                    contentCharacterCount: content.count,
                    reasoningCharacterCount: reasoning.count,
                    contentPreview: diagnosticPreview(content),
                    reasoningPreview: diagnosticPreview(reasoning),
                    sawToolCallProgress: sawToolCallProgress,
                    pendingToolName: pendingToolName,
                    toolArgumentCharacters: toolArgumentCharacters,
                    completionTokens: completionTokens,
                    requestedEnableThinking: enableThinking
                )
            )
        }

        /// Append the assistant turn carrying this step's tool calls.
        /// Call ids are pre-assigned (preserving model-supplied ids) so the
        /// history's `tool_calls[].id` and the driver's per-call ids match.
        /// Provider reasoning state is carried through like the chat surface
        /// does: Gemini 3.x 400s if a functionCall part is re-sent without
        /// its thought signature, and DeepSeek thinking mode 400s if
        /// `reasoning_content` is not echoed back on assistant turns.
        func appendAssistantToolCalls(
            _ invocations: [ServiceToolInvocation],
            content: String?,
            reasoning: String? = nil
        ) -> [ServiceToolInvocation] {
            let withIds = invocations.map { inv in
                ServiceToolInvocation(
                    toolName: inv.toolName,
                    jsonArguments: inv.jsonArguments,
                    toolCallId: AgentToolLoop.callId(for: inv),
                    geminiThoughtSignature: inv.geminiThoughtSignature
                )
            }
            history.append(
                ChatMessage(
                    role: "assistant",
                    content: (content?.isEmpty == false) ? content : nil,
                    tool_calls: withIds.map {
                        ToolCall(
                            id: $0.toolCallId ?? "",
                            type: "function",
                            function: ToolCallFunction(name: $0.toolName, arguments: $0.jsonArguments),
                            geminiThoughtSignature: $0.geminiThoughtSignature
                        )
                    },
                    tool_call_id: nil,
                    reasoning_content: (reasoning?.isEmpty == false) ? reasoning : nil
                )
            )
            return withIds
        }

        /// Registry dispatch for one call (shared by the serial hook and
        /// the parallel batch executor). Auto-approves `.ask`-gated tools
        /// (e.g. `shell_run`): eval runs are headless against isolated
        /// temp workspaces, so the approval NSPanel would hang the run on
        /// a card nobody can click.
        @Sendable func dispatchOne(_ inv: ServiceToolInvocation) async -> String {
            do {
                return try await ChatExecutionContext.$currentFolderRoot.withValue(evalFolderRoot) {
                    try await ChatExecutionContext.$currentSessionId.withValue(sessionId) {
                        try await ChatExecutionContext.$autoApproveToolPrompts.withValue(true) {
                            // Headless idle ceiling for `shell_run` when the model
                            // passed no `timeout`: there is no [Terminate] button
                            // here, so a hung command would wedge the eval run.
                            try await ChatExecutionContext.$defaultShellIdleTimeout.withValue(300) {
                                try await ToolRegistry.shared.execute(
                                    name: inv.toolName,
                                    argumentsJSON: inv.jsonArguments
                                )
                            }
                        }
                    }
                }
            } catch {
                return ToolEnvelope.fromError(error, tool: inv.toolName)
            }
        }

        /// History/transcript/intercept handling for one executed call —
        /// runs serially in model order, after dispatch.
        func postProcess(
            _ inv: ServiceToolInvocation,
            callId: String,
            result: String
        ) async -> AgentLoopToolExecution {
            let isError = ToolEnvelope.isError(result)
            // Deferred-schema policy (production parity): drain the load buffer
            // — tools loaded via `capabilities_load` are callable immediately
            // through the registry, and their schemas already ride in the tool
            // result (`CapabilitiesLoadTool.loadedSchemaBlock`) — but the request
            // schema stays FROZEN for the whole run (no mid-run `<tools>`
            // rewrite), so the paged-KV prefix stays byte-stable.
            if inv.toolName == "capabilities_load" || inv.toolName == "capabilities" {
                _ = await CapabilityLoadBuffer.shared.drain()
            }
            history.append(
                ChatMessage(role: "tool", content: result, tool_calls: nil, tool_call_id: callId)
            )
            transcriptCalls.append(
                .init(
                    name: inv.toolName,
                    arguments: inv.jsonArguments,
                    resultPreview: String(result.prefix(300)),
                    wasDeduped: false,
                    wasError: isError,
                    spawnBatch: AgentLoopTranscript.spawnBatchObservation(from: result)
                )
            )
            // Agent-loop intercepts, mirroring the chat surface: a
            // successful `complete` ends the run and a successful `clarify`
            // ends the run awaiting user input (headless: no answer ever
            // arrives). Error envelopes fall through so the model can retry.
            //
            // Under the agent-loop contract the user-facing ANSWER is the
            // model's visible prose; `complete`'s summary is only a closing
            // status. Prefer this turn's assistant prose as `finalText` so
            // rubric grading judges the real answer, falling back to the
            // summary when the turn carried no visible text (the older
            // bare-`complete` behavior the chat banner still renders).
            if inv.toolName == "complete", !isError {
                completedViaTool = true
                let answer =
                    history.last(where: { $0.role == "assistant" })?
                    .content?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !answer.isEmpty {
                    finalText = answer
                } else if let summary = CompleteTool.parseSummary(from: inv.jsonArguments) {
                    finalText = summary
                }
                return AgentLoopToolExecution(result: result, endRun: true)
            }
            if inv.toolName == "clarify", !isError {
                clarifiedViaTool = true
                return AgentLoopToolExecution(result: result, endRun: true)
            }
            return AgentLoopToolExecution(result: result, isError: isError)
        }

        let hooks = AgentLoopHooks(
            isCancelled: {
                // Cancellation evals: flip cancelled once the processed-call
                // budget is reached. Reads the same transcript array the
                // executors append to (all on the main actor, so no race).
                guard let cancelAfterToolCalls else { return false }
                return transcriptCalls.count >= cancelAfterToolCalls
            },
            buildMessages: { notices in
                // Canonical notice contract: trim with the system prefix
                // kept byte-stable, then notices ride transiently. Notices
                // are also recorded for the transcript so cases can assert
                // a nudge/warning actually fired.
                noticesSeen.append(contentsOf: notices)
                var msgs: [ChatMessage] = [ChatMessage(role: "system", content: systemPrompt)]
                msgs.append(contentsOf: history)
                return AgentLoopBudget.composeIterationMessages(
                    msgs,
                    notices: notices,
                    manager: budgetManager,
                    watermark: watermark
                )
            },
            modelStep: { effective, _ in
                // Context-cost accounting: estimate the INPUT tokens for THIS
                // step (the exact messages the loop composed + the run's
                // frozen tool schema) before the model call. Deterministic and
                // provider-independent, so it is captured even when the run
                // surfaces no runtime stats hint (remote / non-streaming).
                let stepInputTokens =
                    ContextBudgetManager.estimateTokens(for: effective) + composed.toolTokens
                promptTokensTotal += stepInputTokens
                peakContextTokens = max(peakContextTokens, stepInputTokens)
                if firstStepInputTokens == nil { firstStepInputTokens = stepInputTokens }
                modelStepCount += 1
                if streaming {
                    // Streaming path (default, matching chat): delta routing
                    // and tool-call assembly — where most local-model parser
                    // bugs live — are part of what's under test.
                    var content = ""
                    // Reasoning deltas are kept (not shown in finalText) so
                    // assistant turns can echo `reasoning_content` back to
                    // providers that require it in thinking mode (DeepSeek).
                    var reasoning = ""
                    var terminalStopReason: String?
                    var terminalUnclosedReasoning = false
                    var streamedToolName: String?
                    var streamedToolArgumentCharacters = 0
                    var sawToolCallProgress = false
                    var stepCompletionTokens: Int?
                    let stepStarted = Date()
                    let isFirstStep = !sawAnyModelStep
                    sawAnyModelStep = true
                    do {
                        let stream = try await engine.streamChat(
                            request: makeRequest(effective, stream: true)
                        )
                        for try await delta in stream {
                            // TTFT: first streamed delta of the FIRST step,
                            // regardless of channel (reasoning / content /
                            // tool hint all count as "model produced output").
                            if isFirstStep, firstStepTtftMs == nil {
                                firstStepTtftMs = Date().timeIntervalSince(stepStarted) * 1000
                            }
                            if let toolName = StreamingToolHint.decode(delta) {
                                sawToolCallProgress = true
                                streamedToolName = toolName.isEmpty ? nil : toolName
                                // Local envelope-first parsing replays canonical
                                // arguments after the name commits.
                                streamedToolArgumentCharacters = 0
                                continue
                            }
                            if let fragment = StreamingToolHint.decodeArgs(delta) {
                                sawToolCallProgress = true
                                streamedToolArgumentCharacters += fragment.utf8.count
                                if streamedToolArgumentCharacters
                                    > AgentToolLoop.maxStreamingToolArgumentCharacters
                                {
                                    recordStepDiagnostic(
                                        step: modelStepCount,
                                        stopReason: "oversized_tool_call",
                                        content: content,
                                        reasoning: reasoning,
                                        sawToolCallProgress: true,
                                        pendingToolName: streamedToolName,
                                        toolArgumentCharacters: streamedToolArgumentCharacters
                                    )
                                    finalText = ""
                                    return .oversizedToolCall(
                                        toolName: streamedToolName,
                                        argumentCharacters: streamedToolArgumentCharacters
                                    )
                                }
                                continue
                            }
                            if let fragment = StreamingToolCallProgressHint.decode(delta) {
                                sawToolCallProgress = true
                                streamedToolArgumentCharacters += fragment.utf8.count
                                if streamedToolArgumentCharacters
                                    > AgentToolLoop.maxStreamingToolArgumentCharacters
                                {
                                    recordStepDiagnostic(
                                        step: modelStepCount,
                                        stopReason: "oversized_tool_call",
                                        content: content,
                                        reasoning: reasoning,
                                        sawToolCallProgress: true,
                                        pendingToolName: streamedToolName,
                                        toolArgumentCharacters: streamedToolArgumentCharacters
                                    )
                                    finalText = ""
                                    return .oversizedToolCall(
                                        toolName: streamedToolName,
                                        argumentCharacters: streamedToolArgumentCharacters
                                    )
                                }
                                continue
                            }
                            if let fragment = StreamingReasoningHint.decode(delta) {
                                reasoning += fragment
                                continue
                            }
                            if let stats = StreamingStatsHint.decode(delta) {
                                terminalStopReason = stats.stopReason
                                terminalUnclosedReasoning = stats.unclosedReasoning
                                // Authoritative end-of-step runtime stats:
                                // token-weight the decode tps, sum tokens,
                                // and keep the first step's prefill speed.
                                if stats.tokensPerSecond > 0, stats.tokenCount > 0 {
                                    decodeTpsWeightedSum += stats.tokensPerSecond * Double(stats.tokenCount)
                                    decodeTpsTokenWeight += stats.tokenCount
                                }
                                completionTokensTotal += max(0, stats.tokenCount)
                                stepCompletionTokens = max(0, stats.tokenCount)
                                // Prefill speed: keep the FIRST measured reading
                                // (the cold prompt-processing pass). Not gated to
                                // the first model step — an early step that ends
                                // in a tool call throws `ServiceToolInvocations`
                                // before emitting its end-of-step stats hint, so
                                // the first prefill reading often arrives on a
                                // later step. Take the first positive value seen.
                                if firstStepPrefillTps == nil,
                                    let prefill = stats.prefillTokensPerSecond,
                                    prefill > 0
                                {
                                    firstStepPrefillTps = prefill
                                }
                                continue
                            }
                            if StreamingToolHint.isSentinel(delta) { continue }
                            content += delta
                        }
                        finalText = content
                        recordStepDiagnostic(
                            step: modelStepCount,
                            stopReason: terminalStopReason,
                            content: content,
                            reasoning: reasoning,
                            sawToolCallProgress: sawToolCallProgress,
                            pendingToolName: streamedToolName,
                            toolArgumentCharacters: streamedToolArgumentCharacters,
                            completionTokens: stepCompletionTokens
                        )
                        if terminalStopReason == "length",
                            sawToolCallProgress,
                            streamedToolArgumentCharacters > 0
                        {
                            return .truncatedToolCall(
                                toolName: streamedToolName,
                                argumentCharacters: streamedToolArgumentCharacters
                            )
                        }
                        return AgentLoopModelStep.classifyTerminal(
                            contentIsBlank: content.trimmingCharacters(in: .whitespacesAndNewlines)
                                .isEmpty,
                            thinkingIsBlank: reasoning.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).isEmpty,
                            stopReason: terminalStopReason,
                            unclosedReasoning: terminalUnclosedReasoning,
                            requiresVisibleFinalResponse: true
                        )
                    } catch let invs as ServiceToolInvocations {
                        recordStepDiagnostic(
                            step: modelStepCount,
                            stopReason: "tool_calls",
                            content: content,
                            reasoning: reasoning,
                            sawToolCallProgress: true,
                            pendingToolName: streamedToolName,
                            toolArgumentCharacters: streamedToolArgumentCharacters,
                            completionTokens: stepCompletionTokens
                        )
                        // Interim prose preceding tool calls is NOT the
                        // final answer (never let it go stale into the
                        // transcript's finalText) — but it DOES stay in
                        // history, like the chat surface: the model's
                        // narrated findings must survive later compaction
                        // of the tool results they describe.
                        finalText = ""
                        return .toolCalls(
                            appendAssistantToolCalls(
                                invs.invocations,
                                content: content,
                                reasoning: reasoning
                            )
                        )
                    } catch let inv as ServiceToolInvocation {
                        recordStepDiagnostic(
                            step: modelStepCount,
                            stopReason: "tool_call",
                            content: content,
                            reasoning: reasoning,
                            sawToolCallProgress: true,
                            pendingToolName: inv.toolName,
                            toolArgumentCharacters: inv.jsonArguments.utf8.count,
                            completionTokens: stepCompletionTokens
                        )
                        finalText = ""
                        return .toolCalls(
                            appendAssistantToolCalls([inv], content: content, reasoning: reasoning)
                        )
                    }
                }

                let response = try await engine.completeChat(
                    request: makeRequest(effective, stream: false)
                )
                guard let choice = response.choices.first else {
                    recordStepDiagnostic(
                        step: modelStepCount,
                        stopReason: nil,
                        content: "",
                        reasoning: "",
                        sawToolCallProgress: false,
                        pendingToolName: nil,
                        toolArgumentCharacters: 0,
                        completionTokens: response.usage.completion_tokens
                    )
                    return .finalResponse
                }
                guard let calls = choice.message.tool_calls, !calls.isEmpty else {
                    let text = choice.message.content ?? ""
                    let reasoning = choice.message.reasoning_content ?? ""
                    finalText = text
                    recordStepDiagnostic(
                        step: modelStepCount,
                        stopReason: choice.finish_reason,
                        content: text,
                        reasoning: reasoning,
                        sawToolCallProgress: false,
                        pendingToolName: nil,
                        toolArgumentCharacters: 0,
                        completionTokens: response.usage.completion_tokens
                    )
                    return AgentLoopModelStep.classifyTerminal(
                        contentIsBlank: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        thinkingIsBlank: reasoning
                            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        stopReason: choice.finish_reason,
                        requiresVisibleFinalResponse: true
                    )
                }
                recordStepDiagnostic(
                    step: modelStepCount,
                    stopReason: choice.finish_reason,
                    content: choice.message.content ?? "",
                    reasoning: choice.message.reasoning_content ?? "",
                    sawToolCallProgress: true,
                    pendingToolName: calls.first?.function.name,
                    toolArgumentCharacters: calls.reduce(0) { $0 + $1.function.arguments.utf8.count },
                    completionTokens: response.usage.completion_tokens
                )
                // Tool calls present: any prose on this turn is interim
                // narration, not the final answer. `reasoning_content` is
                // preserved for providers that require it echoed (DeepSeek).
                finalText = ""
                history.append(
                    ChatMessage(
                        role: "assistant",
                        content: choice.message.content,
                        tool_calls: calls,
                        tool_call_id: nil,
                        reasoning_content: choice.message.reasoning_content
                    )
                )
                return .toolCalls(
                    calls.map {
                        ServiceToolInvocation(
                            toolName: $0.function.name,
                            jsonArguments: $0.function.arguments,
                            toolCallId: $0.id
                        )
                    }
                )
            },
            onDedupedResult: { inv, callId, held in
                if firstActionMs == nil {
                    firstActionMs = Date().timeIntervalSince(loopStarted) * 1000
                }
                history.append(
                    ChatMessage(role: "tool", content: held, tool_calls: nil, tool_call_id: callId)
                )
                transcriptCalls.append(
                    .init(
                        name: inv.toolName,
                        arguments: inv.jsonArguments,
                        resultPreview: String(held.prefix(300)),
                        wasDeduped: true,
                        spawnBatch: AgentLoopTranscript.spawnBatchObservation(from: held)
                    )
                )
            },
            executeTool: { inv, callId in
                if firstActionMs == nil {
                    firstActionMs = Date().timeIntervalSince(loopStarted) * 1000
                }
                let result = await dispatchOne(inv)
                return await postProcess(inv, callId: callId, result: result)
            },
            executeBatch: { calls in
                if firstActionMs == nil, !calls.isEmpty {
                    firstActionMs = Date().timeIntervalSince(loopStarted) * 1000
                }
                // Parallel batch executor (the production HTTP/chat shape).
                // Batches carrying a loop-ending intercept fall back to
                // serial model-order execution, stopping at the first
                // `endRun` — mirroring the chat surface, so siblings after
                // a `complete`/`clarify` never run.
                if AgentToolLoop.containsIntercept(calls) {
                    var executions: [AgentLoopToolExecution] = []
                    for call in calls {
                        let result = await dispatchOne(call.invocation)
                        let execution = await postProcess(
                            call.invocation,
                            callId: call.callId,
                            result: result
                        )
                        executions.append(execution)
                        if execution.endRun { break }
                    }
                    return executions
                }
                // PRODUCTION two-phase batch (`sessionId:agentId:`): phase 1
                // resolves permission gates serially in model order (denials
                // produce paired rejection/skip envelopes — exercised e2e
                // here), phase 2 executes the approved set in parallel with
                // same-path slots serialized. Auto-approve stays bound: eval
                // runs are headless, an approval panel would hang the run.
                let results = await ChatExecutionContext.$currentFolderRoot.withValue(evalFolderRoot) {
                    await ChatExecutionContext.$autoApproveToolPrompts.withValue(true) {
                        await ChatExecutionContext.$defaultShellIdleTimeout.withValue(300) {
                            await AgentToolLoop.runBatchInParallel(
                                calls,
                                sessionId: sessionId,
                                agentId: resolvedAgentId
                            )
                        }
                    }
                }
                var executions: [AgentLoopToolExecution] = []
                executions.reserveCapacity(calls.count)
                for (call, raw) in zip(calls, results) {
                    executions.append(
                        await postProcess(call.invocation, callId: call.callId, result: raw.result)
                    )
                }
                return executions
            },
            // Production parity: chat wires the todo-staleness nudge
            // (unchecked items + N iterations without a `todo` call →
            // one-line notice). Without it the eval lane silently drops a
            // production behavior that exists precisely for multi-step
            // discipline — the thing todo-discipline cases measure.
            pendingTodoCount: {
                guard let todo = await AgentTodoStore.shared.todo(for: sessionId) else {
                    return 0
                }
                return todo.totalCount - todo.doneCount
            },
            emitFallbackText: { text in
                // Preserve real partial visible output for length exhaustion;
                // the fallback is presentation, not a replacement for the
                // model evidence persisted in failed-run transcripts.
                if text == AgentToolLoop.lengthExhaustedFallback {
                    finalText = AgentLoopModelStep.contentWithLengthFallback(
                        finalText,
                        fallback: text
                    )
                } else {
                    finalText = text
                }
            }
        )

        do {
            let runResult = try await ChatExecutionContext.$currentSessionSource.withValue(
                sessionSource
            ) {
                try await ChatExecutionContext.$currentAgentId.withValue(resolvedAgentId) {
                    try await ChatExecutionContext.$currentModelName.withValue(resolvedModel) {
                        try await ChatExecutionContext.$currentEnableThinking.withValue(enableThinking) {
                            try await AgentToolLoop.run(
                                policy: AgentLoopPolicy(
                                    maxIterations: maxIterations,
                                    stopOnToolRejection: stopOnToolRejection,
                                    dedupeNoticeEnabled: true,
                                    maxDataMovementSteps: min(16, maxIterations)
                                ),
                                state: state,
                                hooks: hooks
                            )
                        }
                    }
                }
            }
            // Production parity (ChatView): when the iteration budget is
            // exhausted mid-task, chat sends ONE final tool-free request over
            // the same trimmed history and streams that as the visible
            // answer. Without this, a cap-hitting eval run scores an empty
            // finalText that no production user would ever see. The exit
            // label stays `iterationCapReached` — cases can still assert the
            // cap — but the transcript carries the wrap-up text.
            if case .iterationCapReached = runResult.exit {
                var msgs: [ChatMessage] = [ChatMessage(role: "system", content: systemPrompt)]
                msgs.append(contentsOf: history)
                let trimmed = AgentLoopBudget.trimPreservingSystemPrefix(
                    msgs,
                    with: budgetManager,
                    watermark: watermark
                )
                // No tool schema on the wrap-up call (mirrors chat's
                // `tools: nil`), so the token estimate excludes toolTokens.
                let wrapUpInputTokens = ContextBudgetManager.estimateTokens(for: trimmed)
                promptTokensTotal += wrapUpInputTokens
                peakContextTokens = max(peakContextTokens, wrapUpInputTokens)
                modelStepCount += 1
                // STREAMING, like ChatView's post-cap call (`stream: true`,
                // `tools: nil`): the non-streaming local path is not what
                // production drives here, and a failure must be visible in
                // the transcript notices — not silently swallowed.
                do {
                    var content = ""
                    let stream = try await engine.streamChat(
                        request: makeRequest(trimmed, stream: true, includeTools: false)
                    )
                    for try await delta in stream {
                        if StreamingReasoningHint.decode(delta) != nil { continue }
                        if let stats = StreamingStatsHint.decode(delta) {
                            if stats.tokensPerSecond > 0, stats.tokenCount > 0 {
                                decodeTpsWeightedSum +=
                                    stats.tokensPerSecond * Double(stats.tokenCount)
                                decodeTpsTokenWeight += stats.tokenCount
                            }
                            completionTokensTotal += max(0, stats.tokenCount)
                            continue
                        }
                        if StreamingToolHint.isSentinel(delta) { continue }
                        content += delta
                    }
                    let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { finalText = text }
                } catch {
                    noticesSeen.append("[post-cap wrap-up failed: \(error)]")
                }
            }
            // A run ended by a successful `complete` intercept IS the
            // model's final response (the summary), not a surface
            // interruption — report it as the happy-path exit so cases
            // score tool-completion and text-completion identically.
            // A `clarify` intercept maps to its own exit so cases can
            // assert "asked instead of guessing" distinctly.
            let exitLabel: String
            if case .endedBySurface = runResult.exit, completedViaTool {
                exitLabel = "finalResponse"
            } else if case .endedBySurface = runResult.exit, clarifiedViaTool {
                exitLabel = "clarifyRequested"
            } else {
                exitLabel = Self.describe(runResult.exit)
            }
            // Buffer hygiene: drain anything still pending (e.g. a
            // capabilities_load on the final iteration) so an eval run
            // can never leak buffered specs process-wide.
            _ = await CapabilityLoadBuffer.shared.drain()
            return makeTranscript(
                iterations: runResult.iterations,
                exit: exitLabel,
                loopMs: Date().timeIntervalSince(loopStarted) * 1000,
                error: nil
            )
        } catch {
            // Same hygiene on the abort path — a crashed model step must
            // not leak pending tool specs into the next run.
            _ = await CapabilityLoadBuffer.shared.drain()
            return makeTranscript(
                iterations: 0,
                exit: "errored",
                loopMs: Date().timeIntervalSince(loopStarted) * 1000,
                error: error.localizedDescription
            )
        }
    }

    private static func describe(_ exit: AgentToolLoop.Exit) -> String {
        switch exit {
        case .finalResponse: return "finalResponse"
        case .endedBySurface: return "endedBySurface"
        case .toolRejected: return "toolRejected"
        case .iterationCapReached: return "iterationCapReached"
        case .cancelled: return "cancelled"
        case .overBudget: return "overBudget"
        case .emptyResponseExhausted: return "emptyResponseExhausted"
        case .lengthExhausted: return "lengthExhausted"
        case .oversizedToolCallExhausted: return "oversizedToolCallExhausted"
        case .truncatedToolCallExhausted: return "truncatedToolCallExhausted"
        case .incompleteReasoningExhausted: return "incompleteReasoningExhausted"
        }
    }
}
