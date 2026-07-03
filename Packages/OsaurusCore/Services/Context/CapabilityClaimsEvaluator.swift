//
//  CapabilityClaimsEvaluator.swift
//  osaurus
//
//  Public facade that drives a real, multi-turn agent loop for the
//  OsaurusEvals `capability_claims` domain. It runs the whole chat path —
//  compose prompt once → model call → tool dispatch → drain
//  `CapabilityLoadBuffer` → continue — so eval cases can assert on what
//  the model SAYS and DOES when asked "do you have X".
//
//  The internal `ChatCompletionRequest` / `ChatMessage` / `Tool` types
//  stay encapsulated; the public surface is a decode-friendly transcript
//  (ordered tool calls + final assistant text) plus an LLM-judge verdict
//  so the runner can combine deterministic transcript checks with a
//  rubric grade.
//
//  Deferred-schema policy (matches production): the system prompt and
//  tool schema are composed ONCE before the loop and stay frozen for the
//  whole run. Tools loaded mid-run via `capabilities_load` are callable
//  immediately through the registry; the drained names are recorded on
//  the transcript but never patched back into the request schema.
//

import Foundation

// MARK: - Public transcript

/// Decode-friendly record of one capability-claims agent run. Carries
/// the ordered tool calls and final assistant text the runner scores,
/// plus forensics (first-turn system prompt, mid-session loads) so a
/// failing row is debuggable from the JSON report alone.
public struct CapabilityClaimsTranscript: Sendable, Codable {
    /// One tool invocation the model emitted, in call order. Arguments
    /// are the raw JSON string the model produced (post-parse), so a
    /// case can assert both the tool name and its argument shape.
    public struct ToolInvocation: Sendable, Codable {
        public let name: String
        public let arguments: String

        public init(name: String, arguments: String) {
            self.name = name
            self.arguments = arguments
        }
    }

    /// Every tool call across every iteration, flattened in order. The
    /// deterministic transcript checks (did it discover/load before
    /// answering; did it load `Osaurus Browser` before browser tools)
    /// read this list.
    public let toolCalls: [ToolInvocation]
    /// The model's last assistant message text — what the LLM judge
    /// grades against the rubric.
    public let finalText: String
    /// How many model round-trips the loop took before it stopped
    /// emitting tool calls (or hit the cap).
    public let iterations: Int
    /// True when the loop stopped because it reached `maxIterations`
    /// rather than because the model produced a tool-call-free answer.
    /// A capped run is suspect — the model may have been looping.
    public let hitIterationCap: Bool
    /// First-turn system prompt (post-compose). Lets a report show
    /// "what the model saw" — including the enabled-capabilities
    /// manifest — without re-deriving it.
    public let systemPrompt: String
    /// Tool names brought into the schema mid-session via
    /// `capabilities_load`, in load order.
    public let loadedToolNames: [String]
    /// Non-nil when the loop aborted (model not routable, engine threw).
    /// `finalText` is empty in that case.
    public let error: String?
    /// Token-weighted mean decode speed (tokens/sec) across the run's
    /// model steps, read from each step's authoritative
    /// `usage.tokens_per_second`. nil for remote/non-streaming engines
    /// that don't report it (and on a run that produced no scored answer
    /// step). Surfaced so the eval report records token/s per AGENTS.md.
    public let decodeTokensPerSecond: Double?
    /// Total generated tokens summed across the run's model steps. nil
    /// when no step reported a completion-token count.
    public let completionTokens: Int?

    public init(
        toolCalls: [ToolInvocation],
        finalText: String,
        iterations: Int,
        hitIterationCap: Bool,
        systemPrompt: String,
        loadedToolNames: [String],
        error: String?,
        decodeTokensPerSecond: Double? = nil,
        completionTokens: Int? = nil
    ) {
        self.toolCalls = toolCalls
        self.finalText = finalText
        self.iterations = iterations
        self.hitIterationCap = hitIterationCap
        self.systemPrompt = systemPrompt
        self.loadedToolNames = loadedToolNames
        self.error = error
        self.decodeTokensPerSecond = decodeTokensPerSecond
        self.completionTokens = completionTokens
    }
}

