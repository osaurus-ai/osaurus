//
//  AgentToolLoop.swift
//  osaurus
//
//  The canonical agent tool-loop driver: stream → collect tool calls →
//  dedupe → execute batch → record → repeat. Extracted from the three
//  hand-rolled copies in `ChatSession.send`, `HTTPHandler.handleAgentRunEndpoint`,
//  and `PluginHostAPI.complete`/`completeStream` so loop policy (iteration
//  budgets, dedupe replay, next-step bias, budget warnings, compaction,
//  parallel batches) lands once instead of three times.
//
//  Division of labor:
//
//  - The DRIVER owns the loop skeleton and everything policy-shaped:
//    iteration counting, the iteration-budget warning notice, the
//    consecutive-identical dedupe short-circuit (via `AgentTaskState`),
//    recording outcomes into the state machine, staging the next-step
//    bias notice, and the stop conditions (final response, cancellation,
//    surface-directed end, rejection policy, iteration cap).
//
//  - The SURFACE (chat UI, HTTP SSE, plugin host) owns everything it is
//    the source of truth for: building the message array from its own
//    history store, performing the model step (streaming, delta routing,
//    transient-retry classification), executing a tool call (approvals,
//    TaskLocal scoping, intercepts), and appending outcomes back into its
//    history. These arrive as async closures on `AgentLoopHooks`.
//
//  The driver never spawns tasks of its own (the serial executor runs in
//  the caller's task), so hooks may be actor-isolated closures — Swift
//  hops on each call. `ChatSession` passes `@MainActor` closures; the
//  HTTP and plugin surfaces pass nonisolated ones.
//

import Foundation

// MARK: - Policy

/// Loop-level knobs where the three surfaces deliberately diverge today.
struct AgentLoopPolicy: Sendable {
    /// Maximum number of model iterations (each potentially carrying a
    /// batch of tool calls) before the loop exits with `.iterationCapReached`.
    var maxIterations: Int

    /// When the remaining iteration budget drops to this value or below,
    /// the driver stages a `[System Notice]` warning for the next
    /// iteration so the model can wrap up instead of being cut off.
    var budgetWarningThreshold: Int = 3

    /// Chat stops the whole run when a tool call is rejected/fails
    /// (`true`); HTTP and plugin surfaces hand the model the error
    /// envelope and keep looping (`false`).
    var stopOnToolRejection: Bool

    /// Chat stages a "you already retrieved this exact result" notice when
    /// a dedupe short-circuit replays a held envelope; the headless
    /// surfaces historically don't.
    var dedupeNoticeEnabled: Bool

    init(
        maxIterations: Int,
        budgetWarningThreshold: Int = 3,
        stopOnToolRejection: Bool,
        dedupeNoticeEnabled: Bool
    ) {
        self.maxIterations = max(1, maxIterations)
        self.budgetWarningThreshold = budgetWarningThreshold
        self.stopOnToolRejection = stopOnToolRejection
        self.dedupeNoticeEnabled = dedupeNoticeEnabled
    }
}

// MARK: - Step + execution results

/// What one model step produced, as classified by the surface.
enum AgentLoopModelStep {
    /// The stream/completion finished with plain text — the run is done.
    case finalResponse
    /// The model emitted one or more tool calls to execute this iteration.
    case toolCalls([ServiceToolInvocation])
    /// The surface absorbed a transient failure (e.g. provider truncation
    /// mid-tool-args) and wants the same iteration replayed without
    /// charging the iteration budget.
    case retryWithoutCharge
}

/// Result of the surface executing a single tool call. The surface has
/// already appended whatever history it needs (turns / messages) before
/// returning; the driver only records into `AgentTaskState` and applies
/// stop policy.
struct AgentLoopToolExecution {
    /// The exact result envelope handed to the model.
    var result: String
    /// True when the result is an error/rejection envelope. Drives
    /// `AgentLoopPolicy.stopOnToolRejection`.
    var isError: Bool = false
    /// True when a surface intercept (chat's `complete` / `clarify`)
    /// ended the run. The driver returns `.endedBySurface` without
    /// recording this call into the task state, matching the historical
    /// chat behavior where intercepts break out before recording.
    var endRun: Bool = false
}

/// One processed tool call (executed or replayed), in original model
/// order. Handed to `onBatchComplete` so surfaces that append history
/// per-batch (HTTP) can frame assistant `tool_calls` + tool results.
struct AgentLoopToolOutcome {
    let invocation: ServiceToolInvocation
    let callId: String
    let result: String
    let wasDeduped: Bool
    let wasError: Bool
}

