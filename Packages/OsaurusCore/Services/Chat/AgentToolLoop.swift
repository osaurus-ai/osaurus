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

import CryptoKit
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

    /// Iterations without a `todo` call (while unchecked items remain)
    /// before the driver stages the staleness notice. Only consulted when
    /// `AgentLoopHooks.pendingTodoCount` is set. The notice re-arms after
    /// firing, so it nags at most once per threshold window.
    var todoStalenessThreshold: Int = 4

    /// Hard cap on "data-movement" iterations that are refunded instead of
    /// charged against `maxIterations`. An iteration qualifies only when
    /// EVERY tool call in it is a *successful* bulk DB load (`db_import`, or
    /// `db_insert`/`db_upsert` with `rows[]`). 0 disables the relief (the
    /// default, so non-agent surfaces and tests are unaffected). Set > 0 on
    /// agent-run surfaces; it is naturally scoped to DB-enabled agents
    /// because only they can land a successful `db_*` bulk call.
    var maxDataMovementSteps: Int = 0

    /// Chat-only structural fallback for models that ignore the proactive
    /// `todo` guidance. When greater than zero, the Nth ordinary action tool
    /// is not executed until this run has produced a valid Todo. The rejected
    /// call remains model-visible and retryable, so the model can create the
    /// checklist and retry the exact action. Headless surfaces leave this at
    /// zero and retain their existing semantics.
    var todoRequiredBeforeToolCallCount: Int = 0

    init(
        maxIterations: Int,
        budgetWarningThreshold: Int = 3,
        stopOnToolRejection: Bool,
        dedupeNoticeEnabled: Bool,
        todoStalenessThreshold: Int = 4,
        maxDataMovementSteps: Int = 0,
        todoRequiredBeforeToolCallCount: Int = 0
    ) {
        self.maxIterations = max(1, maxIterations)
        self.budgetWarningThreshold = budgetWarningThreshold
        self.stopOnToolRejection = stopOnToolRejection
        self.dedupeNoticeEnabled = dedupeNoticeEnabled
        self.todoStalenessThreshold = max(1, todoStalenessThreshold)
        self.maxDataMovementSteps = max(0, maxDataMovementSteps)
        self.todoRequiredBeforeToolCallCount = max(0, todoRequiredBeforeToolCallCount)
    }
}

// MARK: - Step + execution results

/// The composed message array for one model step, plus whether even a
/// fully-compacted transcript exceeds the history budget. Returned by the
/// `buildMessages` hook so the driver can end the run with `.overBudget`
/// instead of sending a doomed request.
struct AgentLoopIterationInput {
    var messages: [ChatMessage]
    /// True when the protected first message + recent tail ALONE exceed
    /// the history budget after every compaction lever was exhausted.
    var overBudget: Bool = false
}

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
    /// A streamed tool call exceeded the bounded argument buffer before it
    /// became executable. The driver gives the model one typed retry with
    /// chunking guidance instead of decoding an unbounded file payload.
    case oversizedToolCall(toolName: String?, argumentCharacters: Int)
    /// The runtime hit its output-token ceiling after beginning a streamed
    /// tool envelope but before committing an executable invocation. Unlike
    /// ordinary length exhaustion, this is a typed protocol failure and gets
    /// one bounded retry with smaller-call guidance.
    case truncatedToolCall(toolName: String?, argumentCharacters: Int)
    /// The model step produced NO visible text AND no tool calls — an empty
    /// turn (an immediate EOS / 0-token generation). The driver attempts a
    /// bounded recovery (a corrective nudge, then retry) instead of ending
    /// the run silently; on exhaustion it emits a fallback message via
    /// `AgentLoopHooks.emitFallbackText` so the user never sees nothing and
    /// the loop can never spin on a deterministically-empty model.
    case emptyResponse
    /// The runtime reached the configured output-token limit without a tool
    /// call. Visible partial content or reasoning may be present, but the
    /// authoritative terminal reason says generation was incomplete.
    case lengthExhausted
    /// The stream ended after emitting reasoning but no user-visible answer,
    /// or the runtime reported that the reasoning envelope never closed.
    /// Agent runs require a normal final answer after reasoning/tool work, so
    /// an explicitly recovery-capable surface may perform one bounded retry;
    /// other surfaces end with a typed incomplete result instead of presenting
    /// the reasoning card as a completed response.
    case incompleteReasoning
    /// The runtime reported an unclosed reasoning envelope after already
    /// emitting user-visible content. Streaming surfaces cannot retract that
    /// content, so transparently replaying would concatenate two attempts.
    /// End honestly without an automatic retry.
    case incompleteVisibleResponse
    /// The model emitted visible text that ANNOUNCES an imminent tool call
    /// ("Let me write the first batch:") and then stopped without emitting
    /// one, while tools were on the table. Ending here is what makes a small
    /// model look like its tools are silently failing: the user reads a
    /// promise to act, no call runs, and the next turn the model reports the
    /// tool "isn't executing". Recoverable — the driver nudges and retries,
    /// and because the announcement is a preamble rather than an answer, the
    /// retry's tool call reads as the natural continuation of it.
    case announcedToolCall
    /// The stream consumer cut the turn short because the model collapsed
    /// into a phrase-repetition loop. Recoverable once: the repeat is a
    /// decoding failure, not an answer, so ending here would present a wall
    /// of the same sentence as the response.
    case repetitionLoop(phrase: String?)
    /// The turn ended by asking the user for permission to carry on ("would
    /// you like me to continue?") instead of carrying on. Only a stall when
    /// tracked work is still pending — the driver checks that before
    /// recovering, so a genuine question to the user still ends the run.
    /// `clarify` is the tool for real questions; this shape is the model
    /// handing back a turn it was asked to finish.
    case continuationRequest

    /// Classify a naturally completed model step from its rendered channels
    /// and authoritative terminal stop reason.
    ///
    /// A reasoning-only natural `stop` is not a complete agent response. The
    /// reasoning rail is visible diagnostic work, while the user-facing answer
    /// belongs in content. This distinction matters after tools: a reported
    /// 29K-character Gemma thought block had no answer, but its saved artifact
    /// lacked terminal provenance, so this classifier relies on live stop and
    /// envelope state rather than inferring completion from reasoning alone.
    /// - Parameter toolsWereOffered: whether the model could have called
    ///   something on this step. A reasoning-only stop is a legitimate finish
    ///   for a bundle that returns on its reasoning rail with nothing to call,
    ///   but when tools were on the table and the model produced neither an
    ///   answer nor a call, the user is left with a thought bubble and no way
    ///   forward — see osaurus#2327, where Ornith reasons "I have a tool called
    ///   get_current_time… Let me call it." and then emits `<|im_end|>`.
    ///   `requiresVisibleFinalResponse` cannot cover that case: it is
    ///   `hasStructuredToolWork || isRemoteAgentTarget`, both false on the very
    ///   first turn, which is exactly when this happens.
    /// - Parameter content: the rendered visible content, used only to tell an
    ///   answer apart from a bare announcement of an un-made tool call. Pass
    ///   `nil` from surfaces that cannot cheaply materialise it; the
    ///   announce-only recovery is then skipped and behaviour is unchanged.
    static func classifyTerminal(
        contentIsBlank: Bool,
        thinkingIsBlank: Bool,
        stopReason: String?,
        unclosedReasoning: Bool = false,
        requiresVisibleFinalResponse: Bool,
        toolsWereOffered: Bool = false,
        content: String? = nil,
        repetitionLoopPhrase: String? = nil
    ) -> Self {
        // Checked before `stopReason`: the consumer stopped reading, so the
        // reported terminal reason describes a stream nobody finished. A
        // repeated sentence is never a usable answer regardless of how the
        // generation would otherwise have ended.
        if let repetitionLoopPhrase {
            return .repetitionLoop(phrase: repetitionLoopPhrase.isEmpty ? nil : repetitionLoopPhrase)
        }
        if stopReason == "length" {
            return .lengthExhausted
        }
        if requiresVisibleFinalResponse
            && unclosedReasoning && !contentIsBlank
        {
            return .incompleteVisibleResponse
        }
        if requiresVisibleFinalResponse
            && (unclosedReasoning || (contentIsBlank && !thinkingIsBlank))
        {
            return .incompleteReasoning
        }
        if contentIsBlank, thinkingIsBlank {
            return .emptyResponse
        }
        // Reasoning, no answer, no call — with tools available. Recoverable
        // rather than complete: ending here presents the reasoning card as the
        // response, which the classifier's own contract says it is not.
        if contentIsBlank, toolsWereOffered {
            return .incompleteReasoning
        }
        // Visible text, no call, tools available — check whether that text is
        // an answer, a request to be allowed to carry on, or only a preamble
        // to a call the model never emitted.
        if toolsWereOffered, let content {
            if isContinuationRequest(content) { return .continuationRequest }
            if isAnnounceOnly(content) { return .announcedToolCall }
        }
        return .finalResponse
    }

    /// Whether visible content ends by asking permission to keep going.
    ///
    /// Matches only the closing line, and only an explicit ask about
    /// CONTINUING — not questions in general. A model that asks something
    /// substantive ("which version of the toolkit do you mean?") is doing the
    /// right thing and must still end the turn.
    static func isContinuationRequest(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix("?") else { return false }
        guard trimmed.components(separatedBy: "```").count % 2 == 1 else { return false }

        let lines = trimmed.split(whereSeparator: \.isNewline)
        guard let last = lines.last?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        else { return false }
        return Self.continuationRequestPhrases.contains { last.contains($0) }
    }

    /// Ways a model asks to be let off the hook mid-task. Lowercased,
    /// matched anywhere in the closing line.
    private static let continuationRequestPhrases: [String] = [
        "would you like me to continue", "want me to continue", "shall i continue",
        "should i continue", "do you want me to continue", "shall i proceed",
        "should i proceed", "would you like me to proceed", "want me to proceed",
        "shall i keep going", "should i keep going", "want me to keep going",
        "would you like me to keep going", "ok to continue", "okay to continue",
    ]

    /// Whether visible content reads as a preamble to a tool call rather than
    /// an answer to the user.
    ///
    /// Deliberately narrow, because a false positive suppresses a legitimate
    /// final answer and spends a retry. The signal is the LAST non-empty line:
    /// a finished answer does not end on a colon (a colon promises something
    /// follows, and when something does follow the colon is no longer last),
    /// and does not end on a bare first-person statement of what the model is
    /// about to do. Both shapes dominate the announce-only turns in
    /// osaurus#2439, where every "Let me write the first batch:" ended the run.
    static func isAnnounceOnly(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // An unbalanced fence means the visible tail is inside a code block,
        // where a trailing colon carries no discourse meaning.
        guard trimmed.components(separatedBy: "```").count % 2 == 1 else { return false }

        let lines = trimmed.split(whereSeparator: \.isNewline)
        guard
            let last = lines.last?.trimmingCharacters(in: .whitespacesAndNewlines),
            !last.isEmpty
        else { return false }
        // Structural tails (list items, tables, fences, quotes) are answer
        // content even when they happen to end in a colon.
        guard let first = last.first,
            !"-*>|#`+".contains(first)
        else { return false }

        if last.hasSuffix(":") { return true }

        // "Let me check the result" / "I'll write these now" as the whole
        // closing line, with no answer after it. Bounded length keeps this
        // from matching a long sentence that merely opens with "I'll".
        let lowered = last.lowercased()
        if last.count <= 120, Self.announcementPrefixes.contains(where: { lowered.hasPrefix($0) }) {
            return true
        }

        // The same announcement as the closing SENTENCE of a status line:
        // "The Wellkr site blocks retrieval. Let me try the Verywell Health
        // article and the Quantum Cacao source." ended an Ornith research run
        // with `stop` and no call. Narrower than the line rule: only
        // first-person action phrases (try/fetch/check/read/search/run/open/
        // look), never "let me know", so a sign-off is not mistaken for a
        // promised call.
        guard let sentence = Self.closingSentence(of: last), sentence.count <= 120 else { return false }
        let loweredSentence = sentence.lowercased()
        return Self.actionAnnouncementPrefixes.contains { loweredSentence.hasPrefix($0) }
    }

    /// The last sentence of a line: the text after the final ". ", "! " or
    /// "? " boundary. `nil` when the line is a single sentence (the line rule
    /// already judged it).
    private static func closingSentence(of line: String) -> String? {
        var cut: String.Index? = nil
        for boundary in [". ", "! ", "? "] {
            if let range = line.range(of: boundary, options: .backwards) {
                if cut == nil || range.upperBound > cut! { cut = range.upperBound }
            }
        }
        guard let cut else { return nil }
        let tail = line[cut...].trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.isEmpty ? nil : tail
    }

    /// First-person "about to act on a source" openers for the closing-sentence
    /// rule. Lowercased, matched as prefixes of the final sentence only.
    private static let actionAnnouncementPrefixes: [String] = [
        "let me try ", "let me fetch ", "let me check ", "let me read ", "let me search ",
        "let me run ", "let me open ", "let me look ", "let me pull ", "let me grab ",
        "now let me ", "next, let me ", "next let me ",
        "i'll try ", "i'll fetch ", "i'll check ", "i'll read ", "i'll search ",
        "i'll run ", "i'll open ", "i'll look ", "i'll pull ", "i'll grab ",
        "i will try ", "i will fetch ", "i will check ", "i will read ", "i will search ",
        "next, i'll ", "next i'll ",
    ]

    /// Openers of a first-person "about to act" line. Lowercased, matched as
    /// prefixes of the final line only.
    private static let announcementPrefixes: [String] = [
        "let me ", "let's ", "now let me ", "i'll ", "i will ", "i am going to ",
        "i'm going to ", "next, i'll ", "next i'll ", "first, let me ", "first let me ",
    ]

    /// Preserve visible partial output, remove only terminal whitespace, and
    /// append the truthful output-cap notice. A whitespace-only completion
    /// becomes the notice itself instead of a giant blank bubble.
    static func contentWithLengthFallback(_ content: String, fallback: String) -> String {
        guard let lastVisible = content.lastIndex(where: { !$0.isWhitespace }) else {
            return fallback
        }
        return String(content[...lastVisible]) + "\n\n" + fallback
    }
}

struct OversizedStreamingToolCall: Error, Sendable {
    let toolName: String?
    let argumentCharacters: Int
}