/// One LLM-judge verdict for one rubric condition. `pass` is the grade;
/// `reason` is the judge's one-line justification, surfaced in the
/// report so a contributor can see WHY a condition failed.
public struct CapabilityClaimsJudgement: Sendable, Codable {
    public let pass: Bool
    public let reason: String

    public init(pass: Bool, reason: String) {
        self.pass = pass
        self.reason = reason
    }
}

/// Full audit of one judge call: the verdicts plus what actually happened
/// on the wire — which model graded, the raw reply text, and how many
/// attempts the retry ladder burned. `judge` returns only `verdicts`;
/// callers that persist judge evidence (the eval harness) use
/// `judgeDetailed` so a disputed rubric grade can be audited from the
/// report alone instead of re-running the case.
public struct CapabilityClaimsJudgeAudit: Sendable, Codable {
    public let verdicts: [CapabilityClaimsJudgement]
    /// The model id the judge call actually used (after nil-model fallback
    /// to the configured chat model / foundation).
    public let judgeModelId: String
    /// Raw judge reply text from the attempt that produced `verdicts`.
    /// nil when every attempt threw before returning a body.
    public let raw: String?
    /// Attempts consumed (1 = first try worked; >1 = retried a thrown call).
    public let attempts: Int

    public init(
        verdicts: [CapabilityClaimsJudgement],
        judgeModelId: String,
        raw: String?,
        attempts: Int
    ) {
        self.verdicts = verdicts
        self.judgeModelId = judgeModelId
        self.raw = raw
        self.attempts = attempts
    }
}

// MARK: - Evaluator

/// Public entry point for the capability-claims behaviour evals. Lives
/// on the main actor because the prompt composer, tool registry, and
/// agent lookups it drives are all main-actor-isolated.
@MainActor
public enum CapabilityClaimsEvaluator {

