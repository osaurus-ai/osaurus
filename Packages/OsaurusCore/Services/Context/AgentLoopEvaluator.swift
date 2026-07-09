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

        public init(
            name: String,
            arguments: String,
            resultPreview: String,
            wasDeduped: Bool,
            wasError: Bool = false
        ) {
            self.name = name
            self.arguments = arguments
            self.resultPreview = resultPreview
            self.wasDeduped = wasDeduped
            self.wasError = wasError
        }
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

    public init(
        toolCalls: [ToolInvocation],
        finalText: String,
        iterations: Int,
        exit: String,
        systemPrompt: String,
        toolSchemaNames: [String],
        loopDurationMs: Double = 0,
        notices: [String] = [],
        compacted: Bool = false,
        error: String?,
        decodeTokensPerSecond: Double? = nil,
        prefillTokensPerSecond: Double? = nil,
        ttftMs: Double? = nil,
        completionTokens: Int? = nil,
        promptTokensTotal: Int? = nil,
        peakContextTokens: Int? = nil,
        modelSteps: Int? = nil
    ) {
        self.toolCalls = toolCalls
        self.finalText = finalText
        self.iterations = iterations
        self.exit = exit
        self.systemPrompt = systemPrompt
        self.toolSchemaNames = toolSchemaNames
        self.loopDurationMs = loopDurationMs
        self.notices = notices
        self.compacted = compacted
        self.error = error
        self.decodeTokensPerSecond = decodeTokensPerSecond
        self.prefillTokensPerSecond = prefillTokensPerSecond
        self.ttftMs = ttftMs
        self.completionTokens = completionTokens
        self.promptTokensTotal = promptTokensTotal
        self.peakContextTokens = peakContextTokens
        self.modelSteps = modelSteps
    }
}

// MARK: - Sandbox mode