/// Whether a surface owes the user a normal visible answer after a
/// reasoning-only model stop. Merely advertising tool schemas is not evidence
/// that an agent/tool workflow occurred: ordinary direct chats may expose
/// baseline tools while a reasoning-only bundle intentionally returns on its
/// reasoning rail. Structured tool work in this logical run and remote-agent
/// execution are the two contracts that require a visible final response.
enum AgentLoopVisibleResponsePolicy {
    static func requiresVisibleFinalResponse(
        hasStructuredToolWork: Bool,
        isRemoteAgentTarget: Bool
    ) -> Bool {
        hasStructuredToolWork || isRemoteAgentTarget
    }
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

/// Typed, session-scoped view of the checklist the `todo` tool owns.
/// The driver compares snapshots from successful current-run `todo` calls;
/// it never infers progress from assistant prose or tool-result strings.
struct AgentTodoProgressSnapshot: Equatable, Sendable {
    let done: Int
    let total: Int

    var pending: Int { max(0, total - done) }
}

/// Semantic checklist identity for one parsed `todo` invocation. Markdown
/// headings, bullet choice, whitespace, and other presentation-only text are
/// intentionally excluded: progress means that at least one parsed task or
/// checkbox state changed. This snapshot is scoped to one `run` invocation;
/// an identical checklist in a later user turn is still a legitimate first
/// update and must not be rejected because of stale session state.
struct AgentTodoSemanticSnapshot: Equatable, Sendable {
    struct Item: Equatable, Sendable {
        let text: String
        let isDone: Bool
    }

    let items: [Item]
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
    /// Set `overBudget` on the returned input when even fully-compacted
    /// history cannot fit — the driver ends the run with `.overBudget`
    /// instead of sending a doomed request.
    var buildMessages: (_ notices: [String]) async -> AgentLoopIterationInput

    /// Perform one model step (request build + stream/complete + delta
    /// routing) and classify the outcome. Thrown errors abort the run and
    /// propagate to the caller of `run` (chat's catch blocks live there).
    var modelStep: (_ messages: [ChatMessage], _ iteration: Int) async throws -> AgentLoopModelStep

    /// Keep the just-finished incomplete attempt in the surface transcript and
    /// prepare a fresh output buffer for one natural retry. The retry's
    /// model-visible history must remain byte-for-byte equivalent to the
    /// pre-attempt history: local templates disagree on how a tool-free
    /// `reasoning_content` assistant message is serialized (some drop it,
    /// others close and rewrite it). This boundary must not append that
    /// incomplete attempt to the next model request or inject a prompt,
    /// reasoning tag, sampler override, EOS override, or other coercion.
    var prepareIncompleteReasoningContinuation: (() async -> Void)?

    /// Preserve an ordinary assistant response visibly when a run that
    /// successfully created/updated a todo list stops while structured work
    /// remains, then prepare a fresh output buffer for the next model step.
    /// The premature response MUST be excluded from the next model request:
    /// otherwise chat persists `assistant(final), assistant(tool_call)` after
    /// the transient continuation notice disappears. That invalid role shape
    /// changes Qwen-family template rendering and can restore stale hybrid
    /// state from disk. The preceding tool result remains the authoritative
    /// continuation anchor. Only chat opts into this boundary; headless
    /// surfaces keep their existing terminal behavior.
    var prepareTrackedTaskContinuation: (() async -> Void)?

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

    /// Called after a full batch is processed (and on batch-mode early
    /// stops via `finishBatch`), with outcomes in original model order.
    /// HTTP appends its assistant `tool_calls` message + tool results
    /// here; chat persists its hidden tool turns here so transcript order
    /// always matches the model's call order.
    var onBatchComplete: (_ outcomes: [AgentLoopToolOutcome]) async -> Void

    /// Number of UNCHECKED items on the session's todo list, or nil when
    /// the surface has no session-scoped todo (HTTP/plugin/eval). Chat uses
    /// this only for the periodic staleness notice.
    var pendingTodoCount: (() async -> Int)?

    /// Current structured checklist counts for the run's captured session.
    /// Chat supplies this so a successful current-run `todo` cannot be silently
    /// abandoned while unchecked work remains. Other surfaces retain their
    /// existing terminal behavior by leaving it nil.
    var todoProgressSnapshot: (() async -> AgentTodoProgressSnapshot?)?

    /// Emit a final, user-visible assistant message when an empty turn could
    /// not be recovered (the model produced nothing across the bounded
    /// retries). The surface writes this into its stream/history so the run
    /// never ends with silent emptiness. Surfaces that don't render text to a
    /// user (plugin/eval harnesses) may leave this nil — they then keep their
    /// prior empty-final behavior, which is harmless off the chat surface.
    var emitFallbackText: ((_ text: String) async -> Void)?

    /// Emit a final user-visible explanation when chat's fail-closed tool
    /// policy stops the loop. The rejected envelope is already persisted as
    /// a tool turn; this hook closes the visible assistant turn without
    /// asking the model to guess about a denied or failed side effect.
    var emitToolRejectionText: ((_ text: String) async -> Void)?

    /// Diagnostics side channel, fired once immediately before the run
    /// returns. Optional and observational: the loop's behaviour is
    /// identical whether or not a surface supplies it, and `RunResult`
    /// deliberately stays free of these fields so behavioural assertions
    /// are unaffected. See `AgentToolLoop.ExitDiagnostics`.
    var recordExitDiagnostics: ((AgentToolLoop.ExitDiagnostics) async -> Void)?

    /// The user-visible text of the final response the surface just
    /// classified, for the grounded-claim check
    /// (`GroundedConfigClaimCheck`). Return nil to skip the check for this
    /// turn — chat returns nil when `osaurus_config` is not in the offered
    /// tool schema, so agents without the configure surface are never
    /// second-guessed. Leaving the hook nil opts the surface out entirely.
    var finalVisibleText: (() async -> String?)?

    /// Keep the ungrounded final visible in the surface transcript but
    /// exclude it from the next model request and prepare a fresh output
    /// buffer — the same persistence-backed boundary contract as
    /// `prepareTrackedTaskContinuation`. Required for the grounded-claim
    /// retry: without it a streaming surface would splice two attempts into
    /// one answer, so the driver skips the check when this is nil.
    var prepareGroundedClaimRetry: (() async -> Void)?

    /// The user-visible text of the assistant message the surface just
    /// classified — a tool-calling message's narration OR a final answer —
    /// for the file side-effect advisory (`GroundedFileSideEffectCheck`).
    /// Unlike `finalVisibleText` this is not scoped to a tool surface. The
    /// loop reads it BEFORE executing a tool batch, because a streaming
    /// surface may swap in a fresh buffer in `onBatchComplete`. Leaving it
    /// nil opts the surface out; a nil return skips the check for that turn.
    var assistantVisibleText: (() async -> String?)?

    /// The tool names this request is authorized to EXECUTE right now —
    /// chat binds it to `ToolExecutionScope.authorizedNames` (the scope
    /// grows with same-run `capabilities` activations, so this is a closure,
    /// not a snapshot). The driver uses it for two advisory-only jobs:
    /// folding a hallucinated punctuation variant of an authorized name
    /// (`osaurus_help!!`) back onto the real tool before execution, and
    /// listing the authorized names in the `tool_not_found` notice. Nil on
    /// surfaces that publish no scope — both behaviours then stay off.
    var authorizedToolNames: (() -> Set<String>)?