    /// Run the multi-turn agent loop for `query` against the live
    /// registry/agent state and return the transcript. The loop mirrors
    /// the production chat path: it composes the real system prompt
    /// (manifest included) ONCE, calls the routed model with that frozen
    /// tool schema, dispatches every tool call through
    /// `ToolRegistry.execute`, drains tools loaded via
    /// `capabilities_load` (callable immediately by name; recorded on
    /// the transcript, never patched into the schema), and continues
    /// until the model answers without calling a tool (or
    /// `maxIterations` is hit).
    ///
    /// `agentId` defaults to the active agent. `model` defaults to
    /// whatever `ChatConfigurationStore` currently routes to (set by the
    /// eval runner's `ModelOverride`).
    public static func run(
        query: String,
        agentId: UUID? = nil,
        maxIterations: Int = 6,
        model: String? = nil,
        toolExecutionTimeout: TimeInterval? = nil,
        autoApproveToolPrompts: Bool = false,
        denyUnapprovedToolPrompts: Bool = false
    ) async -> CapabilityClaimsTranscript {
        let resolvedAgentId = agentId ?? AgentManager.shared.activeAgent.id
        let resolvedModel =
            model
            ?? ChatConfigurationStore.load().coreModelIdentifier
            ?? "foundation"
        let engine = ChatEngine()

        var history: [ChatMessage] = [ChatMessage(role: "user", content: query)]
        var toolCalls: [CapabilityClaimsTranscript.ToolInvocation] = []
        var loadedToolNames: [String] = []
        var finalText = ""
        var firstTurnPrompt = ""
        var iterations = 0
        var hitCap = false
        // Empty-turn recovery, mirroring the production driver
        // (`AgentToolLoop.emptyResponse`): a 0-token / EOS-first turn is a
        // recoverable local-model failure mode, not a final answer. The
        // production chat surface nudges-and-retries a bounded number of
        // times before giving up; without the same policy here the eval
        // lane is HARSHER than production and scores a one-off blank turn
        // as an instant empty-final failure.
        var emptyTurnRetries = 0
        var pendingEmptyTurnNotice: String?
        // Decode speed, token-weighted across model steps so a long final
        // answer dominates a 2-token tool-call turn (same weighting as the
        // agent-loop evaluator). Only the no-tool answer step carries an
        // authoritative `tokens_per_second`; tool-call turns report 0 and
        // contribute nothing. Recorded so every generation row has token/s.
        var decodeTpsWeightedSum = 0.0
        var decodeTpsTokenWeight = 0
        var completionTokensTotal = 0
        // Stable per-run session id so the engine's content-addressed KV
        // grouping sees one coherent conversation instead of N anonymous
        // requests.
        let runSessionId = UUID().uuidString

        // Bind the agent for the whole loop so capability-tool scoping,
        // `capabilities_load` agent grants, and agent-scoped tools see
        // the same agent the prompt was composed for.
        let result:
            (
                text: String, calls: [CapabilityClaimsTranscript.ToolInvocation], loaded: [String], iters: Int,
                cap: Bool, prompt: String, err: String?
            )
        do {
            result = try await ChatExecutionContext.$currentAgentId.withValue(resolvedAgentId) {
                // Compose ONCE; prompt + tool schema stay frozen for the
                // whole run (deferred-schema policy, same as production).
                let composed = await SystemPromptComposer.composeChatContext(
                    agentId: resolvedAgentId,
                    executionMode: .none,
                    model: resolvedModel,
                    query: query,
                    messages: history
                )
                firstTurnPrompt = composed.prompt
                let frozenTools = composed.tools

                while iterations < maxIterations {
                    var requestMessages: [ChatMessage] = [
                        ChatMessage(role: "system", content: firstTurnPrompt)
                    ]
                    requestMessages.append(contentsOf: history)
                    if let notice = pendingEmptyTurnNotice {
                        // Same transient-notice contract as the production
                        // loop: the nudge rides once and is not persisted
                        // into `history`, so the transcript stays clean.
                        requestMessages = AgentLoopBudget.appendingTransientNotices(
                            [notice],
                            to: requestMessages
                        )
                        pendingEmptyTurnNotice = nil
                    }

                    let request = ChatCompletionRequest(
                        model: resolvedModel,
                        messages: requestMessages,
                        temperature: 0.0,
                        max_tokens: 2048,
                        stream: false,
                        top_p: nil,
                        frequency_penalty: nil,
                        presence_penalty: nil,
                        stop: nil,
                        n: nil,
                        tools: frozenTools,
                        tool_choice: .auto,
                        session_id: runSessionId
                    )

                    let response = try await engine.completeChat(request: request)
                    // Fold this step's authoritative runtime stats into the
                    // token-weighted decode-speed accumulators.
                    let usage = response.usage
                    if let tps = usage.tokens_per_second, tps > 0, usage.completion_tokens > 0 {
                        decodeTpsWeightedSum += tps * Double(usage.completion_tokens)
                        decodeTpsTokenWeight += usage.completion_tokens
                    }
                    completionTokensTotal += max(0, usage.completion_tokens)
                    guard let choice = response.choices.first else {
                        finalText = ""
                        break
                    }
                    let message = choice.message
                    if let content = message.content, !content.isEmpty {
                        finalText = content
                    }

                    guard let calls = message.tool_calls, !calls.isEmpty else {
                        let visible = (message.content ?? "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if visible.isEmpty, emptyTurnRetries < AgentToolLoop.maxEmptyTurnRetries {
                            // Empty turn (no text, no tool call): nudge and
                            // retry without charging the iteration budget —
                            // production-parity recovery, not coercion (the
                            // model still writes its own answer).
                            emptyTurnRetries += 1
                            pendingEmptyTurnNotice = AgentToolLoop.emptyTurnNotice
                            continue
                        }
                        // Tool-call-free answer → the loop is done.
                        break
                    }
                    emptyTurnRetries = 0

                    iterations += 1

                    // Echo the assistant tool-call turn back into history
                    // so the model sees its own request alongside results.
                    history.append(
                        ChatMessage(
                            role: "assistant",
                            content: message.content,
                            tool_calls: calls,
                            tool_call_id: nil
                        )
                    )

                    for call in calls {
                        toolCalls.append(
                            .init(name: call.function.name, arguments: call.function.arguments)
                        )
                        // Headless harness: there is no [Allow] button, so an
                        // `.ask` tool would otherwise suspend forever on
                        // `ToolPermissionPromptService`. Bind BOTH approval
                        // task-locals so the unstructured task `executeTool`
                        // spawns inherits them (a detached task would not):
                        // `default_agent` passes auto-approve (it measures the
                        // configure surface EXECUTING); `capability_claims`
                        // passes auto-deny (it measures tool SELECTION + honest
                        // claims, and must NOT execute state-mutating configure/
                        // agent writes mid-eval). Production surfaces keep both
                        // `false` and present the real prompt.
                        let toolResult = await ChatExecutionContext.$autoApproveToolPrompts
                            .withValue(autoApproveToolPrompts) {
                                await ChatExecutionContext.$denyUnapprovedToolPrompts
                                    .withValue(denyUnapprovedToolPrompts) {
                                        await executeTool(
                                            name: call.function.name,
                                            argumentsJSON: call.function.arguments,
                                            timeout: toolExecutionTimeout
                                        )
                                    }
                            }
                        history.append(
                            ChatMessage(
                                role: "tool",
                                content: toolResult,
                                tool_calls: nil,
                                tool_call_id: call.id
                            )
                        )
                    }

                    // Drain tools loaded via capabilities_load: record them
                    // on the transcript (and keep the process-wide buffer
                    // clean), but do NOT patch the frozen schema — they are
                    // already callable by name through the registry.
                    let drained = await CapabilityLoadBuffer.shared.drain()
                    for spec in drained {
                        let name = spec.function.name
                        if !loadedToolNames.contains(name) {
                            loadedToolNames.append(name)
                        }
                    }
                }
                if iterations >= maxIterations { hitCap = true }
                if hitCap {
                    // Production parity (ChatView): a cap-hit run gets ONE
                    // final tool-free request so the user still sees a
                    // wrap-up answer. Score what production shows, not the
                    // empty string the loop was cut off with.
                    let wrapUpRequest = ChatCompletionRequest(
                        model: resolvedModel,
                        messages: [ChatMessage(role: "system", content: firstTurnPrompt)] + history,
                        temperature: 0.0,
                        max_tokens: 2048,
                        stream: false,
                        top_p: nil,
                        frequency_penalty: nil,
                        presence_penalty: nil,
                        stop: nil,
                        n: nil,
                        tools: nil,
                        tool_choice: nil,
                        session_id: runSessionId
                    )
                    // Same non-streaming call shape as this evaluator's own
                    // loop steps. A wrap-up failure must not sink the whole
                    // case (the loop itself succeeded) — but it must be
                    // visible, so it lands in the transcript's finalText
                    // rather than being silently swallowed.
                    do {
                        let response = try await engine.completeChat(request: wrapUpRequest)
                        let usage = response.usage
                        if let tps = usage.tokens_per_second, tps > 0, usage.completion_tokens > 0 {
                            decodeTpsWeightedSum += tps * Double(usage.completion_tokens)
                            decodeTpsTokenWeight += usage.completion_tokens
                        }
                        completionTokensTotal += max(0, usage.completion_tokens)
                        let text = (response.choices.first?.message.content ?? "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty { finalText = text }
                    } catch {
                        finalText = "[post-cap wrap-up failed: \(error)]"
                    }
                }
                return (finalText, toolCalls, loadedToolNames, iterations, hitCap, firstTurnPrompt, nil)
            }
        } catch {
            return CapabilityClaimsTranscript(
                toolCalls: toolCalls,
                finalText: "",
                iterations: iterations,
                hitIterationCap: false,
                systemPrompt: firstTurnPrompt,
                loadedToolNames: loadedToolNames,
                error: error.localizedDescription,
                decodeTokensPerSecond: decodeTpsTokenWeight > 0
                    ? decodeTpsWeightedSum / Double(decodeTpsTokenWeight)
                    : nil,
                completionTokens: completionTokensTotal > 0 ? completionTokensTotal : nil
            )
        }

        return CapabilityClaimsTranscript(
            toolCalls: result.calls,
            finalText: result.text,
            iterations: result.iters,
            hitIterationCap: result.cap,
            systemPrompt: result.prompt,
            loadedToolNames: result.loaded,
            error: result.err,
            decodeTokensPerSecond: decodeTpsTokenWeight > 0
                ? decodeTpsWeightedSum / Double(decodeTpsTokenWeight)
                : nil,
            completionTokens: completionTokensTotal > 0 ? completionTokensTotal : nil
        )
    }

    /// Execute one tool call through `ToolRegistry`, optionally bounding it
    /// with a wall-clock `timeout`.
    ///
    /// The `default_agent` lane drives REAL configure tools, a few of which
    /// reach live services (the Hugging Face metadata probe behind
    /// `osaurus_model` download, the plugin registry, an MCP connect). With
    /// no network — or a slow one — those awaits can stall the whole suite.
    /// The tool CALL is already recorded on the transcript BEFORE this runs,
    /// so the deterministic `argsMustContain` / `mustCallTools` checks score
    /// the model's selection regardless of how execution resolves; bounding
    /// execution only protects multi-turn liveness. On timeout we feed the
    /// model a typed `executionError` envelope (mirroring a real tool
    /// failure) so the loop continues instead of hanging. `capability_claims`
    /// passes `nil` and keeps the original unbounded behavior.
    private static func executeTool(
        name: String,
        argumentsJSON: String,
        timeout: TimeInterval?
    ) async -> String {
        func runOnce() async -> String {
            do {
                return try await ToolRegistry.shared.execute(
                    name: name,
                    argumentsJSON: argumentsJSON
                )
            } catch {
                return ToolEnvelope.failure(
                    kind: .unavailable,
                    message: "Tool execution failed: \(error.localizedDescription)",
                    tool: name
                )
            }
        }

        guard let timeout, timeout > 0 else {
            return await runOnce()
        }

        let timedOutMarker = "\u{0}__osaurus_eval_tool_timeout__"

        // `withTaskGroup` is the wrong tool here: structured concurrency awaits
        // EVERY child before the group returns, and `cancelAll()` only *signals*
        // cancellation. A tool stuck on a non-cancellable suspension (a UI
        // continuation, a network read with no deadline) ignores the signal, so
        // the group — and the whole eval — hangs even after the timeout fires.
        // Instead, run the work in an UNSTRUCTURED `Task` (which still inherits
        // our task-locals, including the `.ask` auto-approve) and race it against
        // a timer via a resume-once latch. On timeout we resume with the marker
        // and ABANDON the work task; it may keep running in the background until
        // it finishes or the process exits, but it can never wedge the loop.
        let latch = SingleResume<String>()
        let work = Task { latch.resume(await runOnce()) }
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            latch.resume(timedOutMarker)
        }
        let result = await latch.value
        timer.cancel()
        if result == timedOutMarker {
            // Best-effort: ask the abandoned work to stop; it may not honor it.
            work.cancel()
            return ToolEnvelope.failure(
                kind: .executionError,
                message:
                    "Tool `\(name)` did not return within \(Int(timeout))s and was abandoned by the "
                    + "eval harness (likely a live-service call). The tool call itself was recorded.",
                tool: name,
                retryable: false
            )
        }
        return result
    }