// MARK: - Hooks

/// Surface-specific behavior, injected as async closures. All closures
/// are async so actor-isolated implementations (chat's `@MainActor`
/// session methods) convert cleanly.
struct AgentLoopHooks {
    /// Cheap cancellation probe, checked at iteration boundaries and
    /// between tool calls. Return true to end the run with `.cancelled`.
    var isCancelled: () async -> Bool

    /// Build the full message array for the next model step from the
    /// surface's history store. `notices` carries driver-staged
    /// `[System Notice]` lines (budget warning first, then state notice)
    /// for this iteration; the surface decides placement and persistence
    /// (chat appends transiently, HTTP/plugin persist into their arrays).
    var buildMessages: (_ notices: [String]) async -> [ChatMessage]

    /// Perform one model step (request build + stream/complete + delta
    /// routing) and classify the outcome. Thrown errors abort the run and
    /// propagate to the caller of `run` (chat's catch blocks live there).
    var modelStep: (_ messages: [ChatMessage], _ iteration: Int) async throws -> AgentLoopModelStep

    /// Called for every parsed invocation before the dedupe check, so the
    /// chat surface can materialise its tool-call row (and UI timers)
    /// regardless of whether the call short-circuits. Headless surfaces
    /// no-op.
    var willProcessCall: (_ invocation: ServiceToolInvocation, _ callId: String) async -> Void

    /// A dedupe short-circuit replayed `heldResult` instead of executing.
    /// The surface appends the replayed envelope to its history exactly
    /// as if the tool had run.
    var onDedupedResult: (_ invocation: ServiceToolInvocation, _ callId: String, _ heldResult: String) async -> Void

    /// Execute one tool call and append the outcome to the surface's
    /// history. Must not throw — surfaces convert failures to error
    /// envelopes (`ToolEnvelope.fromError`) and flag `isError`.
    var executeTool: (_ invocation: ServiceToolInvocation, _ callId: String) async -> AgentLoopToolExecution

    /// Optional whole-batch executor for the non-deduped calls of one
    /// iteration. When set, the driver switches to slotting mode: it runs
    /// the dedupe pass over the full batch first, hands the remaining
    /// calls to this executor in model order (the executor may run them
    /// in parallel but must return results in input order), then records
    /// every outcome — held replays included — in model order. This is
    /// the HTTP `/agents/{id}/run` semantic. When nil, the driver
    /// executes serially via `executeTool` with interleaved dedupe.
    var executeBatch:
        ((_ calls: [(invocation: ServiceToolInvocation, callId: String)]) async -> [AgentLoopToolExecution])?

    /// Called after a full batch is processed (not on early stop), with
    /// outcomes in original model order. HTTP appends its assistant
    /// `tool_calls` message + tool results here; chat no-ops (it appends
    /// per-call).
    var onBatchComplete: (_ outcomes: [AgentLoopToolOutcome]) async -> Void

    init(
        isCancelled: @escaping () async -> Bool = { false },
        buildMessages: @escaping (_ notices: [String]) async -> [ChatMessage],
        modelStep: @escaping (_ messages: [ChatMessage], _ iteration: Int) async throws -> AgentLoopModelStep,
        willProcessCall: @escaping (_ invocation: ServiceToolInvocation, _ callId: String) async -> Void = { _, _ in },
        onDedupedResult:
            @escaping (_ invocation: ServiceToolInvocation, _ callId: String, _ heldResult: String) async -> Void = {
                _,
                _,
                _ in
            },
        executeTool: @escaping (_ invocation: ServiceToolInvocation, _ callId: String) async -> AgentLoopToolExecution,
        executeBatch: (
            (_ calls: [(invocation: ServiceToolInvocation, callId: String)]) async -> [AgentLoopToolExecution]
        )? = nil,
        onBatchComplete: @escaping (_ outcomes: [AgentLoopToolOutcome]) async -> Void = { _ in }
    ) {
        self.isCancelled = isCancelled
        self.buildMessages = buildMessages
        self.modelStep = modelStep
        self.willProcessCall = willProcessCall
        self.onDedupedResult = onDedupedResult
        self.executeTool = executeTool
        self.executeBatch = executeBatch
        self.onBatchComplete = onBatchComplete
    }
}

// MARK: - Shared window resolution + budget construction