    init(
        isCancelled: @escaping () async -> Bool = { false },
        buildMessages: @escaping (_ notices: [String]) async -> AgentLoopIterationInput,
        modelStep: @escaping (_ messages: [ChatMessage], _ iteration: Int) async throws -> AgentLoopModelStep,
        prepareIncompleteReasoningContinuation: (() async -> Void)? = nil,
        prepareTrackedTaskContinuation: (() async -> Void)? = nil,
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
        onBatchComplete: @escaping (_ outcomes: [AgentLoopToolOutcome]) async -> Void = { _ in },
        pendingTodoCount: (() async -> Int)? = nil,
        todoProgressSnapshot: (() async -> AgentTodoProgressSnapshot?)? = nil,
        emitFallbackText: ((_ text: String) async -> Void)? = nil,
        emitToolRejectionText: ((_ text: String) async -> Void)? = nil,
        finalVisibleText: (() async -> String?)? = nil,
        prepareGroundedClaimRetry: (() async -> Void)? = nil,
        assistantVisibleText: (() async -> String?)? = nil,
        authorizedToolNames: (() -> Set<String>)? = nil
    ) {
        self.isCancelled = isCancelled
        self.buildMessages = buildMessages
        self.modelStep = modelStep
        self.prepareIncompleteReasoningContinuation = prepareIncompleteReasoningContinuation
        self.prepareTrackedTaskContinuation = prepareTrackedTaskContinuation
        self.willProcessCall = willProcessCall
        self.onDedupedResult = onDedupedResult
        self.executeTool = executeTool
        self.executeBatch = executeBatch
        self.onBatchComplete = onBatchComplete
        self.pendingTodoCount = pendingTodoCount
        self.todoProgressSnapshot = todoProgressSnapshot
        self.emitFallbackText = emitFallbackText
        self.emitToolRejectionText = emitToolRejectionText
        self.finalVisibleText = finalVisibleText
        self.prepareGroundedClaimRetry = prepareGroundedClaimRetry
        self.assistantVisibleText = assistantVisibleText
        self.authorizedToolNames = authorizedToolNames
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

    enum ContextWindowSource: String, Equatable, Sendable {
        case foundationFixed
        case bundleMetadata
        case providerMetadata
        case metadataFallback
        /// The user's cap was lower than the model's window, so it decided the
        /// number. Distinct from the metadata sources so the chip and logs can
        /// say WHY the window is smaller than the bundle advertises.
        case userCap
    }

    /// Applies the user's context cap to a resolved window.
    ///
    /// One helper, called by both resolver twins, because the sync and async
    /// paths feed different surfaces — the send gate and context chip use the
    /// sync one, the agent loop and subagent runner the async one — and a cap
    /// honoured by only one of them would mean the number a user sees and the
    /// number their agents actually run under disagree.
    ///
    /// Only ever lowers. A cap above the model's window is ignored rather than
    /// obeyed: the weights cannot honour it, so raising it produces incoherent
    /// output instead of more context.
    static func applyingUserCap(
        _ resolution: ContextWindowResolution,
        cap: Int?
    ) -> ContextWindowResolution {
        guard let cap, cap > 0, cap < resolution.tokens else { return resolution }
        return ContextWindowResolution(tokens: cap, source: .userCap)
    }

    struct ContextWindowResolution: Equatable, Sendable {
        let tokens: Int
        let source: ContextWindowSource
    }

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
    /// (fixed window), then local bundle metadata (`ModelInfo.contextLength`),
    /// then already-discovered provider metadata from the model picker, and
    /// finally the user-configured unknown-metadata fallback. This is THE
    /// definition of "how big is the window" — the UI uses
    /// `resolveContextWindowSync`, which must stay behavior-identical.
    static func resolveContextWindow(modelId: String) async -> Int {
        (await resolveContextWindowResolution(modelId: modelId)).tokens
    }

    static func resolveContextWindowResolution(
        modelId: String
    ) async -> ContextWindowResolution {
        if foundationModelIds.contains(modelId) {
            return ContextWindowResolution(
                tokens: foundationContextWindow,
                source: .foundationFixed
            )
        }
        let cap = await MainActor.run { ChatConfigurationStore.load().contextLengthCap }
        if let info = ModelInfo.load(modelId: modelId), let ctx = info.model.contextLength {
            return applyingUserCap(
                ContextWindowResolution(tokens: ctx, source: .bundleMetadata), cap: cap)
        }
        if let providerContext = await MainActor.run(body: {
            providerContextWindow(modelId: modelId)
        }) {
            return applyingUserCap(
                ContextWindowResolution(
                    tokens: providerContext,
                    source: .providerMetadata
                ), cap: cap)
        }
        return await MainActor.run {
            applyingUserCap(
                ContextWindowResolution(
                    tokens:
                        ChatConfigurationStore.load().contextLength
                        ?? fallbackContextWindow,
                    source: .metadataFallback
                ), cap: cap)
        }
    }

    /// MainActor-synchronous twin of `resolveContextWindow` for SwiftUI
    /// computed properties (the context chip and send gate). Same
    /// resolution order, same values.
    @MainActor
    static func resolveContextWindowSync(modelId: String) -> Int {
        resolveContextWindowResolutionSync(modelId: modelId).tokens
    }

    @MainActor
    static func resolveContextWindowResolutionSync(
        modelId: String
    ) -> ContextWindowResolution {
        if foundationModelIds.contains(modelId) {
            return ContextWindowResolution(
                tokens: foundationContextWindow,
                source: .foundationFixed
            )
        }
        // Serve the memo or warm it off-thread — never probe disk here. This runs
        // on every layout pass (context chip, send gate), and `ModelInfo.load`'s
        // cold path (`findModelDirectory` + `config.json` read) blocks the main
        // thread long enough to trip the app-hang detector. A transient nil on a
        // cold cache falls through to the conservative store/fallback value.
        let cap = ChatConfigurationStore.load().contextLengthCap
        if let info = ModelInfo.loadCachedOrWarm(modelId: modelId), let ctx = info.model.contextLength {
            return applyingUserCap(
                ContextWindowResolution(tokens: ctx, source: .bundleMetadata), cap: cap)
        }
        if let providerContext = providerContextWindow(modelId: modelId) {
            return applyingUserCap(
                ContextWindowResolution(
                    tokens: providerContext,
                    source: .providerMetadata
                ), cap: cap)
        }
        return applyingUserCap(
            ContextWindowResolution(
                tokens:
                    ChatConfigurationStore.load().contextLength
                    ?? fallbackContextWindow,
                source: .metadataFallback
            ), cap: cap)
    }

    /// Synchronous cache-only provider lookup used by both the async runtime
    /// resolver and SwiftUI's synchronous context display. Provider discovery
    /// populates `ModelPickerItemCache`; this function never performs network
    /// I/O or rebuilds the catalog during a request/layout pass.
    @MainActor
    private static func providerContextWindow(modelId: String) -> Int? {
        let trimmed = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return ModelPickerItemCache.shared.items.first(where: {
            guard case .remote = $0.source else { return false }
            return $0.id == trimmed
        })?.contextLength
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
    /// entry, not real cost; "summary" is the LLM compaction summary, which
    /// a later re-compaction can shrink further.
    private static let compactableEntryIds: Set<String> = [
        "conversation", "output", "compacted", "summary",
    ]

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
        let reservation = cappedResponseReservation(
            maxResponseTokens,
            effectiveBudget: effective
        )
        let nonCompactable = max(0, total - compactable) + reservation

        return Assessment(
            usageRatio: ratio,
            nearLimit: (ratio ?? 0) >= nearLimitThreshold,
            hardOverflow: nonCompactable > effective
        )
    }

    /// The ONE definition of how many tokens the response reserves out of
    /// the effective budget, shared by `assess` (UI hard-overflow gate)
    /// and `makeBudgetManager` (runtime trim budget) so the two never
    /// diverge. Capped at a quarter of the effective budget so
    /// small-window models (Foundation ~4K) aren't permanently gated by a
    /// reservation larger than their whole window — the runtime truncates
    /// generation in that case rather than failing the request.
    static func cappedResponseReservation(
        _ maxResponseTokens: Int?,
        effectiveBudget: Int
    ) -> Int {
        min(
            maxResponseTokens ?? defaultResponseReservation,
            max(0, effectiveBudget / 4)
        )
    }

    /// Build a `ContextBudgetManager` with the canonical reservations:
    /// system prompt (by char count), tool schema (tokens), and the
    /// response (`max_tokens` capped via `cappedResponseReservation`,
    /// matching the `assess` hard gate).
    static func makeBudgetManager(
        contextWindow: Int,
        systemPromptChars: Int,
        toolTokens: Int,
        maxResponseTokens: Int?
    ) -> ContextBudgetManager {
        var mgr = ContextBudgetManager(contextLength: contextWindow)
        mgr.reserveByCharCount(.systemPrompt, characters: systemPromptChars)
        mgr.reserve(.tools, tokens: toolTokens)
        mgr.reserve(
            .response,
            tokens: cappedResponseReservation(maxResponseTokens, effectiveBudget: mgr.effectiveBudget)
        )
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
    /// `[System Notice]` lines as TRANSIENT messages (see
    /// ``appendingTransientNotices(_:to:)`` — tool-role feedback after a tool
    /// result so the chat-template last-query anchor and the KV prefix stay
    /// stable, else a trailing user turn) — never persisted into the
    /// surface's history store, so a notice rides exactly one iteration. The
    /// trim budget's safety margin
    /// (`ContextBudgetManager.safetyMargin`, 15% of the window) is the
    /// refit headroom that absorbs the notices' small token cost.
    ///
    /// Chat follows the same contract inline (it interleaves compaction
    /// telemetry and the mid-run token notice between the two steps).
    ///
    /// The returned input carries `overBudget` (trimmed transcript still
    /// exceeds the history budget after every compaction lever) so the
    /// driver can end the run with `.overBudget` instead of sending a
    /// doomed request.
    static func composeIterationMessages(
        _ messages: [ChatMessage],
        notices: [String],
        manager: ContextBudgetManager?,
        watermark: CompactionWatermark? = nil
    ) -> AgentLoopIterationInput {
        var msgs = messages
        var overBudget = false
        if let manager {
            let result = trimPreservingSystemPrefixReportingOverflow(
                msgs,
                with: manager,
                watermark: watermark
            )
            msgs = result.messages
            overBudget = result.overBudget
        }
        msgs = appendingTransientNotices(notices, to: msgs)
        return AgentLoopIterationInput(messages: msgs, overBudget: overBudget)
    }

    /// Append transient per-iteration `[System Notice]` lines to a prompt
    /// WITHOUT destabilizing the KV-cache prefix.
    ///
    /// A notice appended as a trailing *user* turn re-anchors chat templates
    /// that gate the assistant reasoning rail on "the last user query"
    /// (e.g. Qwen3.x's `last_query_index`): the most recent assistant
    /// tool-call turn then re-renders WITHOUT the `<think>…</think>` scaffold
    /// it generated under, so its cached token prefix no longer matches and
    /// the next iteration re-prefills the entire prompt (the "kv cache set to
    /// 0" symptom after a tool call). When the iteration already ends in tool
    /// output, deliver the notices as additional tool-role environment
    /// feedback instead: the template's last-query anchor — and therefore the
    /// reused KV prefix — stays put, while the model still reads the notice.
    /// With no trailing tool result (e.g. the empty-turn nudge), fall back to
    /// the original trailing-user turn, which has no cached tool-call rail to
    /// preserve.
    static func appendingTransientNotices(
        _ notices: [String],
        to messages: [ChatMessage]
    ) -> [ChatMessage] {
        guard !notices.isEmpty else { return messages }
        var msgs = messages
        // If the iteration ends in a tool result, notices ride alongside it as
        // tool-role environment feedback (captured before we append, so every
        // notice keeps that result's `tool_call_id`); otherwise they fall back
        // to a trailing user turn. Native image generate->edit is the narrow
        // exception: Gemma treats a second tool-role message as low-salience
        // environment chatter after the generated image, so only that
        // continuation notice is promoted to a transient user turn.
        let trailingTool = (msgs.last?.role == "tool") ? msgs.last : nil
        let nativeImageGenerateResult = trailingTool.map(isNativeImageGenerateToolResult) ?? false
        for notice in notices {
            if nativeImageGenerateResult, isNativeImageEditContinuationNotice(notice) {
                msgs.append(ChatMessage(role: "user", content: notice))
            } else if let trailingTool {
                msgs.append(
                    ChatMessage(
                        role: "tool",
                        content: notice,
                        tool_calls: nil,
                        tool_call_id: trailingTool.tool_call_id
                    )
                )
            } else {
                msgs.append(ChatMessage(role: "user", content: notice))
            }
        }
        return msgs
    }

    private static func isNativeImageGenerateToolResult(_ message: ChatMessage) -> Bool {
        guard message.role == "tool",
            let content = message.content,
            ToolEnvelope.isSuccess(content),
            let data = content.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            dict["tool"] as? String == "image",
            let payload = dict["result"] as? [String: Any],
            payload["kind"] as? String == "native_image_generation_job",
            // Only a fresh generation (not an edit) gets the continuation
            // promotion — the nudge after an edit would loop.
            (payload["mode"] as? String) ?? "generate" == "generate",
            let images = payload["images"] as? [[String: Any]]
        else { return false }
        return images.contains { image in
            guard let path = image["path"] as? String else { return false }
            return !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static func isNativeImageEditContinuationNotice(_ notice: String) -> Bool {
        notice.contains("source_paths")
            && notice.contains("previous `image` result")
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
        /// `buildMessages` reported that even fully-compacted history
        /// cannot fit the budget. The run ends WITHOUT a model step; the
        /// surface emits a distinct "context cannot fit" envelope instead
        /// of sending a doomed request.
        case overBudget
        /// Empty-turn recovery exhausted after at least one tool result had
        /// already landed, so the task may be truncated rather than merely blank.
        case emptyResponseExhausted
        /// The model exhausted the configured output-token budget without an
        /// executable tool call. Any visible partial text is preserved.
        case lengthExhausted
        /// A tool call repeatedly exceeded the bounded streaming-argument
        /// contract and never became executable.
        case oversizedToolCallExhausted
        /// A streamed tool envelope repeatedly hit the model output ceiling
        /// before becoming executable.
        case truncatedToolCallExhausted
        /// The model degenerated into a phrase-repetition loop and the bounded
        /// retry did not recover it.
        case repetitionLoopExhausted
        /// Bounded recovery could not turn reasoning-only/unclosed output into
        /// a user-visible final answer.
        case incompleteReasoningExhausted
    }

    /// WHICH decision produced the exit. `Exit` says what the run ended as;
    /// `ExitOrigin` says which branch decided it, and the two are not 1:1.
    ///
    /// `.finalResponse` alone is returned from six distinct sites, three of
    /// which are give-up paths taken only after a bounded recovery was
    /// exhausted. Without this field an exhausted-recovery exit is
    /// indistinguishable in telemetry from a model that simply answered —
    /// which is why "the agent stopped mid-turn" reports have been
    /// unfalsifiable from logs and eval reports alike.
    ///
    /// Diagnostic only: nothing branches on this value.
    enum ExitOrigin: String, Sendable, Equatable {
        /// The model produced a final answer and the driver accepted it.
        case ordinaryModelFinal
        /// Empty-turn recovery ran out of nudges with no completed tool work;
        /// the fallback text was emitted and the run ended.
        case emptyTurnRecoveryExhausted
        /// Announce-only recovery ran out of nudges; the model's preamble is
        /// kept as the answer.
        case announcedToolCallRecoveryExhausted
        /// The model asked whether to continue and no tracked work was
        /// pending, so the question was handed to the user.
        case continuationRequestNoPendingWork
        /// Continuation-request recovery ran out of nudges.
        case continuationRequestRecoveryExhausted
        /// A malformed repeat of an already-successful desktop subagent call
        /// was replaced by the prior tool's summary.
        case desktopSummarySubstituted
        /// Terminal states that are already unambiguous from `Exit` itself.
        case typedTerminal
    }

    /// Bounded-recovery attempts actually spent during the run. All are
    /// uncharged against the iteration budget, so without this they leave no
    /// trace anywhere: a run that burned six nudges looks identical to one
    /// that never stalled.
    struct RecoveryCounters: Equatable, Sendable {
        var emptyTurn: Int = 0
        var announcedToolCall: Int = 0
        var continuationRequest: Int = 0
        var repetitionLoop: Int = 0
        var incompleteReasoning: Int = 0

        var total: Int {
            emptyTurn + announcedToolCall + continuationRequest
                + repetitionLoop + incompleteReasoning
        }
    }

    struct RunResult: Equatable, Sendable {
        var exit: Exit
        /// Iterations charged against the budget (transient retries are
        /// not charged).
        var iterations: Int
        /// Structured unfinished-work state captured when a current-run Todo
        /// reaches the hard iteration cap. Nil for every other exit, including
        /// an ordinary tool-loop cap with no Todo contract.
        var unfinishedTodoCount: Int?

        init(exit: Exit, iterations: Int, unfinishedTodoCount: Int? = nil) {
            self.exit = exit
            self.iterations = iterations
            self.unfinishedTodoCount = unfinishedTodoCount
        }
    }

    /// Diagnostics emitted once, immediately before the run returns.
    /// Deliberately NOT part of `RunResult`: that type is the behavioural
    /// contract and 41 existing assertions compare it by value, so folding
    /// observability into it would force every one of them to restate
    /// diagnostic data. Nothing branches on any of this.
    struct ExitDiagnostics: Equatable, Sendable {
        var exit: Exit
        var origin: ExitOrigin
        var counters: RecoveryCounters
    }

    /// The dedupe-replay notice staged when a held result short-circuits
    /// a repeated read (chat surface only, per policy).
    static let dedupeNotice =
        "[System Notice] You already retrieved this exact result this turn and it is unchanged. Use the result you already have instead of repeating the call."

    /// Max consecutive empty (0-token / no-tool) turns to nudge-and-retry
    /// before giving up and emitting the fallback. Small: the nudge changes
    /// the prompt so even a temperature-0 model that just emitted EOS will
    /// almost always produce text on the next attempt; the cap guarantees
    /// the loop can never spin on a deterministically-empty model.
    static let maxEmptyTurnRetries = 2

    /// Staged before an empty-turn retry. Telling the model its last turn
    /// produced nothing (and to answer or call a tool) perturbs the prompt
    /// enough to break the immediate-EOS state that caused the empty turn.
    static let emptyTurnNotice =
        "[System Notice] Your previous turn produced no output. Respond to the user's request now, or call a tool to make progress. Do not reply with an empty message."

    /// Emitted to the user when even the nudged retries produced nothing, so
    /// an empty turn never surfaces as a silent "No visible text was produced".
    static let emptyTurnFallback =
        "I wasn't able to generate a response to that. Please try rephrasing your request."

    /// Max consecutive announce-only turns to nudge-and-retry. Lower than the
    /// empty-turn budget: each retry leaves the announcement visible in the
    /// transcript, so repeated attempts read as the model talking to itself.
    /// If two nudges don't produce a call, the model is not going to make one
    /// and the announcement is accepted as the (poor) final answer.
    static let maxAnnouncedToolCallRetries = 2

    /// Staged before an announce-only retry. Names the specific failure — the
    /// model believes it already issued the call — because the generic
    /// "produced no output" nudge does not fit a turn that produced text.
    static let announcedToolCallNotice =
        "[System Notice] Your previous turn described a tool call but did not actually emit one, so nothing ran. "
        + "No file was written and no command executed. Emit the tool call itself now, as a real call — "
        + "do not describe it, narrate it, or claim it already ran."

    /// How many times a run will push back on "shall I continue?" before
    /// letting the question stand. Two: enough to get past a model that asks
    /// reflexively, few enough that a user who really is being consulted is
    /// not talked over indefinitely.
    static let maxContinuationRequestRetries = 2

    /// Staged before a continuation-request retry. States the standing
    /// authorization explicitly — a model that asks permission mid-task is
    /// usually unsure it has any — and names the pending count so "continue"
    /// has a concrete referent.
    static func continuationRequestNotice(pending: Int) -> String {
        let items = pending == 1 ? "1 item remains" : "\(pending) items remain"
        return
            "[System Notice] You asked whether to continue. Yes — continue. The user's request "
            + "already authorized this work and \(items) unchecked on your todo. Do not ask "
            + "again: proceed with the next pending item now. If you are genuinely blocked on "
            + "something only the user can decide, call `clarify` with the specific question "
            + "instead of asking in prose."
    }

    /// One retry. A model that degenerated once usually degenerates again,
    /// and each attempt costs the user real wall-clock time.
    static let maxRepetitionLoopRetries = 1

    static func repetitionLoopNotice(phrase: String?) -> String {
        let quoted = phrase.map { " (\"\($0)\")" } ?? ""
        return
            "[System Notice] Your previous turn repeated the same sentence\(quoted) over and over "
            + "and was stopped. Repeating a plan is not progress. Do exactly ONE concrete thing "
            + "now: emit a single tool call, or state plainly what is blocking you. Do not restate "
            + "what you are about to do."
    }

    /// Shown when the retry degenerates too. Honest about what happened
    /// rather than leaving a wall of repeated text as the answer.
    static let repetitionLoopFallback =
        "The model got stuck repeating itself and the response was stopped. "
        + "This usually means the task is too large for one turn — try narrowing it to a single "
        + "step, or switch to a different model."

    static let emptyToolTaskFallback =
        "The model returned empty output after tool execution. The agent task may be incomplete; retry with less context or continue from the latest tool result."

    static let lengthExhaustedFallback =
        "The model reached the configured output-token limit before naturally completing an answer or tool call. "
        + "The agent task is incomplete; increase Max Tokens, disable Thinking for this task, "
        + "or continue from the latest tool result."

    // This bounds the serialized JSON envelope, not just `content`. A valid
    // 30,000-character write made entirely of quotes or backslashes expands
    // to roughly 60K after JSON escaping, plus path/mode framing.
    static let maxStreamingToolArgumentCharacters = 65_536
    static let maxOversizedToolCallRetries = 1
    static let maxTruncatedToolCallRetries = 1

    static func oversizedToolCallNotice(toolName: String?, argumentCharacters: Int) -> String {
        let tool = toolName?.isEmpty == false ? "`\(toolName!)`" : "tool"
        return
            "[System Notice] The previous \(tool) call exceeded the \(argumentCharacters)-character "
            + "streaming argument limit before it became executable. Retry with smaller calls. "
            + "Keep each content chunk under \(WorkspaceToolContract.recommendedWriteChunkCharacters) characters. "
            + "For a large file, write the first chunk with `file_write`, then use "
            + "`file_write` with `mode: \"append\"` for later chunks."
    }

    static let oversizedToolCallFallback =
        "The model repeatedly produced an oversized tool call that could not execute. "
        + "The task is incomplete; retry with a smaller output or split large file writes into chunks."

    static func truncatedToolCallNotice(toolName: String?, argumentCharacters: Int) -> String {
        let tool = toolName?.isEmpty == false ? "`\(toolName!)`" : "tool"
        return
            "[System Notice] The previous \(tool) call reached the model output limit after "
            + "\(argumentCharacters) argument characters and did not execute. "
            + "Retry now with `file_write` content under "
            + "\(WorkspaceToolContract.recommendedWriteChunkCharacters) characters. "
            + "Write a viable first chunk, then use `file_write` with `mode: \"append\"` "
            + "for every later chunk."
    }

    static let truncatedToolCallFallback =
        "The model repeatedly reached its output limit inside an unfinished tool call. "
        + "The task is incomplete; retry with a higher Max Tokens setting or smaller file-write chunks."

    /// Only one natural continuation generation is allowed after a
    /// reasoning-only assistant step. The surface preserves that real step in
    /// history and starts a fresh output buffer; the driver does not fabricate
    /// a user/system message or alter decode controls.
    static let maxIncompleteReasoningRetries = 1

    /// Bounded grounded-claim retries per run (see
    /// `GroundedConfigClaimCheck`): one regeneration per trip class — a
    /// fabricated-envelope answer and an ungrounded change claim can each be
    /// corrected once. The notice reflects true executed state back to the
    /// model; the model always writes its own corrected answer.
    static let maxGroundedClaimRetries = 2

    /// Bounded file side-effect advisories per run for TOOL-CALLING turns
    /// (see `GroundedFileSideEffectCheck`): the notice is staged for the
    /// next step and the loop continues — never a stop — so a model that
    /// ignores it is nudged at most this many times rather than every
    /// iteration. Final-answer trips share `maxGroundedClaimRetries`.
    static let maxUngroundedFileClaimNotices = 2

    static let incompleteReasoningFallback =
        "The model ended in reasoning without producing a user-visible final answer. "
        + "The agent task may be incomplete; retry with Thinking disabled or continue from the latest tool result."

    /// Structured state notice used when a model emits an ordinary stop while
    /// the Todo it created this run still has unchecked work. This is not a
    /// prose classifier: the count comes from `AgentTodoStore`, and the loop is
    /// still bounded by the user's normal tool-attempt budget.
    static func todoPendingFinalNotice(pending: Int) -> String {
        "[System Notice] The todo you created this turn still has \(pending) unchecked item\(pending == 1 ? "" : "s"). Continue the task now. If you cannot finish, give the user an honest final answer and call `complete(summary)` with what remains blocked."
    }

    /// Honest chat fallback when a structured current-run Todo remains
    /// unfinished at the hard agent-step cap. This is driven by typed Todo
    /// state, never by classifying the model's prose.
    static func unfinishedTodoCapFallback(pending: Int) -> String {
        "The agent reached the configured step limit with \(pending) todo item\(pending == 1 ? "" : "s") still unfinished. The task is incomplete; continue from the latest completed step or increase Max Agent Steps in Chat settings."
    }

    /// The iteration-budget warning staged when the remaining budget
    /// drops to the policy threshold.
    static func budgetWarningNotice(remaining: Int, maxIterations: Int) -> String {
        "[System Notice] Tool call budget: \(remaining) of \(maxIterations) remaining. Wrap up your current work and provide a summary."
    }

    private static let budgetWarningNoticeMarker = "[System Notice] Tool call budget: "

    /// The driver stages this iteration's notices BEFORE the surface's
    /// `buildMessages` hook runs; chat injects a queued steer (a new user
    /// message) inside that hook and resets `AgentTaskState` there. State
    /// notices staged for the previous message ("you have made the exact
    /// same call 3+ times", invalid-args nudges, planning-loop nudges) then
    /// rode into the first request of the NEW message, telling the model it
    /// had repeated a call it had not yet made in this message. Only the
    /// run-scoped iteration-budget warning belongs to the run rather than to
    /// the message that produced it; keep that one.
    static func noticesSurvivingNewUserMessage(_ notices: [String]) -> [String] {
        notices.filter { $0.hasPrefix(budgetWarningNoticeMarker) }
    }

    /// Final, transient control notice for the one tool-free summarization
    /// request issued after the hard iteration cap. The model may still have
    /// an unfinished tool request in mind; without this explicit boundary it
    /// can print an imitation tool/result envelope and claim work that never
    /// executed. This notice asks for an honest status only. It does not alter
    /// sampling, thinking, templates, or any model-family behavior.
    /// Visible text for a capped run whose wrap-up turn produced no visible
    /// content at all (thinking only, or nothing). Not a summary of the work
    /// — the model did not write one — just the truthful state.
    static let iterationCapEmptyWrapUpText =
        "The configured tool-call limit was reached before a final answer was written. "
        + "The tool results above are the state of the work; send a message to continue."

    static let iterationCapWrapUpNotice =
        "[System Notice] The configured tool-call limit has been reached. "
        + "No more tools are available in this response. Give the user an honest final status "
        + "using only tool results already present. Do not emit or imitate a tool call or "
        + "tool-result payload, do not claim an unexecuted step succeeded, and explicitly "
        + "identify any requested step that remains unfinished."

    /// The mid-run near-limit notice (history estimate crossed ~90% of the
    /// history budget). When a spawn tool is visible in the schema, the
    /// notice also nudges delegation: offloading the remaining bulk
    /// reading/research to a worker costs the parent a digest instead of
    /// the whole transcript — exactly what a tight window needs. The nudge
    /// is advisory (same posture as the task-state bias notices).
    static func contextNearLimitNotice(spawnAvailable: Bool) -> String {
        var notice =
            "[System Notice] Context is nearly full — older messages are being compacted. "
            + "Wrap up the current work and provide a summary."
        if spawnAvailable {
            notice +=
                " If substantial reading, research, or summarization remains, delegate it via "
                + "your spawn tool with a self-contained input — the returned digest costs a "
                + "fraction of doing that work inline here."
        }
        return notice
    }

    /// Staged once per run, the first time a data-movement step is refunded,
    /// so the model learns it can lean on bulk loads without burning budget.
    static func dataMovementReliefNotice(cap: Int) -> String {
        "[System Notice] Bulk data-movement steps (db_import, or db_insert/db_upsert with `rows[]`) don't count against your tool-call budget — up to \(cap) such steps. Prefer them for loading or moving large data."
    }

    /// True when `outcome` is a successful bulk DB load that should be
    /// refunded by the data-movement budget rather than charged against
    /// `maxIterations`. Deduped replays and failures never qualify.
    static func isSuccessfulDataMovement(_ outcome: AgentLoopToolOutcome) -> Bool {
        guard !outcome.wasError, !outcome.wasDeduped else { return false }
        guard
            isDataMovementCall(
                name: outcome.invocation.toolName,
                argsJSON: outcome.invocation.jsonArguments
            )
        else { return false }
        return envelopeReportsSuccess(outcome.result)
    }

    /// A data-movement call is `db_import`, or `db_insert`/`db_upsert` in
    /// their bulk (`rows[]`) form. Single-row writes are organic agent work
    /// and stay on the normal budget.
    static func isDataMovementCall(name: String, argsJSON: String) -> Bool {
        switch name {
        case "db_import":
            return true
        case "db_insert", "db_upsert":
            guard let data = argsJSON.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let rows = obj["rows"] as? [Any]
            else { return false }
            return !rows.isEmpty
        default:
            return false
        }
    }

    /// Parse a tool-result envelope and report whether it was a success
    /// (`"ok": true`). A failure envelope (e.g. quota exceeded) must NOT be
    /// refunded.
    static func envelopeReportsSuccess(_ result: String) -> Bool {
        guard let data = result.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return (obj["ok"] as? Bool) == true
    }

    /// Interactive desktop subagents can partially affect external state
    /// before returning a terminal failure. Once one reports a canonical,
    /// non-retryable failure, the chat surface must not ask the parent model
    /// to guess what happened or launch another blind automation attempt.
    ///
    /// `invalid_args` and `not_found` deliberately remain recoverable: the
    /// parent can correct the call shape or choose a different target.
    /// `unavailable` is also recoverable: every desktop-subagent emission of
    /// it happens during reject-before-evict model/config/residency
    /// resolution, strictly before any desktop action runs, so no partial
    /// external state can exist — and stopping there leaves the user with no
    /// answer at all when a model calls e.g. `mac_query` on a machine with no
    /// Computer Use model installed. Other tools retain their existing
    /// envelope/pivot behavior; this safety stop is scoped to the three
    /// desktop subagent entry points implicated by the shared
    /// execution/finalization contract.
    static func isTerminalDesktopSubagentFailure(toolName: String, result: String) -> Bool {
        guard ["computer_use", "applescript", "mac_query"].contains(toolName) else {
            return false
        }
        guard ToolEnvelope.isError(result),
            let data = result.data(using: .utf8),
            let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            envelope["retryable"] as? Bool == false,
            let rawKind = envelope["kind"] as? String,
            let kind = ToolEnvelope.Kind(rawValue: rawKind)
        else { return false }

        switch kind {
        case .invalidArgs, .notFound, .unavailable:
            return false
        case .rejected, .timeout, .executionError, .toolNotFound, .userDenied:
            return true
        }
    }

    /// Recover one narrow post-success failure mode without executing a
    /// second desktop mutation. Small local parent models can correctly run a
    /// desktop subagent, receive its successful structured result, then emit
    /// the same tool again with its primary required field omitted. The vMLX
    /// parser truthfully turns that malformed call into an
    /// `invalid_tool_arguments` envelope; feeding it back invites a blind
    /// retry even though the requested desktop work already succeeded.
    ///
    /// This is intentionally NOT a general invalid-arguments repair. It only
    /// returns the real summary from the immediately preceding successful
    /// result when all of these are true: one of the three desktop subagent
    /// tools is repeated, the parser reports that tool's primary required
    /// field missing, and the prior success envelope belongs to that same
    /// tool. Any other malformed call still executes normally and reaches the
    /// parent for correction.
    static func completedDesktopSummaryBeforeMalformedRepeat(
        invocation: ServiceToolInvocation,
        state: AgentTaskState
    ) -> String? {
        let requiredField: String
        switch invocation.toolName {
        case "computer_use": requiredField = "goal"
        case "applescript": requiredField = "task"
        case "mac_query": requiredField = "question"
        default: return nil
        }

        guard
            let argsData = invocation.jsonArguments.data(using: .utf8),
            let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any],
            args["_error"] as? String == "invalid_tool_arguments",
            args["_tool"] as? String == invocation.toolName,
            args["_field"] as? String == requiredField,
            let priorEnvelope = state.lastResultEnvelope,
            ToolEnvelope.isSuccess(priorEnvelope),
            let priorData = priorEnvelope.data(using: .utf8),
            let prior = try? JSONSerialization.jsonObject(with: priorData) as? [String: Any],
            prior["tool"] as? String == invocation.toolName,
            let result = prior["result"] as? [String: Any],
            let rawSummary = result["summary"] as? String
        else { return nil }

        let summary = rawSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        return summary.isEmpty ? nil : summary
    }

    /// Shared user-facing text for the `.overBudget` exit: the request
    /// cannot fit the model's context window even after every compaction
    /// lever was exhausted. Each surface wraps this in its own envelope
    /// (chat error bubble, HTTP SSE error, plugin JSON error).
    static let overBudgetMessage =
        "Context window cannot fit this request even after compaction. Shorten the input, reduce tool output, or start a new conversation."

    /// The same message, but naming the user's own cap when that — rather
    /// than the model — is what the request failed to fit.
    ///
    /// Telling someone to "shorten the input" when the model has a 108k
    /// window and their Context Window Cap is 2048 sends them to fix the
    /// wrong thing. The resolver already records `.userCap`, so the surface
    /// can point at the setting that actually decided the number.
    static func overBudgetMessage(windowSource: AgentLoopBudget.ContextWindowSource?) -> String {
        guard windowSource == .userCap else { return overBudgetMessage }
        return
            "Context window cannot fit this request. The limit in force is your "
            + "Context Window Cap (Settings → Server → Cache → Context & KV Policy), "
            + "not the model's own window — raise or clear it, or shorten the input."
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
    /// Folder tools that mutate one target path. Two parallel calls on the
    /// same path read-then-write non-atomically (lost update / TOCTOU), so
    /// the batch executor serializes same-path slots while keeping
    /// distinct paths fully parallel.
    static let pathMutatingToolNames: Set<String> = ["file_write", "file_edit"]

    /// Serialization key for a call: non-nil when the call mutates a
    /// single target path. Calls sharing a key execute serially in model
    /// order within the parallel wave.
    static func pathSerializationKey(for invocation: ServiceToolInvocation) -> String? {
        guard pathMutatingToolNames.contains(invocation.toolName) else { return nil }
        guard let data = invocation.jsonArguments.data(using: .utf8),
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let rawPath = obj["path"] as? String
        else { return nil }
        let path = (rawPath.trimmingCharacters(in: .whitespacesAndNewlines) as NSString)
            .standardizingPath
        guard !path.isEmpty else { return nil }
        return path
    }

    static func runBatchInParallel(
        _ calls: [(invocation: ServiceToolInvocation, callId: String)],
        execute: @escaping @Sendable (_ invocation: ServiceToolInvocation, _ callId: String) async throws -> String
    ) async -> [AgentLoopToolExecution] {
        @Sendable func executeOne(
            _ call: (invocation: ServiceToolInvocation, callId: String)
        ) async -> AgentLoopToolExecution {
            // Cooperative cancellation: a Stop / client disconnect cancels
            // the surrounding task (chat run task, HTTP request task), and
            // TaskGroup children inherit it. Check before dispatching so
            // un-started calls don't fire after the user pulled the plug —
            // they come back as paired "cancelled" envelopes instead, so
            // no assistant `tool_use` dangles.
            if Task.isCancelled {
                return AgentLoopToolExecution(
                    result: ToolEnvelope.failure(
                        kind: .executionError,
                        message: "Run cancelled before this call executed.",
                        tool: call.invocation.toolName,
                        retryable: false
                    ),
                    isError: false
                )
            }
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

        // Group same-path mutating calls so they run serially in model
        // order (lost-update / TOCTOU guard); every other call gets its
        // own group and still runs fully parallel.
        var groups: [[Int]] = []
        var groupIndexByKey: [String: Int] = [:]
        for (index, call) in calls.enumerated() {
            if let key = pathSerializationKey(for: call.invocation) {
                if let existing = groupIndexByKey[key] {
                    groups[existing].append(index)
                    continue
                }
                groupIndexByKey[key] = groups.count
            }
            groups.append([index])
        }

        // One batch id for the whole wave so multi-file operations group
        // in the file-operation undo log (`FileOperation.batchId`).
        let indexed: [(Int, AgentLoopToolExecution)] = await ChatExecutionContext.$currentBatchId
            .withValue(UUID()) {
                await withTaskGroup(of: [(Int, AgentLoopToolExecution)].self) { group in
                    for slotGroup in groups {
                        group.addTask {
                            var results: [(Int, AgentLoopToolExecution)] = []
                            results.reserveCapacity(slotGroup.count)
                            for index in slotGroup {
                                results.append((index, await executeOne(calls[index])))
                            }
                            return results
                        }
                    }
                    var collected: [(Int, AgentLoopToolExecution)] = []
                    collected.reserveCapacity(calls.count)
                    for await items in group { collected.append(contentsOf: items) }
                    return collected
                }
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

    /// Agent-loop control calls are not user-task actions and therefore do
    /// not consume the structural tracking threshold. `share_artifact` is an
    /// action because it performs the requested delivery.
    static let taskTrackingControlToolNames: Set<String> = ["todo", "complete", "clarify"]

    static let taskTrackingRequiredReason = "task_tracking_required"
    static let todoProgressUpdateRequiredReason = "todo_progress_update_required"
    static let todoNoProgressReason = "todo_no_progress"

    /// Todo is model-authored progress metadata, not an execution precondition.
    /// Rejecting the Nth ordinary action until a checklist exists turned
    /// recoverable discovery mistakes into mandatory Todo loops and prevented
    /// otherwise valid tools from running. Keep the compatibility helper for
    /// callers compiled against this policy surface, but never force tracking.
    static func chatTodoPreconditionThreshold(
        hasTodoTool _: Bool,
        isLocalModel _: Bool,
        modelType _: String?
    ) -> Int {
        0
    }

    static func isTaskTrackingAction(toolName: String) -> Bool {
        !taskTrackingControlToolNames.contains(toolName)
    }

    /// Honest, structured precondition failure used only by a surface that
    /// explicitly enables Todo enforcement. The requested tool did not run;
    /// the model can either create the required checklist and retry, or stop
    /// using tools and give the user a complete answer from evidence already
    /// collected.
    static func taskTrackingRequiredResult(toolName: String, threshold: Int) -> String {
        ToolEnvelope.failure(
            kind: .rejected,
            message:
                "This tool call was not executed because this run reached \(threshold) ordinary "
                + "tool actions without a current-run todo. Call `todo(markdown)` with the "
                + "remaining checklist, then retry this exact tool call. If no more tools are "
                + "needed, answer the user completely now.",
            tool: toolName,
            retryable: true,
            metadata: [
                "reason": taskTrackingRequiredReason,
                "executed": false,
                "required_before_tool_call": threshold,
            ]
        )
    }

    static func isTaskTrackingRequiredResult(_ result: String) -> Bool {
        guard ToolEnvelope.isError(result),
            let data = result.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return object["reason"] as? String == taskTrackingRequiredReason
    }

    /// A tracked task must not terminate from a stale checklist after new
    /// actions have run. The model owns the semantic mapping from results to
    /// checklist items; the runtime only requires one fresh, structured Todo
    /// snapshot before accepting `complete`. This avoids guessing which work
    /// succeeded while preventing a green completion banner beside a stale
    /// `0/N` list.
    static func todoProgressUpdateRequiredResult(toolName: String, pending: Int) -> String {
        ToolEnvelope.failure(
            kind: .rejected,
            message:
                "This completion was not accepted because \(pending) todo item"
                + (pending == 1 ? " is" : "s are")
                + " still unchecked and ordinary tool actions ran after the last todo update. "
                + "Call `todo(markdown)` with the full current checklist now, checking every "
                + "item actually finished and leaving blocked work unchecked. Then answer "
                + "normally if no items remain, or call `complete` again with an honest blocked "
                + "summary if unfinished work remains.",
            tool: toolName,
            retryable: true,
            metadata: [
                "reason": todoProgressUpdateRequiredReason,
                "executed": false,
                "pending_todo_items": pending,
            ]
        )
    }

    static func isTodoProgressUpdateRequiredResult(_ result: String) -> Bool {
        guard ToolEnvelope.isError(result),
            let data = result.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return object["reason"] as? String == todoProgressUpdateRequiredReason
    }

    /// Reject an exact semantic replay of the current run's latest successful
    /// checklist. Rewriting the same `0/N` Todo is not task progress and, in a
    /// live Gemma run, kept a completed answer spinning until the step cap.
    /// The call is not executed, so the session store and UI timestamp do not
    /// churn and the model receives an explicit choice: do work, record a real
    /// checkbox/task change, or close honestly as blocked.
    static func todoNoProgressResult(pending: Int) -> String {
        ToolEnvelope.failure(
            kind: .rejected,
            message:
                "This todo call was not executed because it exactly repeats the current "
                + "checklist with no task or checkbox change. Do not submit the same todo "
                + "again. Continue a concrete pending step, then re-send the full checklist "
                + "with real progress checked. If the remaining work cannot continue, call "
                + "`complete(summary)` with an honest blocked result.",
            tool: "todo",
            retryable: true,
            metadata: [
                "reason": todoNoProgressReason,
                "executed": false,
                "pending_todo_items": pending,
            ]
        )
    }

    static func isTodoNoProgressResult(_ result: String) -> Bool {
        guard ToolEnvelope.isError(result),
            let data = result.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return object["reason"] as? String == todoNoProgressReason
    }

    static func isStaleSessionTodoCompleteResult(_ result: String) -> Bool {
        guard ToolEnvelope.isError(result),
            let data = result.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return object["reason"] as? String == CompleteTool.staleSessionTodoReason
    }

    static func isRecoverableTodoContractResult(_ result: String) -> Bool {
        isTaskTrackingRequiredResult(result)
            || isTodoProgressUpdateRequiredResult(result)
            || isTodoNoProgressResult(result)
            || isStaleSessionTodoCompleteResult(result)
    }

    /// Typed stop policy: malformed arguments, missing paths, timeouts, and
    /// retryable execution failures go back to the model for one correction.
    /// Explicit user denials and policy/security refusals stop immediately.
    /// Repeating an identical failing call also stops, preventing a correction
    /// loop from spinning on the same envelope.
    /// `invocations` with each tool name replaced by its canonical form
    /// (`AgentTaskState.canonicalToolName`) when — and only when — the
    /// emitted name is NOT authorized but the canonical one IS. Everything
    /// else is returned untouched, including every call when the surface
    /// publishes no scope (`authorizedToolNames == nil`).
    static func canonicalizedInvocations(
        _ invocations: [ServiceToolInvocation],
        authorizedToolNames: Set<String>?
    ) -> [ServiceToolInvocation] {
        guard let authorized = authorizedToolNames else { return invocations }
        return invocations.map { invocation in
            let raw = invocation.toolName
            guard !authorized.contains(raw) else { return invocation }
            let canonical = AgentTaskState.canonicalToolName(raw)
            guard canonical != raw, authorized.contains(canonical) else { return invocation }
            print("[Osaurus][Loop] canonicalized tool name raw=\(raw) -> \(canonical)")
            return ServiceToolInvocation(
                toolName: canonical,
                jsonArguments: invocation.jsonArguments,
                toolCallId: invocation.toolCallId,
                geminiThoughtSignature: invocation.geminiThoughtSignature
            )
        }
    }

    static func shouldStopAfterToolOutcome(_ outcome: AgentLoopToolOutcome) -> Bool {
        guard outcome.wasError || ToolEnvelope.isError(outcome.result) else { return false }
        if outcome.wasDeduped { return true }
        if isRecoverableTodoContractResult(outcome.result) { return false }
        if isTerminalDesktopSubagentFailure(
            toolName: outcome.invocation.toolName,
            result: outcome.result
        ) {
            return true
        }
        guard let data = outcome.result.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let kind = object["kind"] as? String
        else {
            // Legacy/untyped failures are hard to correct safely.
            return outcome.wasError
        }
        if kind == ToolEnvelope.Kind.userDenied.rawValue
            || kind == ToolEnvelope.Kind.rejected.rawValue
        {
            return true
        }
        // Runtime, availability, path, and argument failures get one model
        // correction regardless of the as-is retry hint. An identical replay
        // is caught by the dedupe branch above.
        return false
    }

    static func todoProgressUpdateRequiredNotice(pending: Int) -> String {
        "[System Notice] Your completion was rejected because \(pending) todo item"
            + (pending == 1 ? " is" : "s are")
            + " still unchecked and tools ran after the last checklist update. Re-send the full "
            + "todo now with completed work checked. If work remains blocked after that update, "
            + "call `complete` again with an honest blocked summary."
    }

    static func taskTrackingRequiredNotice(threshold: Int) -> String {
        "[System Notice] This run reached \(threshold) ordinary tool actions without the "
            + "required current-run todo. The rejected tool was not executed. Call "
            + "`todo(markdown)` now and retry it, or give the user a complete final answer "
            + "without another tool call."
    }

    static func todoNoProgressNotice(pending: Int) -> String {
        "[System Notice] Your todo update was rejected because it exactly repeated the "
            + "current checklist with \(pending) unchecked item\(pending == 1 ? "" : "s"). "
            + "Do not call todo unchanged again. Continue a concrete step and then record a "
            + "real checkbox/task change, or call `complete(summary)` with an honest blocked "
            + "result if the remaining work cannot continue."
    }

    /// Whether a batch carries a loop-ending intercept tool.
    static func containsIntercept(
        _ calls: [(invocation: ServiceToolInvocation, callId: String)]
    ) -> Bool {
        calls.contains { interceptToolNames.contains($0.invocation.toolName) }
    }

    /// Whether a tool execution produced a SUCCESSFUL intercept — the
    /// surface should flag `endRun` exactly as chat does. Failed intercept
    /// envelopes (e.g. a rejected placeholder `complete` summary) fall
    /// through so the model sees the failure and retries.
    static func isSuccessfulIntercept(toolName: String, result: String) -> Bool {
        interceptToolNames.contains(toolName) && !ToolEnvelope.isError(result)
    }

    /// One-line transient nudge staged when the session's todo list has
    /// gone stale mid-run (unchecked items, no `todo` call for
    /// `todoStalenessThreshold` iterations). Rides the same notice channel
    /// as the budget warning — never persisted into history.
    static func todoStalenessNotice(pending: Int) -> String {
        "[System Notice] Your todo list still has \(pending) unchecked item\(pending == 1 ? "" : "s") and has not been updated recently. If you finished any, re-send the full list with those boxes checked now; if the plan changed, rewrite the list."
    }

    /// Read structured checklist counts from the real Todo invocation body.
    /// This is deliberately parser-based, not a prose/result-text heuristic,
    /// and preserves the order of multiple Todo updates in one tool batch.
    static func todoProgressSnapshot(
        from invocation: ServiceToolInvocation
    ) -> AgentTodoProgressSnapshot? {
        guard invocation.toolName == "todo",
            let data = invocation.jsonArguments.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let markdown = dict["markdown"] as? String
        else { return nil }
        let todo = AgentTodo.parse(markdown)
        guard todo.totalCount > 0 else { return nil }
        return AgentTodoProgressSnapshot(done: todo.doneCount, total: todo.totalCount)
    }

    /// Read the parsed task texts + checkbox states from a Todo invocation.
    /// This deliberately ignores non-checklist prose/formatting so cosmetic
    /// rewrites cannot masquerade as progress.
    static func todoSemanticSnapshot(
        from invocation: ServiceToolInvocation
    ) -> AgentTodoSemanticSnapshot? {
        guard invocation.toolName == "todo",
            let data = invocation.jsonArguments.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let markdown = dict["markdown"] as? String
        else { return nil }
        let todo = AgentTodo.parse(markdown)
        guard !todo.items.isEmpty else { return nil }
        return AgentTodoSemanticSnapshot(
            items: todo.items.map {
                AgentTodoSemanticSnapshot.Item(text: $0.text, isDone: $0.isDone)
            }
        )
    }

    // Capability schemas loaded mid-run are delivered append-only in the
    // `capabilities_load` tool *result* (see
    // `CapabilitiesLoadTool.loadedSchemaBlock`), never by rewriting the frozen
    // `<tools>` prefix. That keeps the paged-KV prefix byte-stable across the
    // run while the model still gets same-turn, call-by-name visibility
    // (registry dispatch is name-based). Loaded tools fold into the rendered
    // `<tools>` block on the next user turn via `frozenAlwaysLoadedNames`.

    /// Stable call-id assignment: preserve the model-supplied id when
    /// present (OpenAI `call_xxx`), otherwise mint one in the same shape.
    static func callId(for invocation: ServiceToolInvocation) -> String {
        if let preserved = invocation.toolCallId, !preserved.isEmpty {
            return preserved
        }
        let raw = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        return "call_" + String(raw.prefix(24))
    }

    /// Short, stable fingerprint of an outbound message array, for Router
    /// billing idempotency keys. The loop's iteration counter alone is NOT a
    /// safe key component: budget-refunded iterations (data-movement relief,
    /// empty-turn retries) reuse the same counter value with a *different*
    /// request body, which the Router rejects as `IDEMPOTENCY_CONFLICT`
    /// (HTTP 409). Suffixing the key with this fingerprint keeps genuine
    /// re-POSTs (`retryWithoutCharge` replays the identical messages)
    /// deduping on the same key while any body change mints a fresh one.
    ///
    /// Covers every field that reaches the wire per message: role, content,
    /// tool_call_id, reasoning content, tool calls (id/name/arguments), and
    /// multimodal content parts. Field and message boundaries are separated
    /// with control bytes so adjacent fields can't collide by concatenation.
    static func stepIdempotencyFingerprint(messages: [ChatMessage]) -> String {
        var hasher = SHA256()
        func feed(_ value: String) {
            hasher.update(data: Data(value.utf8))
            hasher.update(data: Data([0x1F]))  // unit separator between fields
        }
        for message in messages {
            feed(message.role)
            feed(message.content ?? "")
            feed(message.tool_call_id ?? "")
            feed(message.reasoning_content ?? "")
            for call in message.tool_calls ?? [] {
                feed(call.id)
                feed(call.function.name)
                feed(call.function.arguments)
            }
            for part in message.contentParts ?? [] {
                switch part {
                case .text(let text):
                    feed("text:" + text)
                case .imageUrl(let url, let detail):
                    feed("image:" + (detail ?? "") + ":" + url)
                case .audioInput(let data, let format):
                    feed("audio:" + format + ":" + data)
                case .videoUrl(let url):
                    feed("video:" + url)
                }
            }
            hasher.update(data: Data([0x1E]))  // record separator between messages
        }
        return hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Stable suffix for one logical generation attempt. Transport retries
    /// reuse the same recovery ordinal and therefore the same key; the one
    /// deliberate reasoning recovery increments it so a billing/router
    /// idempotency layer cannot replay attempt 1 instead of generating attempt
    /// 2 from the otherwise-identical message body.
    static func recoveryAwareIdempotencySuffix(
        messages: [ChatMessage],
        incompleteReasoningRetryOrdinal: Int
    ) -> String {
        "r\(max(0, incompleteReasoningRetryOrdinal))-"
            + stepIdempotencyFingerprint(messages: messages)
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
        // The `tool_not_found` notice lists what the request may execute;
        // the surface's scope is the only source of that truth.
        if let authorizedToolNames = hooks.authorizedToolNames {
            state.authorizedToolNamesProvider = authorizedToolNames
        }
        // Staged-notice slots, mirroring the historical chat locals
        // (`pendingBudgetNotice` / `pendingStateNotice`). The state slot
        // holds an ORDERED, de-duplicated list rather than a single string:
        // per-event signals (dedupe, escalation, no-tool-call recoveries)
        // still replace it so the LAST one in a batch wins, exactly as the
        // per-call overwrite did in `ChatSession.send`, while independent
        // advisories staged later in the same iteration (task-tracking,
        // data-movement relief, ungrounded file claims) COMPOSE onto it.
        // Before this, `taskTrackingRequiredNotice` / `dataMovementReliefNotice`
        // silently dropped the invalid-args notice `AgentTaskState.nextStepBias`
        // had just staged. The bias notice always rides first.
        var pendingBudgetNotice: String?
        var pendingStateNotices: [String] = []
        var stagedBiasNotice: String?
        var pendingTodoNotice: String?
        /// Per-event replace: the historical single-slot overwrite.
        func replaceStateNotice(_ notice: String) {
            pendingStateNotices = [notice]
            stagedBiasNotice = nil
        }
        /// Compose: append unless an identical notice is already staged.
        func stageStateNotice(_ notice: String) {
            guard !pendingStateNotices.contains(notice) else { return }
            pendingStateNotices.append(notice)
        }
        /// The next-step bias (invalid-args, listing nudge, ...) goes FIRST
        /// and a later bias in the same batch supersedes an earlier one
        /// (last bias wins, as before) without touching the other staged
        /// advisories.
        func stageBiasNotice(_ bias: String) {
            let notice = "[System Notice] " + bias
            if let previous = stagedBiasNotice {
                pendingStateNotices.removeAll { $0 == previous }
            }
            pendingStateNotices.removeAll { $0 == notice }
            pendingStateNotices.insert(notice, at: 0)
            stagedBiasNotice = notice
        }
        // Consecutive empty (0-token / no-tool) turns this run. Reset by any
        // productive turn; bounds the nudge-and-retry recovery so the loop
        // can never spin on a deterministically-empty model.
        var consecutiveEmptyTurns = 0
        // Grounded-claim invariant state: whether any `osaurus_config` apply
        // landed a real change this run, and how many corrective retries the
        // final-response check has consumed (bounded, never editing output).
        var hasGroundedConfigApply = false
        var groundedClaimRetries = 0
        // File side-effect grounding (`GroundedFileSideEffectCheck`): whether
        // any file-writing tool succeeded this run, and how many advisory
        // notices tool-calling turns have staged (bounded).
        var hasGroundedFileWrite = false
        var ungroundedFileClaimNotices = 0
        // Knowledge grounding (`GroundedKnowledgeClaimCheck`): whether any
        // knowledge read SUCCEEDED this run, and the most recent knowledge
        // read that FAILED (tool + envelope). A final answer that describes
        // the collection after only failures gets the factual notice.
        var hasGroundedKnowledgeRead = false
        var lastFailedKnowledgeRead: (tool: String, result: String)? = nil
        // Consecutive announce-only turns (visible "let me…" preamble, no
        // call). Reset by any productive turn, for the same reason.
        var consecutiveAnnouncedToolCalls = 0
        // Total repetition-loop recoveries this run.
        var repetitionLoopRetries = 0
        // Consecutive "shall I continue?" hand-backs this run.
        var consecutiveContinuationRequests = 0
        // Total (not merely consecutive) reasoning-only recovery attempts.
        // A tool call between attempts must not re-arm another potentially
        // huge reasoning cycle in the same logical run.
        var incompleteReasoningRetries = 0
        // Diagnostic-only RUN TOTALS. The three `consecutive*` counters above
        // are reset by a successful `.toolCalls` step, so reading them at exit
        // reports the current streak rather than what the run actually spent —
        // an alternating stall/tool pattern would report zero. These never
        // reset, so `RunResult.recoveryCounters` describes the whole run.
        // Nothing branches on them.
        var totalEmptyTurnRetries = 0
        var totalAnnouncedToolCallRetries = 0
        var totalContinuationRequestRetries = 0

        /// Emit the exit diagnostics for this run. Called immediately before
        /// each labelled `return`, so `origin` names the branch that actually
        /// decided the outcome — the distinction `Exit` alone cannot make for
        /// `.finalResponse`, which six different sites produce.
        func recordExit(_ exit: Exit, _ origin: ExitOrigin) async {
            await hooks.recordExitDiagnostics?(
                ExitDiagnostics(
                    exit: exit,
                    origin: origin,
                    counters: RecoveryCounters(
                        emptyTurn: totalEmptyTurnRetries,
                        announcedToolCall: totalAnnouncedToolCallRetries,
                        continuationRequest: totalContinuationRequestRetries,
                        repetitionLoop: repetitionLoopRetries,
                        incompleteReasoning: incompleteReasoningRetries)))
        }

        /// Close a fail-closed tool rejection visibly. This runs only after
        /// cancellation has been checked, so Stop/cancel retains its own
        /// terminal semantics and never gains a synthetic denial message.
        func emitToolRejection(_ outcome: AgentLoopToolOutcome) async {
            await hooks.emitToolRejectionText?(ToolEnvelope.failureMessage(outcome.result))
        }
        // Total oversized streamed-call recoveries. One typed retry gives a
        // model a chance to switch to bounded/chunked writes without allowing
        // another unbounded decode loop.
        var oversizedToolCallRetries = 0
        // Separate from ordinary length exhaustion: only a stream that began
        // a real tool envelope receives this bounded protocol retry.
        var truncatedToolCallRetries = 0
        // Session Todo state persists for the UI, while terminal semantics are
        // per logical run. Bind this same marker around every serial or batched
        // tool dispatch so TodoTool and CompleteTool agree even when a batch
        // executes in child tasks.
        let todoRunScope = AgentTodoRunScope()
        let permissionRunScope = ToolPermissionRunScope()
        // Session Todo state persists across user turns. Arm terminal gating
        // only after THIS run successfully executes a valid `todo`; an older
        // stale checklist must never hijack an unrelated direct answer.
        var hasSuccessfulCurrentRunTodo = false
        // Keep the last parseable current-run checklist as a fail-closed
        // fallback. The session store is authoritative when available, but a
        // transient missing lookup must not turn known unchecked work into a
        // clean final response.
        var lastSuccessfulCurrentRunTodoProgress: AgentTodoProgressSnapshot?
        // Last iteration that carried a `todo` call (0 = run start), for
        // the staleness check below.
        var lastTodoIteration = 0
        // Data-movement relief bookkeeping: how many bulk-load iterations
        // have been refunded so far, and whether we've told the model about
        // the relief yet (staged once per run).
        var dataMovementStepsUsed = 0
        var announcedDataMovementRelief = false
        var completedToolWork = false
        func taskTrackingPreconditionResult(
            for _: ServiceToolInvocation,
            batchContainsParseableTodo _: Bool
        ) -> String? {
            // Todo is advisory UI state, not a runtime lock.
            nil
        }

        func todoProgressUpdatePreconditionResult(
            for _: ServiceToolInvocation,
            batchContainsPrecedingParseableTodo _: Bool
        ) -> String? {
            // A stale checklist must remain visible and honest, but it must not
            // veto the model's explicit completion. Models frequently finish
            // real work without rewriting Todo; rejecting completion here
            // causes repeated summaries and unrelated follow-up actions.
            nil
        }

        func todoNoProgressPreconditionResult(
            for _: ServiceToolInvocation
        ) -> String? {
            // Re-sending an unchanged checklist is harmless model behavior.
            // Turning it into a retryable tool error made Qwen/Ornith repeat
            // Todo forever instead of returning to the actual pending action.
            nil
        }

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
            if !pendingStateNotices.isEmpty {
                notices.append(contentsOf: pendingStateNotices)
                pendingStateNotices.removeAll()
                stagedBiasNotice = nil
            }
            if let n = pendingTodoNotice {
                notices.append(n)
                pendingTodoNotice = nil
            }
            let input = await hooks.buildMessages(notices)
            if input.overBudget {
                // Even fully-compacted history can't fit — the request is
                // doomed. End cleanly before the model step; the failed
                // build doesn't charge the iteration budget.
                return RunResult(exit: .overBudget, iterations: iteration - 1)
            }

            let step = try await hooks.modelStep(input.messages, iteration)
            // `modelStep` may return because the user pressed Stop and the
            // surface cancelled its upstream stream. Cancellation must win
            // before terminal classification: otherwise a cancelled,
            // reasoning-only turn can prepare continuation state (or emit an
            // incomplete fallback) even though no follow-up generation should
            // occur.
            if await hooks.isCancelled() {
                return RunResult(exit: .cancelled, iterations: iteration - 1)
            }
            switch step {
            case .finalResponse:
                // Grounded-claim invariant (user-approved honest-state
                // reflection, see `GroundedConfigClaimCheck`): a final answer
                // that IS a fabricated tool envelope, or that claims a config
                // change no apply actually landed, gets the factual notice
                // staged and one bounded regeneration. Both hooks are
                // required — without the retry boundary a streaming surface
                // would splice two attempts into one answer.
                if let finalVisibleText = hooks.finalVisibleText,
                    let prepareRetry = hooks.prepareGroundedClaimRetry,
                    groundedClaimRetries < Self.maxGroundedClaimRetries,
                    let visibleText = await finalVisibleText(),
                    let notice = GroundedConfigClaimCheck.notice(
                        finalText: visibleText,
                        hasGroundedApply: hasGroundedConfigApply
                    )
                {
                    groundedClaimRetries += 1
                    print(
                        "[Osaurus] Grounded-claim guard tripped "
                            + "(retry \(groundedClaimRetries)/\(Self.maxGroundedClaimRetries), "
                            + "groundedApply=\(hasGroundedConfigApply)): "
                            + String(notice.prefix(140))
                    )
                    replaceStateNotice(notice)
                    await prepareRetry()
                    // Protocol correction, not agent progress — don't charge
                    // the tool-iteration budget (same as the empty-turn path).
                    iteration -= 1
                    continue
                }
                // File side-effect grounding on a final answer ("I've saved
                // the report" with no file-writing tool landed this run):
                // same bounded, notice-and-regenerate channel as above. The
                // model writes its own corrected answer — either it calls
                // the file tool now, or it says nothing was written.
                if let assistantVisibleText = hooks.assistantVisibleText,
                    let prepareRetry = hooks.prepareGroundedClaimRetry,
                    !hasGroundedFileWrite,
                    groundedClaimRetries < Self.maxGroundedClaimRetries,
                    let visibleText = await assistantVisibleText(),
                    GroundedFileSideEffectCheck.containsFileSideEffectClaim(visibleText)
                {
                    groundedClaimRetries += 1
                    print(
                        "[Osaurus] Ungrounded file side-effect claim in final answer "
                            + "(retry \(groundedClaimRetries)/\(Self.maxGroundedClaimRetries)); "
                            + "no file-writing tool succeeded this run"
                    )
                    replaceStateNotice(GroundedFileSideEffectCheck.ungroundedFileClaimNotice)
                    await prepareRetry()
                    iteration -= 1
                    continue
                }
                // Knowledge grounding on a final answer ("the vault contains
                // 20 documents" when the only knowledge call this run was an
                // `invalid_args` rejection): same bounded notice-and-
                // regenerate channel. The notice repeats the granted
                // collection names the failed envelope already listed, so
                // the corrected turn can retry with the right `collection`
                // — or say plainly that the collection could not be read.
                if let assistantVisibleText = hooks.assistantVisibleText,
                    let prepareRetry = hooks.prepareGroundedClaimRetry,
                    !hasGroundedKnowledgeRead,
                    let failed = lastFailedKnowledgeRead,
                    groundedClaimRetries < Self.maxGroundedClaimRetries,
                    let visibleText = await assistantVisibleText(),
                    GroundedKnowledgeClaimCheck.containsCollectionContentClaim(visibleText)
                {
                    groundedClaimRetries += 1
                    print(
                        "[Osaurus] Ungrounded knowledge-content claim in final answer "
                            + "(retry \(groundedClaimRetries)/\(Self.maxGroundedClaimRetries)); "
                            + "\(failed.tool) failed and no knowledge read succeeded this run"
                    )
                    replaceStateNotice(
                        GroundedKnowledgeClaimCheck.ungroundedKnowledgeClaimNotice(
                            tool: failed.tool,
                            grantedNames: GroundedKnowledgeClaimCheck.grantedCollectionNames(
                                inFailure: failed.result
                            )
                        )
                    )
                    await prepareRetry()
                    iteration -= 1
                    continue
                }
                // An ordinary model final is authoritative. Todo is visible
                // progress metadata; it must never override EOS/stop and make
                // the driver regenerate the same answer until the step cap.
                await recordExit(.finalResponse, .ordinaryModelFinal)
                return RunResult(exit: .finalResponse, iterations: iteration)

            case .retryWithoutCharge:
                // Don't charge the iteration budget. Staged notices were
                // consumed by the failed attempt and are not replayed —
                // matching the historical chat behavior where the pending
                // slots were cleared before the stream error surfaced.
                iteration -= 1
                continue

            case .oversizedToolCall(let toolName, let argumentCharacters):
                oversizedToolCallRetries += 1
                if oversizedToolCallRetries <= Self.maxOversizedToolCallRetries {
                    replaceStateNotice(Self.oversizedToolCallNotice(
                        toolName: toolName,
                        argumentCharacters: argumentCharacters
                    ))
                    iteration -= 1
                    continue
                }
                await hooks.emitFallbackText?(Self.oversizedToolCallFallback)
                return RunResult(exit: .oversizedToolCallExhausted, iterations: iteration)

            case .truncatedToolCall(let toolName, let argumentCharacters):
                truncatedToolCallRetries += 1
                if truncatedToolCallRetries <= Self.maxTruncatedToolCallRetries {
                    replaceStateNotice(Self.truncatedToolCallNotice(
                        toolName: toolName,
                        argumentCharacters: argumentCharacters
                    ))
                    iteration -= 1
                    continue
                }
                await hooks.emitFallbackText?(Self.truncatedToolCallFallback)
                return RunResult(exit: .truncatedToolCallExhausted, iterations: iteration)

            case .emptyResponse:
                // The model produced no visible text and no tool call. Never
                // end the run on a silent empty turn: nudge-and-retry a
                // bounded number of times (the notice perturbs the prompt so
                // a temp-0 model that just emitted EOS produces text), then
                // emit a fallback message so the user always sees something.
                consecutiveEmptyTurns += 1
                totalEmptyTurnRetries += 1
                if consecutiveEmptyTurns <= Self.maxEmptyTurnRetries {
                    replaceStateNotice(Self.emptyTurnNotice)
                    // Not charged against the tool-iteration budget.
                    iteration -= 1
                    continue
                }
                if completedToolWork {
                    await hooks.emitFallbackText?(Self.emptyToolTaskFallback)
                    return RunResult(exit: .emptyResponseExhausted, iterations: iteration)
                }
                // Recovery exhausted: guarantee a visible message instead of
                // a silent dead-end, then end the run.
                await hooks.emitFallbackText?(Self.emptyTurnFallback)
                await recordExit(.finalResponse, .emptyTurnRecoveryExhausted)
                return RunResult(exit: .finalResponse, iterations: iteration)

            case .announcedToolCall:
                // The model announced a call and stopped. Treating that as a
                // final answer is what makes tools look silently broken, so
                // nudge-and-retry instead. On exhaustion, accept the text as
                // the final answer rather than emitting a fallback: unlike an
                // empty turn, the user already has something on screen, and
                // replacing it would retract visible content.
                consecutiveAnnouncedToolCalls += 1
                totalAnnouncedToolCallRetries += 1
                if consecutiveAnnouncedToolCalls <= Self.maxAnnouncedToolCallRetries {
                    replaceStateNotice(Self.announcedToolCallNotice)
                    // Not charged against the tool-iteration budget.
                    iteration -= 1
                    continue
                }
                await recordExit(.finalResponse, .announcedToolCallRecoveryExhausted)
                return RunResult(exit: .finalResponse, iterations: iteration)

            case .continuationRequest:
                // Asking "would you like me to continue?" is only a stall when
                // there IS tracked work left. With nothing pending it is a
                // real question and the user should get it, so fall through to
                // an ordinary final response rather than talking past them.
                // Matches the todo-staleness call shape below: unwrap the hook
                // first, then await it. A surface that supplies no hook has no
                // tracked work to appeal to, so the question stands.
                var pending = 0
                if let pendingTodoCount = hooks.pendingTodoCount {
                    pending = await pendingTodoCount()
                }
                guard pending > 0 else {
                    await recordExit(.finalResponse, .continuationRequestNoPendingWork)
                    return RunResult(exit: .finalResponse, iterations: iteration)
                }
                consecutiveContinuationRequests += 1
                totalContinuationRequestRetries += 1
                if consecutiveContinuationRequests <= Self.maxContinuationRequestRetries {
                    replaceStateNotice(Self.continuationRequestNotice(pending: pending))
                    // Not charged against the tool-iteration budget.
                    iteration -= 1
                    continue
                }
                // Recovery spent: the model will not proceed on its own. Hand
                // the question to the user rather than looping on it — the
                // text is already on screen and is a reasonable thing to end
                // on once we have tried twice.
                await recordExit(.finalResponse, .continuationRequestRecoveryExhausted)
                return RunResult(exit: .finalResponse, iterations: iteration)

            case .repetitionLoop(let phrase):
                repetitionLoopRetries += 1
                if repetitionLoopRetries <= Self.maxRepetitionLoopRetries {
                    replaceStateNotice(Self.repetitionLoopNotice(phrase: phrase))
                    // Not charged against the tool-iteration budget.
                    iteration -= 1
                    continue
                }
                await hooks.emitFallbackText?(Self.repetitionLoopFallback)
                return RunResult(exit: .repetitionLoopExhausted, iterations: iteration)

            case .lengthExhausted:
                // `stop=length` is authoritative. Do not mislabel a
                // reasoning-only capped turn as successful task completion,
                // and do not auto-retry it with a synthetic prompt: a model
                // already looping in reasoning can consume the cap repeatedly.
                await hooks.emitFallbackText?(Self.lengthExhaustedFallback)
                return RunResult(exit: .lengthExhausted, iterations: iteration)

            case .incompleteReasoning:
                if let prepareRetry = hooks.prepareIncompleteReasoningContinuation,
                    incompleteReasoningRetries < Self.maxIncompleteReasoningRetries
                {
                    incompleteReasoningRetries += 1
                    // Keep the incomplete reasoning visible to the surface,
                    // but replay the exact pre-attempt model-visible history
                    // from a fresh output buffer. No synthetic notice, closing
                    // tag, prompt coercion, sampler override, or EOS override
                    // is introduced here.
                    await prepareRetry()
                    // This is protocol continuation rather than agent/tool
                    // progress, so do not charge it against the tool budget.
                    iteration -= 1
                    continue
                }
                return RunResult(
                    exit: .incompleteReasoningExhausted,
                    iterations: iteration
                )

            case .incompleteVisibleResponse:
                // The surface has already emitted visible content, so a
                // transparent replay would splice two attempts into one
                // answer. Return the typed incomplete exit and let each
                // surface render its native error/banner without retrying.
                return RunResult(
                    exit: .incompleteReasoningExhausted,
                    iterations: iteration
                )

            case .toolCalls(let emittedInvocations):
                // Fold hallucinated punctuation around an AUTHORIZED name
                // (`osaurus_help!!`) back onto the real tool before anything
                // materialises or executes. A name whose canonical form is
                // not in scope is left exactly as emitted, so the registry's
                // `tool_not_found` still answers it — decoration never
                // reaches a withheld tool.
                let invocations = Self.canonicalizedInvocations(
                    emittedInvocations,
                    authorizedToolNames: hooks.authorizedToolNames?()
                )
                // A productive turn — reset the empty-turn and announce-only
                // recovery budgets so a later unrelated stall gets its own
                // fresh allowance.
                consecutiveEmptyTurns = 0
                consecutiveAnnouncedToolCalls = 0
                consecutiveContinuationRequests = 0

                // File side-effect advisory (`GroundedFileSideEffectCheck`):
                // capture this message's visible narration BEFORE any tool
                // runs — chat's `onBatchComplete` swaps in a fresh assistant
                // buffer, so reading afterwards would see the empty next turn.
                var toolCallVisibleText: String? = nil
                if let assistantVisibleText = hooks.assistantVisibleText {
                    toolCallVisibleText = await assistantVisibleText()
                }

                // A desktop subagent already completed successfully, and the
                // very next model step emitted only a malformed repeat of that
                // same tool. Do not materialise or execute the duplicate call:
                // finish with the prior tool's real summary. Requiring the
                // surface text hook keeps this recovery on user-facing chat;
                // headless/API surfaces retain their existing invalid-args
                // contract instead of silently manufacturing a response.
                if invocations.count == 1,
                    let invocation = invocations.first,
                    let summary = Self.completedDesktopSummaryBeforeMalformedRepeat(
                        invocation: invocation,
                        state: state
                    ),
                    let emitFinalText = hooks.emitFallbackText
                {
                    await emitFinalText(summary)
                    await recordExit(.finalResponse, .desktopSummarySubstituted)
                    return RunResult(exit: .finalResponse, iterations: iteration)
                }

                var outcomes: [AgentLoopToolOutcome] = []
                outcomes.reserveCapacity(invocations.count)
                // A valid Todo in the same model-emitted batch satisfies the
                // precondition for its sibling actions. The actual successful
                // outcome still arms terminal tracking below; malformed Todo
                // arguments cannot bypass this gate.
                let batchContainsParseableTodo = invocations.contains {
                    Self.todoProgressSnapshot(from: $0) != nil
                }
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
                    var batchHasPrecedingParseableTodo = false
                    for (slot, invocation) in invocations.enumerated() {
                        let callId = Self.callId(for: invocation)
                        await hooks.willProcessCall(invocation, callId)
                        let invocationHasParseableTodo =
                            Self.todoProgressSnapshot(from: invocation) != nil
                        if let trackingRequired = taskTrackingPreconditionResult(
                            for: invocation,
                            batchContainsParseableTodo: batchContainsParseableTodo
                        ) {
                            slotted[slot] = AgentLoopToolOutcome(
                                invocation: invocation,
                                callId: callId,
                                result: trackingRequired,
                                wasDeduped: false,
                                wasError: true
                            )
                            continue
                        }
                        if let noProgress = todoNoProgressPreconditionResult(
                            for: invocation
                        ) {
                            slotted[slot] = AgentLoopToolOutcome(
                                invocation: invocation,
                                callId: callId,
                                result: noProgress,
                                wasDeduped: false,
                                wasError: true
                            )
                            continue
                        }
                        if let progressUpdateRequired = todoProgressUpdatePreconditionResult(
                            for: invocation,
                            batchContainsPrecedingParseableTodo:
                                batchHasPrecedingParseableTodo
                        ) {
                            slotted[slot] = AgentLoopToolOutcome(
                                invocation: invocation,
                                callId: callId,
                                result: progressUpdateRequired,
                                wasDeduped: false,
                                wasError: true
                            )
                            continue
                        }
                        if invocationHasParseableTodo {
                            batchHasPrecedingParseableTodo = true
                        }
                        if let guarded = state.guardedResult(
                            name: invocation.toolName,
                            argsJSON: invocation.jsonArguments
                        ) {
                            slotted[slot] = AgentLoopToolOutcome(
                                invocation: invocation,
                                callId: callId,
                                result: guarded,
                                wasDeduped: false,
                                wasError: ToolEnvelope.isError(guarded)
                            )
                            continue
                        }
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
                                wasError: ToolEnvelope.isError(held)
                            )
                            // A held-ERROR replay escalates on every surface
                            // (it is a correctness signal, not chat polish);
                            // fresh-read replays keep the per-policy notice.
                            if let escalation = state.lastReplayNotice {
                                replaceStateNotice("[System Notice] " + escalation)
                            } else if policy.dedupeNoticeEnabled {
                                replaceStateNotice(Self.dedupeNotice)
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
                        let executions =
                            await ChatExecutionContext.$agentTodoRunScope.withValue(
                                todoRunScope
                            ) {
                                await ChatExecutionContext.$toolPermissionRunScope.withValue(
                                    permissionRunScope
                                ) {
                                    await executeBatch(
                                        toExecute.map { ($0.invocation, $0.callId) }
                                    )
                                }
                            }
                        // The executor may legitimately return FEWER results
                        // than calls (chat stops executing the rest of a
                        // batch after an intercept); missing slots stay nil
                        // and are excluded from outcomes/recording, exactly
                        // like serial calls that never ran.
                        for (index, entry) in toExecute.enumerated()
                        where index < executions.count {
                            let execution = executions[index]
                            let wasError =
                                execution.isError
                                || ToolEnvelope.isError(execution.result)
                                || Self.isTerminalDesktopSubagentFailure(
                                    toolName: entry.invocation.toolName,
                                    result: execution.result
                                )
                            slotted[entry.slot] = AgentLoopToolOutcome(
                                invocation: entry.invocation,
                                callId: entry.callId,
                                result: execution.result,
                                wasDeduped: false,
                                wasError: wasError
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
                                    wasError: ToolEnvelope.isError(held)
                                )
                                if let escalation = state.lastReplayNotice {
                                    replaceStateNotice("[System Notice] " + escalation)
                                } else if policy.dedupeNoticeEnabled {
                                    replaceStateNotice(Self.dedupeNotice)
                                }
                            } else {
                                let deferredExecutions =
                                    await ChatExecutionContext.$agentTodoRunScope.withValue(
                                        todoRunScope
                                    ) {
                                        await ChatExecutionContext.$toolPermissionRunScope.withValue(
                                            permissionRunScope
                                        ) {
                                            await executeBatch(
                                                [(deferred.invocation, deferred.callId)]
                                            )
                                        }
                                    }
                                guard let execution = deferredExecutions.first else {
                                    continue
                                }
                                let wasError =
                                    execution.isError
                                    || ToolEnvelope.isError(execution.result)
                                    || Self.isTerminalDesktopSubagentFailure(
                                        toolName: deferred.invocation.toolName,
                                        result: execution.result
                                    )
                                slotted[slot] = AgentLoopToolOutcome(
                                    invocation: deferred.invocation,
                                    callId: deferred.callId,
                                    result: execution.result,
                                    wasDeduped: false,
                                    wasError: wasError
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
                        stageBiasNotice(bias)
                    }
                    outcomes = slotted.compactMap { $0 }
                    if outcomes.contains(where: {
                        Self.isTaskTrackingRequiredResult($0.result)
                    }) {
                        stageStateNotice(
                            Self.taskTrackingRequiredNotice(
                                threshold: policy.todoRequiredBeforeToolCallCount
                            )
                        )
                    }
                    if let pending = outcomes.compactMap({ outcome -> Int? in
                        guard Self.isTodoProgressUpdateRequiredResult(outcome.result),
                            let data = outcome.result.data(using: .utf8),
                            let object = try? JSONSerialization.jsonObject(with: data)
                                as? [String: Any]
                        else { return nil }
                        return object["pending_todo_items"] as? Int
                    }).last {
                        pendingTodoNotice = Self.todoProgressUpdateRequiredNotice(
                            pending: pending
                        )
                    }
                    if let pending = outcomes.compactMap({ outcome -> Int? in
                        guard Self.isTodoNoProgressResult(outcome.result),
                            let data = outcome.result.data(using: .utf8),
                            let object = try? JSONSerialization.jsonObject(with: data)
                                as? [String: Any]
                        else { return nil }
                        return object["pending_todo_items"] as? Int
                    }).last {
                        pendingTodoNotice = Self.todoNoProgressNotice(pending: pending)
                    }
                    // Cancellation is honored only AFTER the executed batch
                    // is recorded — the surface history already contains
                    // these tool turns, so skipping `state.record` would
                    // desync the state machine from the transcript.
                    if await hooks.isCancelled() {
                        return await finishBatch(.cancelled)
                    }
                    if policy.stopOnToolRejection,
                        let rejected = outcomes.first(where: Self.shouldStopAfterToolOutcome)
                    {
                        await emitToolRejection(rejected)
                        return await finishBatch(.toolRejected)
                    }
                } else {
                    // Serial mode (chat/plugin semantics): interleaved dedupe
                    // and execution, per-call policy checks.
                    var batchHasPrecedingParseableTodo = false
                    for invocation in invocations {
                        if await hooks.isCancelled() {
                            return RunResult(exit: .cancelled, iterations: iteration)
                        }
                        let callId = Self.callId(for: invocation)
                        await hooks.willProcessCall(invocation, callId)
                        let invocationHasParseableTodo =
                            Self.todoProgressSnapshot(from: invocation) != nil

                        if let trackingRequired = taskTrackingPreconditionResult(
                            for: invocation,
                            batchContainsParseableTodo: batchContainsParseableTodo
                        ) {
                            state.record(
                                name: invocation.toolName,
                                argsJSON: invocation.jsonArguments,
                                result: trackingRequired
                            )
                            outcomes.append(
                                AgentLoopToolOutcome(
                                    invocation: invocation,
                                    callId: callId,
                                    result: trackingRequired,
                                    wasDeduped: false,
                                    wasError: true
                                )
                            )
                            stageStateNotice(
                                Self.taskTrackingRequiredNotice(
                                    threshold: policy.todoRequiredBeforeToolCallCount
                                )
                            )
                            continue
                        }
                        if let noProgress = todoNoProgressPreconditionResult(
                            for: invocation
                        ) {
                            state.record(
                                name: invocation.toolName,
                                argsJSON: invocation.jsonArguments,
                                result: noProgress
                            )
                            outcomes.append(
                                AgentLoopToolOutcome(
                                    invocation: invocation,
                                    callId: callId,
                                    result: noProgress,
                                    wasDeduped: false,
                                    wasError: true
                                )
                            )
                            pendingTodoNotice = Self.todoNoProgressNotice(
                                pending: lastSuccessfulCurrentRunTodoProgress?.pending ?? 0
                            )
                            continue
                        }
                        if let progressUpdateRequired = todoProgressUpdatePreconditionResult(
                            for: invocation,
                            batchContainsPrecedingParseableTodo:
                                batchHasPrecedingParseableTodo
                        ) {
                            state.record(
                                name: invocation.toolName,
                                argsJSON: invocation.jsonArguments,
                                result: progressUpdateRequired
                            )
                            outcomes.append(
                                AgentLoopToolOutcome(
                                    invocation: invocation,
                                    callId: callId,
                                    result: progressUpdateRequired,
                                    wasDeduped: false,
                                    wasError: true
                                )
                            )
                            if let pending = lastSuccessfulCurrentRunTodoProgress?.pending {
                                pendingTodoNotice = Self.todoProgressUpdateRequiredNotice(
                                    pending: pending
                                )
                            }
                            continue
                        }
                        if invocationHasParseableTodo {
                            batchHasPrecedingParseableTodo = true
                        }

                        // Bounded discovery guard: once the state machine has
                        // enough ranked sources, synthesize a structured
                        // transition result instead of paying for another
                        // rephrased provider call. The outcome still lands in
                        // surface history through `onBatchComplete` below.
                        if let guarded = state.guardedResult(
                            name: invocation.toolName,
                            argsJSON: invocation.jsonArguments
                        ) {
                            state.record(
                                name: invocation.toolName,
                                argsJSON: invocation.jsonArguments,
                                result: guarded
                            )
                            if let bias = state.nextStepBias() {
                                stageBiasNotice(bias)
                            }
                            let guardedOutcome = AgentLoopToolOutcome(
                                invocation: invocation,
                                callId: callId,
                                result: guarded,
                                wasDeduped: false,
                                wasError: ToolEnvelope.isError(guarded)
                            )
                            outcomes.append(guardedOutcome)
                            if policy.stopOnToolRejection,
                                Self.shouldStopAfterToolOutcome(guardedOutcome)
                            {
                                await hooks.onBatchComplete(outcomes)
                                await emitToolRejection(guardedOutcome)
                                return RunResult(exit: .toolRejected, iterations: iteration)
                            }
                            continue
                        }

                        // Consecutive-identical dedupe: replay the EXACT envelope
                        // the model already received instead of re-executing.
                        if let held = state.heldResult(
                            name: invocation.toolName,
                            argsJSON: invocation.jsonArguments
                        ) {
                            await hooks.onDedupedResult(invocation, callId, held)
                            let outcome = AgentLoopToolOutcome(
                                    invocation: invocation,
                                    callId: callId,
                                    result: held,
                                    wasDeduped: true,
                                    wasError: ToolEnvelope.isError(held)
                                )
                            outcomes.append(outcome)
                            if let escalation = state.lastReplayNotice {
                                replaceStateNotice("[System Notice] " + escalation)
                            } else if policy.dedupeNoticeEnabled {
                                replaceStateNotice(Self.dedupeNotice)
                            }
                            if policy.stopOnToolRejection,
                                Self.shouldStopAfterToolOutcome(outcome)
                            {
                                await emitToolRejection(outcome)
                                return RunResult(exit: .toolRejected, iterations: iteration)
                            }
                            continue
                        }

                        let execution =
                            await ChatExecutionContext.$agentTodoRunScope.withValue(
                                todoRunScope
                            ) {
                                await ChatExecutionContext.$toolPermissionRunScope.withValue(
                                    permissionRunScope
                                ) {
                                    await hooks.executeTool(invocation, callId)
                                }
                            }
                        let wasError =
                            execution.isError
                            || ToolEnvelope.isError(execution.result)
                            || Self.isTerminalDesktopSubagentFailure(
                                toolName: invocation.toolName,
                                result: execution.result
                            )

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
                            stageBiasNotice(bias)
                        }
                        outcomes.append(
                            AgentLoopToolOutcome(
                                invocation: invocation,
                                callId: callId,
                                result: execution.result,
                                wasDeduped: false,
                                wasError: wasError
                            )
                        )

                        if await hooks.isCancelled() {
                            return RunResult(exit: .cancelled, iterations: iteration)
                        }
                        if policy.stopOnToolRejection,
                            Self.shouldStopAfterToolOutcome(outcomes[outcomes.count - 1])
                        {
                            await emitToolRejection(outcomes[outcomes.count - 1])
                            return RunResult(exit: .toolRejected, iterations: iteration)
                        }
                    }
                }

                await hooks.onBatchComplete(outcomes)
                if outcomes.contains(where: {
                    !Self.isRecoverableTodoContractResult($0.result)
                }) {
                    completedToolWork = true
                }
                // Grounded-claim bookkeeping: remember when an apply landed a
                // real change so a later change claim in the final answer is
                // recognized as grounded.
                if !hasGroundedConfigApply,
                    outcomes.contains(where: {
                        GroundedConfigClaimCheck.isGroundedApplyOutcome(
                            toolName: $0.invocation.toolName,
                            argumentsJSON: $0.invocation.jsonArguments,
                            result: $0.result
                        )
                    })
                {
                    hasGroundedConfigApply = true
                }
                // File side-effect grounding: one successful file-writing
                // tool this run grounds later "saved / appended…" narration.
                if !hasGroundedFileWrite,
                    outcomes.contains(where: {
                        GroundedFileSideEffectCheck.isGroundedFileWriteOutcome(
                            toolName: $0.invocation.toolName,
                            result: $0.result
                        )
                    })
                {
                    hasGroundedFileWrite = true
                }
                // Knowledge grounding bookkeeping: one successful knowledge
                // read grounds every later content claim; otherwise remember
                // the latest failed read so the final-answer check can quote
                // the granted names its envelope carries.
                for outcome in outcomes {
                    if GroundedKnowledgeClaimCheck.isGroundedKnowledgeOutcome(
                        toolName: outcome.invocation.toolName,
                        result: outcome.result
                    ) {
                        hasGroundedKnowledgeRead = true
                    } else if GroundedKnowledgeClaimCheck.isFailedKnowledgeOutcome(
                        toolName: outcome.invocation.toolName,
                        result: outcome.result
                    ) {
                        lastFailedKnowledgeRead = (outcome.invocation.toolName, outcome.result)
                    }
                }
                // Advisory, never a stop: the model narrated a file write
                // ("appended to the file") in a message whose tool calls
                // wrote nothing (observed live: `fetch_html` with no write
                // tool in the schema). Stage the factual notice for the next
                // step and keep going; bounded per run.
                if !hasGroundedFileWrite,
                    ungroundedFileClaimNotices < Self.maxUngroundedFileClaimNotices,
                    let narration = toolCallVisibleText,
                    GroundedFileSideEffectCheck.containsFileSideEffectClaim(narration)
                {
                    ungroundedFileClaimNotices += 1
                    print(
                        "[Osaurus] Ungrounded file side-effect claim in a tool-calling turn "
                            + "(notice \(ungroundedFileClaimNotices)/\(Self.maxUngroundedFileClaimNotices)); "
                            + "no file-writing tool succeeded this run"
                    )
                    let notice = GroundedFileSideEffectCheck.ungroundedFileClaimNotice
                    stageStateNotice(notice)
                }
                let successfulTodoOutcomes = outcomes.filter { outcome in
                    outcome.invocation.toolName == "todo"
                        && !outcome.wasError
                        && ToolEnvelope.isSuccess(outcome.result)
                }
                let successfulTodoOutcome = !successfulTodoOutcomes.isEmpty
                if successfulTodoOutcome {
                    lastTodoIteration = iteration
                    // A successful envelope is not enough by itself: arm the
                    // terminal contract only when at least one invocation has
                    // a real parseable checklist. This keeps malformed/empty
                    // calls and synthetic success stubs from hijacking finals.
                    if let latestProgress = successfulTodoOutcomes.compactMap({
                        Self.todoProgressSnapshot(from: $0.invocation)
                    }).last {
                        hasSuccessfulCurrentRunTodo = true
                        lastSuccessfulCurrentRunTodoProgress = latestProgress
                    }
                }

                // Data-movement relief: when an iteration's tool calls
                // are ALL successful bulk loads (db_import / bulk
                // db_insert|db_upsert), it's real progress that shouldn't
                // spend the model's reasoning budget. Refund the iteration and
                // charge a separate, hard-capped budget instead so a large
                // ingest doesn't starve the agent of steps to actually reason
                // over the data it just loaded.
                if policy.maxDataMovementSteps > 0,
                    dataMovementStepsUsed < policy.maxDataMovementSteps,
                    !outcomes.isEmpty,
                    outcomes.allSatisfy({ Self.isSuccessfulDataMovement($0) })
                {
                    dataMovementStepsUsed += 1
                    iteration -= 1
                    if !announcedDataMovementRelief {
                        announcedDataMovementRelief = true
                        stageStateNotice(
                            Self.dataMovementReliefNotice(cap: policy.maxDataMovementSteps)
                        )
                    }
                    continue
                }

                // Per-iteration budget bookkeeping: one decrement per model
                // step regardless of how many tools the batch ran.
                let remaining = policy.maxIterations - iteration
                if remaining > 0, remaining <= policy.budgetWarningThreshold {
                    pendingBudgetNotice = Self.budgetWarningNotice(
                        remaining: remaining,
                        maxIterations: policy.maxIterations
                    )
                }

                // Todo staleness: when the session todo still has unchecked
                // items and no `todo` call has landed for a threshold of
                // iterations, stage a one-line nudge. Firing re-arms the
                // window so the nudge repeats at most once per threshold.
                if !successfulTodoOutcome,
                    let pendingTodoCount = hooks.pendingTodoCount,
                    iteration - lastTodoIteration >= policy.todoStalenessThreshold
                {
                    let pending = await pendingTodoCount()
                    if pending > 0 {
                        pendingTodoNotice = Self.todoStalenessNotice(pending: pending)
                        lastTodoIteration = iteration
                    }
                }
            }
        }

        // The loop can consume its final allowed iteration with a tool batch,
        // not only with `.finalResponse`. If this run created a real Todo and
        // that checklist is still pending, preserve the typed pending count so
        // Chat cannot launch its generic tool-free finalizer and guess that the
        // unfinished task completed. `onBatchComplete` has already created the
        // fresh assistant buffer for the terminal fallback on the chat surface.
        if hasSuccessfulCurrentRunTodo,
            let todoProgressSnapshot = hooks.todoProgressSnapshot
        {
            let progress = await todoProgressSnapshot()
                ?? lastSuccessfulCurrentRunTodoProgress
            // The store lookup suspends across an actor boundary. A Stop that
            // lands during it must still win over the cap fallback.
            if await hooks.isCancelled() {
                return RunResult(exit: .cancelled, iterations: iteration)
            }
            if let progress, progress.pending > 0 {
                return RunResult(
                    exit: .iterationCapReached,
                    iterations: iteration,
                    unfinishedTodoCount: progress.pending
                )
            }
        }

        await recordExit(.iterationCapReached, .typedTerminal)
        return RunResult(exit: .iterationCapReached, iterations: iteration)
    }
}