    /// Grade `finalText` against each rubric `condition` with a single
    /// LLM-judge call. Returns one verdict per condition (same order).
    /// Falls back to a `pass: false` verdict carrying the error when the
    /// judge model can't be reached or returns unparseable output — a
    /// case should never silently pass because the judge broke.
    ///
    /// `model` defaults to the run model; pass a stronger judge model
    /// (the runner threads `JUDGE_MODEL`) when grading small-model output.
    public static func judge(
        finalText: String,
        conditions: [String],
        model: String? = nil
    ) async -> [CapabilityClaimsJudgement] {
        await judgeDetailed(finalText: finalText, conditions: conditions, model: model).verdicts
    }

    /// `judge` plus the audit trail (raw judge reply, resolved judge model,
    /// attempt count). Same grading semantics — `judge` delegates here.
    public static func judgeDetailed(
        finalText: String,
        conditions: [String],
        model: String? = nil
    ) async -> CapabilityClaimsJudgeAudit {
        guard !conditions.isEmpty else {
            return CapabilityClaimsJudgeAudit(
                verdicts: [],
                judgeModelId: model ?? "",
                raw: nil,
                attempts: 0
            )
        }
        let resolvedModel =
            model
            ?? ChatConfigurationStore.load().coreModelIdentifier
            ?? "foundation"
        let engine = ChatEngine()

        let numbered = conditions.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")
        let judgeSystem = """
            You are a strict evaluator. You are given an assistant's final \
            reply and a numbered list of conditions. For each condition, \
            decide whether the reply satisfies it. Judge ONLY the reply text \
            against each condition; do not invent requirements.

            Respond with ONLY a JSON object of this exact shape, no prose:
            {"verdicts": [{"pass": true, "reason": "<short>"}, ...]}
            One verdict per condition, in order.
            """
        let judgeUser = """
            Assistant reply:
            \"\"\"
            \(finalText)
            \"\"\"

            Conditions:
            \(numbered)
            """

        let request = ChatCompletionRequest(
            model: resolvedModel,
            messages: [
                ChatMessage(role: "system", content: judgeSystem),
                ChatMessage(role: "user", content: judgeUser),
            ],
            temperature: 0.0,
            max_tokens: 1024,
            stream: false,
            top_p: nil,
            frequency_penalty: nil,
            presence_penalty: nil,
            stop: nil,
            n: nil,
            tools: nil,
            tool_choice: nil,
            session_id: nil
        )

        // One bounded retry ladder on a THROWN judge call. A remote judge
        // (xAI / Gemini) occasionally drops a request mid-flight — a matrix run
        // surfaced a transient `CancellationError` from the provider's own
        // timeout (NOT our task being cancelled) that zeroed an entire case's
        // rubric even though every deterministic matcher passed. Retrying a
        // temperature-0 judge is idempotent and safe, and a flaky judge call
        // must never masquerade as a real model failure (it would pollute a
        // pre/post fix diff). We only retry a THROWN error; an unparseable reply
        // is deterministic at temperature 0, so we return it immediately rather
        // than burning retries. We also honor genuine task cancellation
        // (`Task.isCancelled`) so a killed run still stops promptly instead of
        // looping on its own teardown.
        let maxJudgeAttempts = 3
        var lastError: Error?
        var attemptsUsed = 0
        for attempt in 1 ... maxJudgeAttempts {
            attemptsUsed = attempt
            do {
                let response = try await engine.completeChat(request: request)
                let raw = response.choices.first?.message.content ?? ""
                if let parsed = parseVerdicts(raw, expected: conditions.count) {
                    return CapabilityClaimsJudgeAudit(
                        verdicts: parsed,
                        judgeModelId: resolvedModel,
                        raw: raw,
                        attempts: attempt
                    )
                }
                return CapabilityClaimsJudgeAudit(
                    verdicts: conditions.map {
                        CapabilityClaimsJudgement(
                            pass: false,
                            reason: "judge output not parseable for condition: \($0)"
                        )
                    },
                    judgeModelId: resolvedModel,
                    raw: raw,
                    attempts: attempt
                )
            } catch {
                lastError = error
                if Task.isCancelled { break }
                if attempt < maxJudgeAttempts {
                    // Linear backoff (0.5s, 1.0s) before the next attempt.
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
                }
            }
        }
        return CapabilityClaimsJudgeAudit(
            verdicts: conditions.map { _ in
                CapabilityClaimsJudgement(
                    pass: false,
                    reason: "judge call failed: \(lastError?.localizedDescription ?? "unknown error")"
                )
            },
            judgeModelId: resolvedModel,
            raw: nil,
            attempts: attemptsUsed
        )
    }