/// Canonical context-window resolution and `ContextBudgetManager`
/// construction for every loop surface. Historically only the plugin host
/// had this (its `createBudgetManager`); chat and HTTP sent untrimmed
/// histories until they overflowed the model window. Hoisted next to the
/// loop so all three surfaces share one definition of "how big is the
/// window and what's reserved".
enum AgentLoopBudget {

    /// Model ids that route to the Apple Foundation model, whose context
    /// window is fixed and not described by any `ModelInfo` bundle.
    static let foundationModelIds: Set<String> = ["foundation", "default"]

    /// The Apple Foundation model's usable context window (~4K tokens).
    static let foundationContextWindow = 4_096

    /// Fallback window when neither the model bundle nor the user config
    /// declares one.
    static let fallbackContextWindow = 128_000

    /// Canonical response (`max_tokens`) reservation when the request
    /// doesn't specify one — matches what the plugin host always reserved.
    static let defaultResponseReservation = 4_096

    /// Resolve the model's usable context window: Foundation ids first
    /// (fixed window), then model bundle metadata (`ModelInfo.contextLength`),
    /// then the user-configured chat fallback. This is THE definition of
    /// "how big is the window" — the UI uses `resolveContextWindowSync`,
    /// which must stay behavior-identical.
    static func resolveContextWindow(modelId: String) async -> Int {
        if foundationModelIds.contains(modelId) { return foundationContextWindow }
        if let info = ModelInfo.load(modelId: modelId), let ctx = info.model.contextLength {
            return ctx
        }
        return await MainActor.run { ChatConfigurationStore.load().contextLength ?? fallbackContextWindow }
    }

    /// MainActor-synchronous twin of `resolveContextWindow` for SwiftUI
    /// computed properties (the context chip and send gate). Same
    /// resolution order, same values.
    @MainActor
    static func resolveContextWindowSync(modelId: String) -> Int {
        if foundationModelIds.contains(modelId) { return foundationContextWindow }
        if let info = ModelInfo.load(modelId: modelId), let ctx = info.model.contextLength {
            return ctx
        }
        return ChatConfigurationStore.load().contextLength ?? fallbackContextWindow
    }

    // MARK: Shared budget assessment (UI + runtime parity)

    /// One shared answer to "how full is the context and is the send
    /// doomed", derived the same way the runtime trims: against the
    /// EFFECTIVE budget (window × safety margin), not the raw window.
    struct Assessment: Equatable, Sendable {
        /// Estimated next-send tokens over the effective budget; nil when
        /// the breakdown is empty.
        var usageRatio: Double?
        /// Soft warning: usage at or beyond `nearLimitThreshold` of the
        /// effective budget. Sends still go through — compaction handles
        /// history growth — but quality may degrade.
        var nearLimit: Bool
        /// The NON-compactable prefix (system prompt, tools, memory,
        /// input — everything except conversation history and generated
        /// output, which compaction can trim) plus the response
        /// reservation exceeds the effective budget. Such a request fails
        /// no matter how much history is compacted.
        var hardOverflow: Bool

        static let empty = Assessment(usageRatio: nil, nearLimit: false, hardOverflow: false)
    }

    /// Breakdown entry ids that history compaction can trim away. The
    /// generated-output entry is conversation history from the next
    /// request's point of view; "compacted" is the saved-tokens display
    /// entry, not real cost.
    private static let compactableEntryIds: Set<String> = ["conversation", "output", "compacted"]

    /// Assess a composed breakdown against a model window. The response
    /// reservation's contribution to the hard gate is capped at a quarter
    /// of the effective budget so small-window models (Foundation ~4K)
    /// aren't permanently gated by a reservation larger than their whole
    /// window — the runtime truncates generation in that case rather than
    /// failing the request.
    static func assess(
        breakdown: ContextBreakdown,
        contextWindow: Int,
        maxResponseTokens: Int? = nil,
        nearLimitThreshold: Double = 0.85
    ) -> Assessment {
        guard contextWindow > 0 else { return .empty }
        let effective = ContextBudgetManager(contextLength: contextWindow).effectiveBudget
        guard effective > 0 else { return .empty }

        let total = breakdown.total
        let ratio: Double? = total > 0 ? Double(total) / Double(effective) : nil

        let compactable = breakdown.messages
            .filter { compactableEntryIds.contains($0.id) }
            .reduce(0) { $0 + $1.tokens }
        let reservation = min(
            maxResponseTokens ?? defaultResponseReservation,
            max(0, effective / 4)
        )
        let nonCompactable = max(0, total - compactable) + reservation

        return Assessment(
            usageRatio: ratio,
            nearLimit: (ratio ?? 0) >= nearLimitThreshold,
            hardOverflow: nonCompactable > effective
        )
    }