/// How an `agent_loop` eval composes when the case runs against the
/// live Linux-VM sandbox. `nil` (the default) keeps the host-folder
/// path; the runner picks the mode from `fixtures.sandbox.hostFolder`.
public enum AgentLoopSandboxMode: Sendable, Equatable {
    /// Pure sandbox: every file/exec tool is a `sandbox_*` tool; no
    /// host folder tools are registered (`.sandbox(hostRead: nil)`).
    case pure
    /// Combined mode: the eval workspace becomes the READ-ONLY host
    /// context — `file_read` / `file_search` stay host-side while
    /// writes/execution happen in the VM (`.sandbox(hostRead: ctx)`).
    case combined
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
    ///   - maxTokens: per-step response cap; falls back to the user's
    ///     chat configuration, then 2048.
    ///   - sandbox: non-nil switches the run into live-sandbox mode —
    ///     the container is booted (kept alive across cases; boot is
    ///     expensive, per-agent provisioning is cheap), the agent's
    ///     builtin sandbox tools are registered for the run, and the
    ///     prompt composes with `executionMode: .sandbox(...)`. Requires
    ///     `agentId` to reference a PERSISTED agent whose
    ///     `autonomousExec.enabled == true` (the runner's eval agent) —
    ///     tool registration reads the agent record. Builtin sandbox
    ///     tools are unregistered on exit; the container is NOT stopped.
    public static func run(
        task: String,
        workspace: URL,
        agentId: UUID? = nil,
        maxIterations: Int = 10,
        model: String? = nil,
        contextWindowOverride: Int? = nil,
        streaming: Bool = true,
        maxTokens: Int? = nil,
        stopOnToolRejection: Bool = false,
        sandbox: AgentLoopSandboxMode? = nil
    ) async -> AgentLoopTranscript {
        // The Default agent's schema is hard-restricted to the 8-tool
        // configure baseline (folder write tools enter only via
        // `capabilities_load`), which is not the surface these agentic
        // folder evals exercise. When the active agent is the Default
        // agent, run under an ephemeral non-default agent id so the
        // composed schema matches a regular chat agent working in a
        // folder (folder tools in, configure tools stripped).
        // In-process interleaving guard: this evaluator swaps the
        // PROCESS-WIDE folder toolset to the eval workspace. Running it
        // while a user folder session is live would point the user's
        // chat tools at the eval temp directory mid-conversation —
        // refuse instead.
        if FolderContextService.shared.hasActiveFolder {
            return AgentLoopTranscript(
                toolCalls: [],
                finalText: "",
                iterations: 0,
                exit: "errored",
                systemPrompt: "",
                toolSchemaNames: [],
                error:
                    "AgentLoopEvaluator refused to run: a user folder session is active in this process."
            )
        }

        let activeId = AgentManager.shared.activeAgent.id
        let resolvedAgentId = agentId ?? (activeId == Agent.defaultId ? UUID() : activeId)
        let resolvedModel =
            model
            ?? ChatConfigurationStore.load().coreModelIdentifier
            ?? "foundation"
        let engine = ChatEngine()

        // Workspace context + folder tools, mirroring the chat path's
        // host-folder mode. Pure sandbox mode registers NO host folder
        // tools — the model's whole file/exec surface is `sandbox_*`.
        // On exit the eval registration is torn down and any PRIOR
        // registration (snapshot below) is restored, so eval cases can't
        // leak tools into each other or clobber a toolset registered
        // outside a folder session.
        let wantsHostFolder = (sandbox == nil || sandbox == .combined)
        let priorFolderContext = FolderToolManager.shared.registeredContext
        var folderContext: FolderContext?
        if wantsHostFolder {
            let built = await FolderContextService.shared.buildContext(from: workspace)
            folderContext = built
            FolderToolManager.shared.registerFolderTools(for: built)
        }
        defer {
            if wantsHostFolder {
                FolderToolManager.shared.unregisterFolderTools()
                if let priorFolderContext {
                    FolderToolManager.shared.registerFolderTools(for: priorFolderContext)
                }
            }
        }

        // Combined mode also activates the context on the service so
        // `ToolRegistry.execute`'s per-call combined-mode chokepoint
        // (`cachedRootPath` → read-only scope, secret-read policy,
        // sandbox read bridge) resolves exactly as production would.
        // Plain host-folder eval runs deliberately DON'T activate —
        // their tools take the root at registration and the combined
        // policy must stay inert for them.
        if sandbox == .combined, let folderContext {
            FolderContextService.shared.activateEvalContext(folderContext)
        }
        defer {
            if sandbox == .combined {
                FolderContextService.shared.deactivateEvalContext()
            }
        }

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
        case .combined:
            executionMode = .sandbox(hostRead: folderContext)
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
        let resolvedMaxTokens =
            maxTokens
            ?? ChatConfigurationStore.load().maxTokens
            ?? 2_048
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
                compacted: watermark.hasCompacted,
                error: error,
                decodeTokensPerSecond: decodeTpsTokenWeight > 0
                    ? decodeTpsWeightedSum / Double(decodeTpsTokenWeight)
                    : nil,
                prefillTokensPerSecond: firstStepPrefillTps,
                ttftMs: firstStepTtftMs,
                completionTokens: sawAnyModelStep ? completionTokensTotal : nil,
                promptTokensTotal: modelStepCount > 0 ? promptTokensTotal : nil,
                peakContextTokens: modelStepCount > 0 ? peakContextTokens : nil,
                modelSteps: modelStepCount > 0 ? modelStepCount : nil
            )
        }

        func makeRequest(
            _ messages: [ChatMessage],
            stream: Bool,
            includeTools: Bool = true
        ) -> ChatCompletionRequest {
            ChatCompletionRequest(
                model: resolvedModel,
                messages: messages,
                temperature: 0.0,
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
                return try await ChatExecutionContext.$currentSessionId.withValue(sessionId) {
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
            if inv.toolName == "capabilities_load" {
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
                    wasError: isError
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
                            if let fragment = StreamingReasoningHint.decode(delta) {
                                reasoning += fragment
                                continue
                            }
                            if let stats = StreamingStatsHint.decode(delta) {
                                // Authoritative end-of-step runtime stats:
                                // token-weight the decode tps, sum tokens,
                                // and keep the first step's prefill speed.
                                if stats.tokensPerSecond > 0, stats.tokenCount > 0 {
                                    decodeTpsWeightedSum += stats.tokensPerSecond * Double(stats.tokenCount)
                                    decodeTpsTokenWeight += stats.tokenCount
                                }
                                completionTokensTotal += max(0, stats.tokenCount)
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
                        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            // Empty turn (0-token / EOS-first, no tool call) —
                            // let the driver nudge-and-retry, then fall back.
                            return .emptyResponse
                        }
                        finalText = content
                        return .finalResponse
                    } catch let invs as ServiceToolInvocations {
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
                    return .finalResponse
                }
                guard let calls = choice.message.tool_calls, !calls.isEmpty else {
                    let text = choice.message.content ?? ""
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return .emptyResponse
                    }
                    finalText = text
                    return .finalResponse
                }
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
                history.append(
                    ChatMessage(role: "tool", content: held, tool_calls: nil, tool_call_id: callId)
                )
                transcriptCalls.append(
                    .init(
                        name: inv.toolName,
                        arguments: inv.jsonArguments,
                        resultPreview: String(held.prefix(300)),
                        wasDeduped: true
                    )
                )
            },
            executeTool: { inv, callId in
                let result = await dispatchOne(inv)
                return await postProcess(inv, callId: callId, result: result)
            },
            executeBatch: { calls in
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
                let results = await ChatExecutionContext.$autoApproveToolPrompts.withValue(true) {
                    await ChatExecutionContext.$defaultShellIdleTimeout.withValue(300) {
                        await AgentToolLoop.runBatchInParallel(
                            calls,
                            sessionId: sessionId,
                            agentId: resolvedAgentId
                        )
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
                // Empty-turn recovery exhausted: surface a visible answer so a
                // run never resolves to silent empty text.
                finalText = text
            }
        )

        let loopStarted = Date()
        do {
            let runResult = try await ChatExecutionContext.$currentAgentId.withValue(resolvedAgentId) {
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
                promptTokensTotal += ContextBudgetManager.estimateTokens(for: trimmed)
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
        }
    }
}