    // MARK: - Judge-output parsing (hardened, self-judge friendly)

    /// Extract per-condition verdicts from possibly chatty judge output.
    ///
    /// Small self-judging models rarely emit the exact
    /// `{"verdicts":[...]}` envelope: they wrap it in prose, fence it in
    /// ```json blocks, return a bare array, put `}` inside a `reason`
    /// string, or grade only some of the conditions. The old parser
    /// brace-counted the first `{...}` and blanket-failed the whole case
    /// on any mismatch, so one stray brace or a short reply zeroed grades
    /// the judge actually produced. This ladder degrades instead:
    ///   1. Collect ALL balanced JSON fragments (`{...}` and `[...]`),
    ///      string-aware so braces inside a `reason` and code fences are
    ///      ignored.
    ///   2. Decode each as an envelope, a bare verdict array, or a single
    ///      verdict object, tolerating boolean-ish values ("yes"/1/"pass").
    ///   3. Prefer the fragment whose verdict count == `expected`, else the
    ///      one with the most verdicts (closest to a full grade).
    ///   4. Index-align to `expected`: extra verdicts are dropped; missing
    ///      ones become an explicit "not graded" fail, so a judge that
    ///      returned 2 of 3 verdicts only zeroes the one it skipped.
    /// Returns nil only when no fragment yields a single usable verdict.
    nonisolated static func parseVerdicts(
        _ raw: String,
        expected: Int
    ) -> [CapabilityClaimsJudgement]? {
        guard expected > 0 else { return [] }
        var best: [RawVerdict]?
        for fragment in balancedJSONFragments(in: raw) {
            guard let verdicts = decodeVerdicts(fragment), !verdicts.isEmpty else { continue }
            if verdicts.count == expected {
                best = verdicts
                break
            }
            if best == nil || verdicts.count > (best?.count ?? 0) {
                best = verdicts
            }
        }
        guard let resolved = best else { return nil }
        return alignVerdicts(resolved, to: expected)
    }