    /// Build a `ContextBudgetManager` with the canonical reservations:
    /// system prompt (by char count), tool schema (tokens), and the
    /// response (`max_tokens`, defaulting to 4096 as the plugin host
    /// always has).
    static func makeBudgetManager(
        contextWindow: Int,
        systemPromptChars: Int,
        toolTokens: Int,
        maxResponseTokens: Int?
    ) -> ContextBudgetManager {
        var mgr = ContextBudgetManager(contextLength: contextWindow)
        mgr.reserveByCharCount(.systemPrompt, characters: systemPromptChars)
        mgr.reserve(.tools, tokens: toolTokens)
        mgr.reserve(.response, tokens: maxResponseTokens ?? 4096)
        return mgr
    }

    /// Trim a full request message array while keeping the system prefix
    /// byte-stable: the leading system message (when present) is excluded
    /// from trimming so the paged-KV system prefix is never rewritten, and
    /// the conversation tail is trimmed against the manager's history
    /// budget (which already reserves the system prompt's tokens).
    /// When a `watermark` is supplied, trimming is sticky (see
    /// `CompactionWatermark`): decisions persist across iterations so the
    /// trimmed tail is monotonic and the token prefix stays byte-stable.
    static func trimPreservingSystemPrefix(
        _ messages: [ChatMessage],
        with manager: ContextBudgetManager,
        watermark: CompactionWatermark? = nil
    ) -> [ChatMessage] {
        trimPreservingSystemPrefixReportingOverflow(
            messages,
            with: manager,
            watermark: watermark
        ).messages
    }

    /// Canonical per-iteration message assembly for every loop surface:
    /// trim FIRST against the history budget (so compaction decisions are
    /// notice-independent and KV-stable), then append the driver-staged
    /// `[System Notice]` lines as TRANSIENT user messages — never persisted
    /// into the surface's history store, so a notice rides exactly one
    /// iteration. The trim budget's safety margin
    /// (`ContextBudgetManager.safetyMargin`, 15% of the window) is the
    /// refit headroom that absorbs the notices' small token cost.
    ///
    /// Chat follows the same contract inline (it interleaves compaction
    /// telemetry and the mid-run token notice between the two steps).
    static func composeIterationMessages(
        _ messages: [ChatMessage],
        notices: [String],
        manager: ContextBudgetManager?,
        watermark: CompactionWatermark? = nil
    ) -> [ChatMessage] {
        var msgs = messages
        if let manager {
            msgs = trimPreservingSystemPrefix(msgs, with: manager, watermark: watermark)
        }
        for notice in notices {
            msgs.append(ChatMessage(role: "user", content: notice))
        }
        return msgs
    }

    /// Like `trimPreservingSystemPrefix`, but also reports whether the
    /// trimmed transcript STILL exceeds the history budget after every
    /// compaction lever is exhausted (protected first message + tail alone
    /// over budget), so surfaces can warn instead of silently overflowing.
    /// The stateless (no-watermark) path reports overflow by re-estimating
    /// the trimmed tail.
    static func trimPreservingSystemPrefixReportingOverflow(
        _ messages: [ChatMessage],
        with manager: ContextBudgetManager,
        watermark: CompactionWatermark? = nil
    ) -> (messages: [ChatMessage], overBudget: Bool) {
        func trim(_ msgs: [ChatMessage]) -> (messages: [ChatMessage], overBudget: Bool) {
            if let watermark {
                return manager.trimMessagesReportingOverflow(msgs, watermark: watermark)
            }
            let trimmed = manager.trimMessages(msgs)
            return (trimmed, ContextBudgetManager.estimateTokens(for: trimmed) > manager.historyBudget)
        }
        guard let first = messages.first, first.role == "system" else {
            return trim(messages)
        }
        let tail = Array(messages.dropFirst())
        let result = trim(tail)
        return ([first] + result.messages, result.overBudget)
    }
}

// MARK: - Driver

enum AgentToolLoop {

    /// How a run ended.
    enum Exit: Equatable, Sendable {
        /// The model produced a final text response (no tool calls).
        case finalResponse
        /// A surface intercept ended the run (chat `complete` / `clarify`).
        case endedBySurface
        /// A tool call failed/was rejected and policy says stop.
        case toolRejected
        /// The iteration budget was exhausted while tools were still being
        /// requested. The surface decides what to do next (chat streams a
        /// tool-free wrap-up call; HTTP emits a synthetic notice).
        case iterationCapReached
        /// `isCancelled` returned true.
        case cancelled
    }

    struct RunResult: Equatable, Sendable {
        var exit: Exit
        /// Iterations charged against the budget (transient retries are
        /// not charged).
        var iterations: Int
    }

    /// The dedupe-replay notice staged when a held result short-circuits
    /// a repeated read (chat surface only, per policy).
    static let dedupeNotice =
        "[System Notice] You already retrieved this exact result this turn and it is unchanged. Use the result you already have instead of repeating the call."

    /// The iteration-budget warning staged when the remaining budget
    /// drops to the policy threshold.
    static func budgetWarningNotice(remaining: Int, maxIterations: Int) -> String {
        "[System Notice] Tool call budget: \(remaining) of \(maxIterations) remaining. Wrap up your current work and provide a summary."
    }

    // MARK: - Default parallel batch executor

    /// Default batch executor: run every call concurrently via a TaskGroup,
    /// then restore the input order so the loop's slotting (and therefore
    /// any SSE framing) matches the model's own tool_call sequence.
    /// Per-call errors are caught and converted to `ToolEnvelope.fromError`
    /// so a single bad call never aborts the rest of the batch. Batches of
    /// one skip the TaskGroup and execute inline (serial fallback).
    ///
    /// Generic over the per-call executor so surfaces with bespoke
    /// execution (plugin host) and tests (scripted executors) can reuse the
    /// ordering/error semantics; `ChatExecutionContext` scoping lives in
    /// the `sessionId:agentId:` convenience below.
    static func runBatchInParallel(
        _ calls: [(invocation: ServiceToolInvocation, callId: String)],
        execute: @escaping @Sendable (_ invocation: ServiceToolInvocation, _ callId: String) async throws -> String
    ) async -> [AgentLoopToolExecution] {
        @Sendable func executeOne(
            _ call: (invocation: ServiceToolInvocation, callId: String)
        ) async -> AgentLoopToolExecution {
            do {
                return AgentLoopToolExecution(result: try await execute(call.invocation, call.callId))
            } catch {
                return AgentLoopToolExecution(
                    result: ToolEnvelope.fromError(error, tool: call.invocation.toolName),
                    isError: true
                )
            }
        }

        // Serial fallback: no TaskGroup overhead for a single call.
        if calls.count == 1, let only = calls.first {
            return [await executeOne(only)]
        }

        let indexed: [(Int, AgentLoopToolExecution)] = await withTaskGroup(
            of: (Int, AgentLoopToolExecution).self
        ) { group in
            for (index, call) in calls.enumerated() {
                group.addTask {
                    (index, await executeOne(call))
                }
            }
            var collected: [(Int, AgentLoopToolExecution)] = []
            collected.reserveCapacity(calls.count)
            for await item in group { collected.append(item) }
            return collected
        }

        return indexed.sorted { $0.0 < $1.0 }.map { $0.1 }
    }

    /// Canonical-registry two-phase batch (the chat surface pioneered the
    /// pattern; headless surfaces share it here):
    ///
    /// - Phase 1 — approvals resolve FIRST, serially and in model order,
    ///   so permission prompts never stack or race. On a denial the
    ///   remaining unstarted calls are skipped with a paired rejection
    ///   envelope (the assistant `tool_use` never dangles).
    /// - Phase 2 — the approved set executes in parallel with the gate
    ///   pre-resolved (`permissionGateResolved: true`), so no prompt can
    ///   pop mid-flight.
    ///
    /// Each phase scopes `ChatExecutionContext` so tools and the gate see
    /// the same session/agent ids they would on a sequential dispatch.
    static func runBatchInParallel(
        _ calls: [(invocation: ServiceToolInvocation, callId: String)],
        sessionId: String,
        agentId: UUID
    ) async -> [AgentLoopToolExecution] {
        // Bind the session/agent task-locals exactly as a sequential
        // registry dispatch would.
        @Sendable func scoped<T: Sendable>(
            _ body: @Sendable () async throws -> T
        ) async throws -> T {
            try await ChatExecutionContext.$currentSessionId.withValue(sessionId) {
                try await ChatExecutionContext.$currentAgentId.withValue(agentId) {
                    try await body()
                }
            }
        }

        var executions = [AgentLoopToolExecution?](repeating: nil, count: calls.count)

        // Phase 1 — approvals, serially in model order.
        var approved: [(slot: Int, invocation: ServiceToolInvocation, callId: String)] = []
        var denied = false
        for (slot, call) in calls.enumerated() {
            if denied {
                executions[slot] = AgentLoopToolExecution(
                    result: ToolEnvelope.failure(
                        kind: .rejected,
                        message:
                            "Skipped: an earlier tool call in this batch was rejected, so this call did not run.",
                        tool: call.invocation.toolName
                    ),
                    isError: false
                )
                continue
            }
            do {
                try await scoped {
                    try await ToolRegistry.shared.resolvePermissionGate(
                        name: call.invocation.toolName,
                        argumentsJSON: call.invocation.jsonArguments
                    )
                }
                approved.append((slot, call.invocation, call.callId))
            } catch {
                executions[slot] = AgentLoopToolExecution(
                    result: ToolEnvelope.fromError(error, tool: call.invocation.toolName),
                    isError: true
                )
                denied = true
            }
        }

        // Phase 2 — approved calls execute in parallel, gate pre-resolved.
        if !approved.isEmpty {
            let approvedCalls = approved.map { ($0.invocation, $0.callId) }
            let results = await runBatchInParallel(approvedCalls) { invocation, _ in
                try await scoped {
                    try await ToolRegistry.shared.execute(
                        name: invocation.toolName,
                        argumentsJSON: invocation.jsonArguments,
                        permissionGateResolved: true
                    )
                }
            }
            for (entry, execution) in zip(approved, results) {
                executions[entry.slot] = execution
            }
        }

        return executions.map { $0 ?? AgentLoopToolExecution(result: "") }
    }