    /// Tolerant intermediate verdict (post-decode, pre-alignment).
    private struct RawVerdict {
        let pass: Bool
        let reason: String
    }

    /// Decode one JSON fragment into raw verdicts, accepting the
    /// `{"verdicts":[...]}` envelope, a bare `[...]` array, or a single
    /// `{"pass":...}` object.
    nonisolated private static func decodeVerdicts(_ fragment: String) -> [RawVerdict]? {
        guard let data = fragment.data(using: .utf8) else { return nil }
        struct WireVerdict: Decodable {
            let pass: BoolLike
            let reason: String?
        }
        struct Envelope: Decodable { let verdicts: [WireVerdict] }

        let decoder = JSONDecoder()
        let map: (WireVerdict) -> RawVerdict = { RawVerdict(pass: $0.pass.value, reason: $0.reason ?? "") }

        if let env = try? decoder.decode(Envelope.self, from: data), !env.verdicts.isEmpty {
            return env.verdicts.map(map)
        }
        if let arr = try? decoder.decode([WireVerdict].self, from: data), !arr.isEmpty {
            return arr.map(map)
        }
        if let single = try? decoder.decode(WireVerdict.self, from: data) {
            return [map(single)]
        }
        return nil
    }

    /// Tolerant boolean for the `pass` field: accepts JSON booleans,
    /// 0/1 integers, and common string spellings ("true"/"pass"/"yes").
    /// Anything else is treated as a fail rather than throwing.
    private struct BoolLike: Decodable {
        let value: Bool
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let bool = try? container.decode(Bool.self) {
                value = bool
            } else if let int = try? container.decode(Int.self) {
                value = int != 0
            } else if let string = try? container.decode(String.self) {
                switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "true", "pass", "passed", "yes", "y", "1": value = true
                default: value = false
                }
            } else {
                value = false
            }
        }
    }

    /// Index-align decoded verdicts to the expected condition count: drop
    /// extras, and mark any shortfall as an explicit ungraded fail.
    nonisolated private static func alignVerdicts(
        _ verdicts: [RawVerdict],
        to expected: Int
    ) -> [CapabilityClaimsJudgement] {
        (0 ..< expected).map { index in
            if index < verdicts.count {
                return CapabilityClaimsJudgement(
                    pass: verdicts[index].pass,
                    reason: verdicts[index].reason
                )
            }
            return CapabilityClaimsJudgement(
                pass: false,
                reason:
                    "judge returned \(verdicts.count) of \(expected) verdicts; "
                    + "condition \(index + 1) not graded"
            )
        }
    }

    /// Every balanced top-level JSON fragment (`{...}` or `[...]`) in
    /// `text`, in order. String-aware: braces/brackets and escaped quotes
    /// inside a JSON string literal are ignored, so a `reason` containing
    /// `}` or a fenced ```json block doesn't corrupt matching.
    nonisolated private static func balancedJSONFragments(in text: String) -> [String] {
        var fragments: [String] = []
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            guard character == "{" || character == "[" else {
                index += 1
                continue
            }
            if let end = matchedCloseIndex(characters, from: index) {
                fragments.append(String(characters[index ... end]))
                index = end + 1
            } else {
                index += 1
            }
        }
        return fragments
    }

    /// Index of the balanced closer for the opener at `start`, or nil if
    /// the structure never closes. Tracks string state so quoted braces
    /// don't move the depth counter.
    nonisolated private static func matchedCloseIndex(
        _ characters: [Character],
        from start: Int
    ) -> Int? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < characters.count {
            let character = characters[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else {
                switch character {
                case "\"": inString = true
                case "{", "[": depth += 1
                case "}", "]":
                    depth -= 1
                    if depth == 0 { return index }
                default: break
                }
            }
            index += 1
        }
        return nil
    }
}

// MARK: - One-shot async latch

/// A thread-safe, resume-once async value used to race a tool execution
/// against a timeout without the structured-concurrency "await all
/// children" trap. The first `resume(_:)` wins; later calls are no-ops, so
/// whichever of the work task or the timer fires first decides the result
/// and the loser is simply abandoned. `value` suspends until the first
/// resume (or returns immediately if it already happened).
final class SingleResume<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private var stored: T?
    private var continuation: CheckedContinuation<T, Never>?

    var value: T {
        get async {
            await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
                lock.lock()
                if let stored {
                    lock.unlock()
                    cont.resume(returning: stored)
                } else {
                    continuation = cont
                    lock.unlock()
                }
            }
        }
    }

    func resume(_ value: T) {
        lock.lock()
        if resumed {
            lock.unlock()
            return
        }
        resumed = true
        if let cont = continuation {
            continuation = nil
            lock.unlock()
            cont.resume(returning: value)
        } else {
            stored = value
            lock.unlock()
        }
    }
}