    /// Tools whose successful execution ends the run from INSIDE a batch
    /// (`endRun` intercepts). Batch executors check this to fall back to
    /// serial model-order execution — running siblings in parallel would
    /// let calls AFTER the intercept execute and land in history, where
    /// the serial path stops immediately.
    static let interceptToolNames: Set<String> = ["complete", "clarify"]

    /// Whether a batch carries a loop-ending intercept tool.
    static func containsIntercept(
        _ calls: [(invocation: ServiceToolInvocation, callId: String)]
    ) -> Bool {
        calls.contains { interceptToolNames.contains($0.invocation.toolName) }
    }

    /// Stable call-id assignment: preserve the model-supplied id when
    /// present (OpenAI `call_xxx`), otherwise mint one in the same shape.
    static func callId(for invocation: ServiceToolInvocation) -> String {
        if let preserved = invocation.toolCallId, !preserved.isEmpty {
            return preserved
        }
        let raw = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        return "call_" + String(raw.prefix(24))
    }

    /// Run the canonical loop to completion. Errors thrown by
    /// `hooks.modelStep` propagate to the caller (surface-specific error
    /// handling stays at the call site).
    ///
    /// `isolation` inherits the caller's actor isolation (`#isolation`) so
    /// non-Sendable hooks/state never cross an isolation boundary: chat
    /// drives the loop on the MainActor; HTTP/plugin drive it nonisolated.
    static func run(
        policy: AgentLoopPolicy,
        state: AgentTaskState,
        hooks: AgentLoopHooks,
        isolation: isolated (any Actor)? = #isolation
    ) async throws -> RunResult {
        var iteration = 0
        // Two staged-notice slots, mirroring the historical chat locals
        // (`pendingBudgetNotice` / `pendingStateNotice`). The state slot is
        // overwritten per event so the LAST dedupe/bias in a batch wins,
        // exactly as the per-call overwrite did in `ChatSession.send`.
        var pendingBudgetNotice: String?
        var pendingStateNotice: String?

        while iteration < policy.maxIterations {
            if await hooks.isCancelled() {
                return RunResult(exit: .cancelled, iterations: iteration)
            }
            iteration += 1

            var notices: [String] = []
            if let n = pendingBudgetNotice {
                notices.append(n)
                pendingBudgetNotice = nil
            }
            if let n = pendingStateNotice {
                notices.append(n)
                pendingStateNotice = nil
            }
            let messages = await hooks.buildMessages(notices)

            let step = try await hooks.modelStep(messages, iteration)
            switch step {
            case .finalResponse:
                return RunResult(exit: .finalResponse, iterations: iteration)

            case .retryWithoutCharge:
                // Don't charge the iteration budget. Staged notices were
                // consumed by the failed attempt and are not replayed —
                // matching the historical chat behavior where the pending
                // slots were cleared before the stream error surfaced.
                iteration -= 1
                continue

            case .toolCalls(let invocations):
                var outcomes: [AgentLoopToolOutcome] = []
                outcomes.reserveCapacity(invocations.count)

                if let executeBatch = hooks.executeBatch {
                    // Slotting mode (HTTP semantics): dedupe pass over the
                    // whole batch first, then one batch execution for the
                    // rest — the executor may parallelise but must return
                    // results in input order — then in-order recording.
                    var slotted: [AgentLoopToolOutcome?] = Array(
                        repeating: nil,
                        count: invocations.count
                    )
                    // Slots whose execution ended the run (chat intercepts
                    // `complete`/`clarify` riding through the batch path).
                    var endRunSlots: Set<Int> = []
                    var toExecute: [(slot: Int, invocation: ServiceToolInvocation, callId: String)] = []
                    // Read calls that duplicate an EARLIER sibling in this
                    // same batch. Serial mode would dedupe them (the first
                    // executes and records a fresh read; the second hits
                    // `heldResult`), so they are deferred past the parallel
                    // wave and resolved in the in-order pass below, where
                    // the live state decides replay vs. execute.
                    var deferredDuplicates: [Int: (invocation: ServiceToolInvocation, callId: String)] = [:]
                    var seenSignatures: Set<CallSignature> = []
                    for (slot, invocation) in invocations.enumerated() {
                        let callId = Self.callId(for: invocation)
                        await hooks.willProcessCall(invocation, callId)
                        if let held = state.heldResult(
                            name: invocation.toolName,
                            argsJSON: invocation.jsonArguments
                        ) {
                            await hooks.onDedupedResult(invocation, callId, held)
                            slotted[slot] = AgentLoopToolOutcome(
                                invocation: invocation,
                                callId: callId,
                                result: held,
                                wasDeduped: true,
                                wasError: false
                            )
                            if policy.dedupeNoticeEnabled {
                                pendingStateNotice = Self.dedupeNotice
                            }
                            continue
                        }
                        let signature = CallSignature(
                            name: invocation.toolName,
                            canonicalArgs: AgentTaskState.canonicalArgs(invocation.jsonArguments)
                        )
                        if AgentTaskState.isReplayEligible(name: invocation.toolName),
                            seenSignatures.contains(signature)
                        {
                            deferredDuplicates[slot] = (invocation, callId)
                        } else {
                            seenSignatures.insert(signature)
                            toExecute.append((slot, invocation, callId))
                        }
                    }
                    if !toExecute.isEmpty {
                        let executions = await executeBatch(
                            toExecute.map { ($0.invocation, $0.callId) }
                        )
                        // The executor may legitimately return FEWER results
                        // than calls (chat stops executing the rest of a
                        // batch after an intercept); missing slots stay nil
                        // and are excluded from outcomes/recording, exactly
                        // like serial calls that never ran.
                        for (index, entry) in toExecute.enumerated()
                        where index < executions.count {
                            let execution = executions[index]
                            slotted[entry.slot] = AgentLoopToolOutcome(
                                invocation: entry.invocation,
                                callId: entry.callId,
                                result: execution.result,
                                wasDeduped: false,
                                wasError: execution.isError
                            )
                            if execution.endRun {
                                endRunSlots.insert(entry.slot)
                            }
                        }
                    }
                    // Early-exit helper: the batch's executed outcomes have
                    // already landed in surface history, so `onBatchComplete`
                    // must fire even when the run stops here — otherwise
                    // per-batch surfaces (HTTP) drop the tool rows from
                    // their message arrays. Intercept slots are excluded:
                    // the intercept wrote its own history.
                    func finishBatch(_ exit: Exit) async -> RunResult {
                        let completed = (0 ..< slotted.count).compactMap { slot in
                            endRunSlots.contains(slot) ? nil : slotted[slot]
                        }
                        await hooks.onBatchComplete(completed)
                        return RunResult(exit: exit, iterations: iteration)
                    }
                    // In-order pass: record every outcome — held replays
                    // included — in model order (historical HTTP behavior).
                    // Deferred duplicate reads resolve here against the LIVE
                    // state: once the earlier sibling's read has recorded,
                    // `heldResult` replays it (serial parity); if the
                    // sibling failed, the duplicate executes for real. A
                    // surface intercept ends the run BEFORE its own call is
                    // recorded (matching the serial path); earlier batch
                    // outcomes stay recorded.
                    for slot in 0 ..< slotted.count {
                        if let deferred = deferredDuplicates[slot] {
                            if let held = state.heldResult(
                                name: deferred.invocation.toolName,
                                argsJSON: deferred.invocation.jsonArguments
                            ) {
                                await hooks.onDedupedResult(deferred.invocation, deferred.callId, held)
                                slotted[slot] = AgentLoopToolOutcome(
                                    invocation: deferred.invocation,
                                    callId: deferred.callId,
                                    result: held,
                                    wasDeduped: true,
                                    wasError: false
                                )
                                if policy.dedupeNoticeEnabled {
                                    pendingStateNotice = Self.dedupeNotice
                                }
                            } else if let execution = await executeBatch(
                                [(deferred.invocation, deferred.callId)]
                            ).first {
                                slotted[slot] = AgentLoopToolOutcome(
                                    invocation: deferred.invocation,
                                    callId: deferred.callId,
                                    result: execution.result,
                                    wasDeduped: false,
                                    wasError: execution.isError
                                )
                                if execution.endRun {
                                    endRunSlots.insert(slot)
                                }
                            }
                        }
                        guard let outcome = slotted[slot] else { continue }
                        if endRunSlots.contains(slot) {
                            return await finishBatch(.endedBySurface)
                        }
                        state.record(
                            name: outcome.invocation.toolName,
                            argsJSON: outcome.invocation.jsonArguments,
                            result: outcome.result
                        )
                    }
                    if let bias = state.nextStepBias() {
                        pendingStateNotice = "[System Notice] " + bias
                    }
                    outcomes = slotted.compactMap { $0 }
                    // Cancellation is honored only AFTER the executed batch
                    // is recorded — the surface history already contains
                    // these tool turns, so skipping `state.record` would
                    // desync the state machine from the transcript.
                    if await hooks.isCancelled() {
                        return await finishBatch(.cancelled)
                    }
                    if policy.stopOnToolRejection, outcomes.contains(where: { $0.wasError }) {
                        return await finishBatch(.toolRejected)
                    }
                } else {
                    // Serial mode (chat/plugin semantics): interleaved dedupe
                    // and execution, per-call policy checks.
                    for invocation in invocations {
                        if await hooks.isCancelled() {
                            return RunResult(exit: .cancelled, iterations: iteration)
                        }
                        let callId = Self.callId(for: invocation)
                        await hooks.willProcessCall(invocation, callId)

                        // Consecutive-identical dedupe: replay the EXACT envelope
                        // the model already received instead of re-executing.
                        if let held = state.heldResult(
                            name: invocation.toolName,
                            argsJSON: invocation.jsonArguments
                        ) {
                            await hooks.onDedupedResult(invocation, callId, held)
                            outcomes.append(
                                AgentLoopToolOutcome(
                                    invocation: invocation,
                                    callId: callId,
                                    result: held,
                                    wasDeduped: true,
                                    wasError: false
                                )
                            )
                            if policy.dedupeNoticeEnabled {
                                pendingStateNotice = Self.dedupeNotice
                            }
                            continue
                        }

                        let execution = await hooks.executeTool(invocation, callId)

                        // Surface intercepts (chat `complete`/`clarify`) end the
                        // run before the call is recorded — the intercept already
                        // wrote its own history.
                        if execution.endRun {
                            return RunResult(exit: .endedBySurface, iterations: iteration)
                        }

                        // Record BEFORE honoring cancellation: the surface
                        // already appended this tool turn to its history, so
                        // skipping the record would desync `AgentTaskState`
                        // from the transcript.
                        state.record(
                            name: invocation.toolName,
                            argsJSON: invocation.jsonArguments,
                            result: execution.result
                        )
                        if let bias = state.nextStepBias() {
                            pendingStateNotice = "[System Notice] " + bias
                        }
                        outcomes.append(
                            AgentLoopToolOutcome(
                                invocation: invocation,
                                callId: callId,
                                result: execution.result,
                                wasDeduped: false,
                                wasError: execution.isError
                            )
                        )

                        if await hooks.isCancelled() {
                            return RunResult(exit: .cancelled, iterations: iteration)
                        }
                        if execution.isError, policy.stopOnToolRejection {
                            return RunResult(exit: .toolRejected, iterations: iteration)
                        }
                    }
                }

                await hooks.onBatchComplete(outcomes)

                // Per-iteration budget bookkeeping: one decrement per model
                // step regardless of how many tools the batch ran.
                let remaining = policy.maxIterations - iteration
                if remaining > 0, remaining <= policy.budgetWarningThreshold {
                    pendingBudgetNotice = Self.budgetWarningNotice(
                        remaining: remaining,
                        maxIterations: policy.maxIterations
                    )
                }
            }
        }

        return RunResult(exit: .iterationCapReached, iterations: iteration)
    }
}
