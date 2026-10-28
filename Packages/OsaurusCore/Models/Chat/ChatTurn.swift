//
//  ChatTurn.swift
//  osaurus
//
//  Reference-type chat turn for efficient UI updates
//  Uses lazy string joining for O(1) append operations during streaming
//

import Combine
import Foundation
import os

/// Why observation of an active remote tool stopped. This says nothing
/// about whether its remote side effects succeeded or failed.
enum RemoteToolStreamEnd: String, Sendable, Equatable {
    case completed, failed, cancelled

    var localizedUnobservedResult: String {
        switch self {
        case .completed: return L("The remote stream ended without a tool result. Its outcome is unknown.")
        case .failed: return L("The remote connection failed before a tool result was received. Its outcome is unknown.")
        case .cancelled: return L("Stopped waiting before a remote tool result was received. Its outcome is unknown.")
        }
    }
}

final class ChatTurn: ObservableObject, Identifiable {
    // MARK: - Token-estimate revision

    /// Process-wide counter bumped whenever any turn mutates a field that
    /// feeds `ContextBudgetManager`'s token estimates (content, thinking,
    /// tool calls/results, attachments). `ChatSession` keys its cached
    /// transcript token totals on this value so the context-budget readout
    /// rendered from the chat view body doesn't re-walk every turn per render
    /// — while still picking up in-place turn edits that never reassign the
    /// session's `turns` array.
    private static let _tokenEstimateRevision = OSAllocatedUnfairLock<UInt64>(initialState: 0)

    /// Current value of the process-wide token-estimate revision.
    static var tokenEstimateRevision: UInt64 {
        _tokenEstimateRevision.withLock { $0 }
    }

    private static func bumpTokenEstimateRevision() {
        _tokenEstimateRevision.withLock { $0 &+= 1 }
    }

    let id: UUID
    let role: MessageRole
    /// Wall-clock when the turn was created. Used by the chat-export
    /// timing flags; persisted via `ChatTurnData`.
    let createdAt: Date
    /// Wall-clock when an assistant stream finished. Set by the
    /// streaming completion site; nil on user / tool turns and on
    /// assistant turns that were cancelled or errored.
    var completedAt: Date?
    /// Wall-clock of the last content or reasoning delta the stream
    /// delivered — the moment the answer was fully visible. `completedAt`
    /// is stamped only when the stream TERMINATES, and for local models that
    /// is after vmlx's post-generation cache store, which the runtime adapter
    /// serialises ahead of the terminal stats: measured 4.3 s (AR) to 12.7 s
    /// (native MTP) after the last token on a 930-token JANG_4M answer.
    /// Deriving tok/s from `completedAt - createdAt` therefore reported
    /// 27–30 tok/s for engines decoding at 32–56 tok/s. Nil until the first
    /// delta; persisted so exports can separate decode from persistence.
    var lastOutputAt: Date?

    // MARK: - Content with lazy joining

    /// Internal storage for content chunks - O(1) append
    private var contentChunks: [String] = []
    /// Cached joined content - invalidated on append
    private var _cachedContent: String?
    /// Cached content length - updated on append/set without joining
    private var _contentLength: Int = 0
    /// O(1) render-cache key for replacements as well as streamed appends.
    /// Equal-length status updates (e.g. 10/16 → 11/16) still change the text.
    private(set) var contentRevision: UInt64 = 0
    /// Cached `visibleContent` — the display cleaners (leaked action JSON,
    /// Gemini metadata, channel label) are O(n·braces) and the property is
    /// read several times per block build on the main thread. Invalidated
    /// wherever `contentChunks` changes.
    private var _cachedVisibleContent: String?

    /// The message content. Uses lazy joining for efficient streaming.
    var content: String {
        get {
            if let cached = _cachedContent {
                return cached
            }
            let joined = contentChunks.joined()
            _cachedContent = joined
            return joined
        }
        set {
            // Direct set: clear chunks and update cache
            contentChunks = newValue.isEmpty ? [] : [newValue]
            _cachedContent = newValue
            _contentLength = newValue.count
            contentRevision &+= 1
            _cachedEnvelope = nil
            _cachedVisibleContent = nil
            Self.bumpTokenEstimateRevision()
            objectWillChange.send()
        }
    }

    /// Cached content length - O(1) access without forcing lazy join
    var contentLength: Int { _contentLength }

    // MARK: - Dispatch envelope (memoized)

    /// Memoized `DispatchEnvelope.parse` result for this turn, keyed by the
    /// session source it was parsed under. Invalidated whenever `content`
    /// changes. Read from block generation, the find bar, the minimap, copy
    /// and title derivation — all on the streaming path — so the parse runs
    /// once per turn per session load, not once per consumer per tick.
    private var _cachedEnvelope: (source: SessionSource, value: DispatchEnvelope?)?

    /// The machine-generated dispatch envelope wrapping this user turn's
    /// content, if any. Nil for non-user turns and ordinary typed messages.
    func dispatchEnvelope(sessionSource: SessionSource) -> DispatchEnvelope? {
        guard role == .user, !contentIsEmpty else { return nil }
        if let cached = _cachedEnvelope, cached.source == sessionSource {
            return cached.value
        }
        let parsed = DispatchEnvelope.parse(content, sessionSource: sessionSource)
        _cachedEnvelope = (sessionSource, parsed)
        return parsed
    }

    /// The text the chat should present for this turn: the envelope's
    /// human-authored text when one wraps the content, else the raw content.
    /// Every user-facing consumer (bubble, find bar, minimap, copy, title)
    /// reads this so what is counted and copied matches what is painted.
    func displayContent(sessionSource: SessionSource) -> String {
        dispatchEnvelope(sessionSource: sessionSource)?.displayText ?? content
    }

    /// Whether content is empty - O(1) access without forcing lazy join
    var contentIsEmpty: Bool { _contentLength == 0 }

    /// Whether content has no user-visible characters. This intentionally
    /// treats streamed newline-only completions as blank for rendering and
    /// follow-up prompt construction.
    var contentIsBlank: Bool {
        content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Efficiently append content without triggering immediate UI update.
    /// Call `notifyContentChanged()` after batch appends to update UI.
    func appendContent(_ s: String) {
        guard !s.isEmpty else { return }
        // First visible content marks the end of any thinking phase.
        finalizeThinkingDuration()
        contentChunks.append(s)
        _contentLength += s.count
        contentRevision &+= 1
        _cachedContent = nil  // Invalidate cache
        _cachedEnvelope = nil
        _cachedVisibleContent = nil
        Self.bumpTokenEstimateRevision()
    }

    /// Append content and immediately notify observers (triggers UI update)
    func appendContentAndNotify(_ s: String) {
        appendContent(s)
        objectWillChange.send()
    }

    /// Trims leaked function-call JSON patterns from the end of content.
    /// Call this when a tool call arrives to clean up any text that leaked before detection.
    /// - Parameter toolName: The name of the tool being called, used to detect leaked JSON
    func trimTrailingFunctionCallLeakage(toolName: String) {
        guard !contentIsEmpty else { return }

        let originalContent = content
        let cleanedContent = StringCleaning.stripFunctionCallLeakage(originalContent, toolName: toolName)

        // Update content if modified
        if cleanedContent != originalContent {
            contentChunks = cleanedContent.isEmpty ? [] : [cleanedContent]
            _contentLength = cleanedContent.count
            contentRevision &+= 1
            _cachedContent = cleanedContent
            _cachedEnvelope = nil
            _cachedVisibleContent = nil
            Self.bumpTokenEstimateRevision()
        }
    }

    // MARK: - Thinking with lazy joining

    /// Internal storage for thinking chunks - O(1) append
    private var thinkingChunks: [String] = []
    /// Cached joined thinking - invalidated on append
    private var _cachedThinking: String?
    /// Cached thinking length - updated on append/set without joining
    private var _thinkingLength: Int = 0

    /// Thinking/reasoning content from models that support extended thinking (e.g., DeepSeek, QwQ)
    var thinking: String {
        get {
            if let cached = _cachedThinking {
                return cached
            }
            let joined = thinkingChunks.joined()
            _cachedThinking = joined
            return joined
        }
        set {
            thinkingChunks = newValue.isEmpty ? [] : [newValue]
            _cachedThinking = newValue
            _thinkingLength = newValue.count
            Self.bumpTokenEstimateRevision()
            objectWillChange.send()
        }
    }

    /// Cached thinking length - O(1) access without forcing lazy join
    var thinkingLength: Int { _thinkingLength }

    /// Whether thinking is empty - O(1) access without forcing lazy join
    var thinkingIsEmpty: Bool { _thinkingLength == 0 }

    /// Whether thinking has no renderable text.
    ///
    /// Blank means "nothing a reader would call reasoning", which is broader
    /// than empty. Gemma-4 (and other Harmony-channel models) put the CHANNEL
    /// NAME on the first line — `<|channel>thought\n…payload…<channel|>` — and
    /// with thinking OFF the template emits, and the model echoes, a pre-closed
    /// EMPTY block: token ids [100, 45518, 107, 101] = `<|channel>` / `thought`
    /// / `\n` / `<channel|>`. vmlx's reasoning parser strips the delimiters and
    /// reports 0 reasoning chars, but a bare identifier can still reach the UI
    /// through other derivation paths, and the chrome ("Thought", an expandable
    /// pane) then renders around nothing.
    ///
    /// This is catalog-wide, not one bundle: `think_in_template=false` is the
    /// canonical stamp for every gemma4 variant, so re-stamping a bundle to
    /// paper over it would desync that bundle from the rest of the line. The
    /// guard belongs here — the single predicate every renderer consults via
    /// `hasRenderableThinking` — so no entry point (cell, activity group,
    /// subagent feed) can reach the bug independently.
    var thinkingIsBlank: Bool {
        let trimmed = thinking.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        return Self.isBareChannelIdentifier(trimmed)
    }

    /// A payload that is nothing but a channel label — one short bare
    /// identifier such as `thought`, `analysis`, `final`.
    ///
    /// Deliberately duplicated rather than imported: vmlx's equivalent
    /// (`isHarmonyIdentifierChannelName`) is internal to MLXLMCommon, and
    /// exporting it would make a six-line UI guard a cross-repo pin bump.
    /// Kept strict — a single token of `[A-Za-z0-9_]`, length-bounded — so real
    /// one-word reasoning is never suppressed.
    static func isBareChannelIdentifier(_ text: String) -> Bool {
        StringCleaning.isHarmonyChannelLabel(text)
    }

    /// Efficiently append thinking without triggering immediate UI update.
    func appendThinking(_ s: String, at: Date = Date()) {
        guard !s.isEmpty else { return }
        if thinkingStartedAt == nil { thinkingStartedAt = at }
        thinkingChunks.append(s)
        _thinkingLength += s.count
        _cachedThinking = nil  // Invalidate cache
        Self.bumpTokenEstimateRevision()
    }

    /// Append thinking and immediately notify observers (triggers UI update)
    func appendThinkingAndNotify(_ s: String) {
        appendThinking(s)
        objectWillChange.send()
    }

    // MARK: - Notify observers after batch updates

    /// Notify observers that content/thinking changed. Call after batch appends.
    func notifyContentChanged() {
        objectWillChange.send()
    }

    /// Consolidate chunks into single strings after streaming completes
    func consolidateContent() {
        if contentChunks.count > 1 {
            let joined = contentChunks.joined()
            contentChunks = [joined]
            _cachedContent = joined
        }
        if thinkingChunks.count > 1 {
            let joined = thinkingChunks.joined()
            thinkingChunks = [joined]
            _cachedThinking = joined
        }
    }

    // MARK: - Other Published Properties

    /// File attachments (images and documents) for this turn
    @Published var attachments: [Attachment] = [] {
        didSet { Self.bumpTokenEstimateRevision() }
    }
    /// Chat-local artifacts rendered in the transcript without being sent as
    /// model-visible tool calls.
    @Published var sharedArtifacts: [SharedArtifact] = []
    /// Assistant-issued tool calls attached to this turn (OpenAI compatible)
    @Published var toolCalls: [ToolCall]? = nil {
        didSet { Self.bumpTokenEstimateRevision() }
    }
    /// OpenAI Responses reasoning item captured for this assistant turn: the
    /// opaque `id` and `encrypted_content`. Re-emitted before the turn's
    /// function_call(s) next request so a reasoning model resumes its chain.
    /// Populated only on the Responses path; nil everywhere else.
    var reasoningItemId: String? = nil
    var reasoningEncrypted: String? = nil
    /// Complete provider-authored Responses output Items, captured in wire
    /// order and replayed on follow-up turns. This preserves semantics that
    /// the flattened ChatTurn fields cannot represent (notably assistant
    /// commentary/final phase and future typed item fields).
    var responsesOutputItems: [JSONValue] = []
    /// Exact provider-tagged signed/redacted Anthropic blocks for history.
    var anthropicThinkingBlocks: [JSONValue] = []
    /// Provider-reported prompt usage for this assistant response, including
    /// the subset served from OpenAI's prompt cache when available.
    var inputTokenCount: Int? = nil
    var cachedInputTokenCount: Int? = nil
    /// Prompt-cache read count for the footer chip. Prefers the provider's
    /// own stats hint (direct BYOK: OpenAI / Anthropic / Gemini); falls back
    /// to the Router billing split, which is the authoritative number on the
    /// paid path. `nil` when neither source reported a positive count.
    var effectiveCachedInputTokens: Int? {
        if let cachedInputTokenCount, cachedInputTokenCount > 0 { return cachedInputTokenCount }
        if let billed = routerBilling?.cachedInputTokens, billed > 0 { return billed }
        return nil
    }
    /// Keeps an abandoned protocol attempt visible in the transcript while
    /// preventing it from re-entering model history. This is set only when an
    /// agent/tool generation ends with incomplete reasoning and the loop
    /// retries from the exact pre-attempt history in a fresh assistant turn.
    /// Persisting the marker prevents a later user turn or session reload from
    /// replaying the abandoned reasoning beside the successful retry.
    var modelContextExcluded: Bool = false
    /// For role==.tool messages, associates this result with the originating call id
    var toolCallId: String? = nil
    /// Frozen memory / screen-context block this USER turn was originally
    /// sent with, INCLUDING the trailing separator (see
    /// `SystemPromptComposer.composeInjectedUserPrefix`). Recorded once at
    /// send time and replayed verbatim by `turnToMessage` on every later
    /// request, so the wire bytes for this turn never change after it has
    /// been part of a token stream — required for paged-KV prefix reuse
    /// across turns. Never rendered in the UI (the bubble shows `content`);
    /// persisted so a reloaded session still matches the disk-backed L2
    /// prefix cache. Nil on assistant/tool turns and on turns sent before
    /// this field existed.
    var injectedContextPrefix: String? = nil
    /// Convenience map for UI to show tool results grouped under the assistant turn
    @Published var toolResults: [String: String] = [:] {
        didSet { Self.bumpTokenEstimateRevision() }
    }
    /// Wall-clock duration (seconds) each tool call took to finish, keyed by call
    /// id. Recorded by `setToolResult(_:for:)` and persisted so a reloaded chat
    /// still shows "· 1.2s" next to the tool title.
    @Published var toolCallDurations: [String: TimeInterval] = [:]
    /// Finished Computer Use / AppleScript step logs by call id, captured
    /// when the result lands (the live feed is dropped seconds later).
    var toolCallLogs: [String: SubagentRunLog] = [:]

    // MARK: - Remote-agent (Mode 2) tool activity — display only

    /// Tools the *remote agent* (Mode 2) executed, reconstructed from the
    /// sanitized `osaurus_agent_tool` traces it streams back (name + phase +
    /// error state only — never raw args/results). Rendered as a tool-call
    /// group so the observer watches each remote tool transition
    /// running → done/failed instead of a chip that vanishes the instant the
    /// tool finishes.
    ///
    /// IMPORTANT: this is display-only and deliberately NOT serialized into
    /// outgoing messages (`turnToMessage` reads `toolCalls`, never this). A
    /// Mode 2 history must never carry synthetic, unpaired `tool_calls` — the
    /// peer runs statelessly and re-deriving them client-side would corrupt the
    /// next turn's history.
    @Published var remoteToolActivity: [ToolCall] = []
    /// Sanitized terminal state per remote tool call id. Absent ⇒ still running
    /// (renders the live shimmer); a failure envelope ⇒ red node; any other
    /// non-error string ⇒ green/done node.
    @Published var remoteToolResults: [String: String] = [:]
    /// Terminal display state when no result was observed. Separate from
    /// results so transport end can never manufacture success/failure.
    private(set) var remoteToolUnobservedResults: [String: RemoteToolStreamEnd] = [:]
    /// Bumped on every `remoteToolActivity` / `remoteToolResults` mutation so
    /// `BlockMemoizer`'s streaming fast-path can't short-circuit a trace that
    /// changed neither visible content nor thinking. Read-only to callers;
    /// mutated only through the helpers below.
    private(set) var remoteToolActivityTick: Int = 0
    /// True when this turn carries any remote-agent tool activity.
    var hasRemoteToolActivity: Bool { !remoteToolActivity.isEmpty }
    /// How long the model spent thinking (seconds) — from the first reasoning
    /// token to the first content/tool that follows. Drives "Thought for 30s";
    /// persisted so it survives reload.
    @Published var thinkingDuration: TimeInterval?
    /// First reasoning-token time (ephemeral), used to compute `thinkingDuration`.
    private var thinkingStartedAt: Date?
    private var accumulatedThinkingDuration: TimeInterval = 0
    /// Ephemeral phase, separate from whether this turn contains reasoning.
    /// Later reasoning can resume after a confirmed content/tool boundary.
    var isReasoningActive: Bool { thinkingStartedAt != nil }
    /// Request-owned prompt progress; never restored as a live phase.
    var prefillProgress: PrefillProgressState?
    /// Tool name detected during streaming before the full invocation is ready.
    var pendingToolName: String? = nil {
        didSet {
            // First detection of a tool starts the clock; the imminent call
            // append consumes this in `markToolCallStarted`. Covers the server
            // `done` path where the call + result arrive together (the visible
            // "running" period is this pending phase, not a group-node phase).
            if pendingToolName != nil, pendingToolStartedAt == nil {
                pendingToolStartedAt = Date()
            }
        }
    }
    /// Start time captured at first `pendingToolName` set, consumed by the next
    /// `markToolCallStarted` so duration spans the whole detect→result window.
    private var pendingToolStartedAt: Date?
    /// Per-call start times (ephemeral) used to compute `toolCallDurations`.
    private var toolCallStartedAt: [String: Date] = [:]
    /// Accumulated preview of tool arguments during streaming (tail-truncated)
    var pendingToolArgPreview: String? = nil
    /// Total bytes of tool arguments received during streaming
    var pendingToolArgSize: Int = 0
    /// Number of arg fragments received during streaming. Used by the chat
    /// view to throttle UI refresh — byte-size mod-5 was the original throttle
    /// but it almost never lands on a multiple of 5 (especially when remote
    /// providers ship args in a single chunk), so the UI never refreshed
    /// mid-stream. A fragment counter makes the throttle predictable.
    var pendingToolArgFragmentCount: Int = 0
    /// Full accumulated tool arguments during streaming, kept only for
    /// file-writing tools (see `FileDiff.diffProducingToolNames`) so the chat
    /// can render a live, growing code card while the model writes — the
    /// tail-truncated `pendingToolArgPreview` can't back that. Capped so a
    /// runaway arg stream can't balloon memory; the preview simply stops
    /// growing at the cap and the final diff card takes over.
    var pendingToolArgFull: String? = nil

    // MARK: - Generation Benchmarks

    /// Request-step start to first generated text, reasoning or tool syntax.
    /// Includes this request's queue/setup/load/prefill waits. New turns do
    /// not subtract process-wide model-load intervals: those may belong to
    /// another window. Older persisted turns may use load-excluded semantics.
    var timeToFirstToken: TimeInterval?

    /// Separately attributed model load, when known for this request. New
    /// typed UI streams leave this nil until runtime supplies correlation;
    /// historical persisted rows may contain globally derived values.
    var modelLoadSeconds: TimeInterval?
    /// When the user pressed Enter (or Regenerate / Save & Regenerate) for the
    /// run this turn opened. Earlier than `createdAt` by the pre-send warm-up
    /// (model load) and setup awaits. Set only on a run's first assistant turn;
    /// anchors the footer's total response time.
    var requestedAt: Date?
    /// Tokens generated per second (GPU-timed for MLX, UI-estimated for
    /// remote APIs). Persisted as displayed; do not recompute it from a
    /// wall-clock interval that includes prefill or cache finalization.
    /// Frozen request controls owned by this user turn; used for regenerate/retry.
    var generationControls: ChatTurnGenerationControls?
    var generationTokensPerSecond: Double?
    /// Total tokens generated in this turn. Persisted with the turn.
    var generationTokenCount: Int?
    /// `true` when vmlx's `GenerateCompletionInfo.unclosedReasoning` fired —
    /// the model ended the stream still inside a `<think>` block (trapped
    /// thinking). Reasoning-trained Qwen3.6-A3B / DeepSeek-V4 fine-tunes
    /// hit this on validation-style prompts; the visible content channel
    /// is typically empty while the answer is buried in `.reasoning`.
    /// The chat UI uses this to surface a fallback banner suggesting the
    /// user toggle "Disable Thinking" for the next turn.
    var unclosedReasoning: Bool = false
    /// Authoritative terminal reason supplied by the runtime (`stop`,
    /// `length`, and provider equivalents). Unlike a token-count equality
    /// guess, this distinguishes a natural ending from output-cap exhaustion.
    /// The agent loop uses it to avoid treating a reasoning-only `length`
    /// completion as a successful final response.
    var terminalStopReason: String?
    /// Osaurus Router billing snapshot captured from the in-stream summary
    /// frame (cost, token counts, status). Persisted so a reloaded chat still
    /// shows a billed-but-empty turn (and its "you were charged" notice)
    /// instead of a silent gap. Nil for local models and non-router providers.
    var routerBilling: RouterBillingSummary?
    /// Ledger entry ids recorded during this live run. Ephemeral - not persisted;
    /// the ledger owns the rows. A single assistant turn can contain multiple
    /// router requests in agent/tool loops, so cleanup finalizes every billed row.
    var billingEntryIds: Set<String> = []

    private static let maxArgPreviewLength = 500
    private static let maxFullArgAccumulation = 262_144

    /// Durations shorter than this aren't shown — they're indistinguishable from
    /// "instant" and usually mean the call + result arrived in the same tick
    /// without an observable execution window.
    private static let minDisplayableToolDuration: TimeInterval = 0.05

    /// Mark a tool call as started so its duration can be measured. Idempotent;
    /// uses the pending-detection start when present (so the timer spans the
    /// whole detect→result window), else now.
    func markToolCallStarted(_ callId: String) {
        // A tool following reasoning also ends the thinking phase.
        finalizeThinkingDuration()
        guard toolCallStartedAt[callId] == nil else { return }
        toolCallStartedAt[callId] = pendingToolStartedAt ?? Date()
        pendingToolStartedAt = nil
    }

    /// Record the thinking duration once, at the first content/tool that follows
    /// reasoning. No-op for turns without thinking, after it's measured, or below
    /// the display threshold.
    func finalizeThinkingDuration(at: Date = Date()) {
        guard let start = thinkingStartedAt else { return }
        accumulatedThinkingDuration += max(0, at.timeIntervalSince(start))
        thinkingStartedAt = nil
        if accumulatedThinkingDuration >= Self.minDisplayableToolDuration {
            thinkingDuration = accumulatedThinkingDuration
        }
    }

    /// Set a tool call's result and record how long it took (if we saw it start).
    /// Use this instead of assigning `toolResults` directly so durations persist.
    func setToolResult(_ result: String, for callId: String) {
        toolResults[callId] = result
        // The run has finished by the time its result lands, and the feed
        // registry keeps it for a short grace window. Keep the log.
        if toolCallLogs[callId] == nil,
            let log = SubagentFeedRegistry.shared.feed(for: callId)?.finishedRunLog()
        {
            toolCallLogs[callId] = log
            SubagentRunLogArchive.shared.store(log, for: callId)
        }
        guard toolCallDurations[callId] == nil, let start = toolCallStartedAt[callId] else { return }
        let elapsed = Date().timeIntervalSince(start)
        if elapsed >= Self.minDisplayableToolDuration {
            toolCallDurations[callId] = elapsed
        }
    }

    // MARK: - Remote-agent (Mode 2) tool activity helpers

    /// Sanitized placeholder result for a remote tool that succeeded. The peer
    /// never ships raw output, so the row records only that it ran.
    private static let remoteToolSuccessResult = "Completed on the remote agent."

    /// Record that the remote agent *started* a tool. Idempotent per call id;
    /// the row renders as "running" (shimmer) until `noteRemoteToolFinished`.
    @MainActor
    func noteRemoteToolStarted(callId: String, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !remoteToolActivity.contains(where: { $0.id == callId }) else { return }
        remoteToolActivity.append(
            ToolCall(
                id: callId,
                type: "function",
                function: ToolCallFunction(name: trimmed, arguments: "")
            )
        )
        remoteToolActivityTick &+= 1
    }

    /// Record that a remote tool *finished*. Materializes the row if we never
    /// saw its "started" (some peers may only emit terminal traces) and stamps a
    /// sanitized success/failure result so the chip flips to done/failed. The
    /// failure case uses a `ToolEnvelope` error so the row renders red without
    /// ever exposing the remote's raw tool output.
    @MainActor
    func noteRemoteToolFinished(callId: String, name: String, isError: Bool) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remoteToolActivity.contains(where: { $0.id == callId }) {
            remoteToolActivity.append(
                ToolCall(
                    id: callId,
                    type: "function",
                    function: ToolCallFunction(name: trimmed.isEmpty ? "tool" : trimmed, arguments: "")
                )
            )
        }
        remoteToolUnobservedResults.removeValue(forKey: callId)
        remoteToolResults[callId] =
            isError
            ? ToolEnvelope.failure(
                kind: .executionError,
                message: "The remote agent reported this tool call failed.",
                tool: trimmed.isEmpty ? nil : trimmed
            )
            : Self.remoteToolSuccessResult
        remoteToolActivityTick &+= 1
    }

    /// Settle observation of still-running remote tools as explicitly unknown.
    /// Called when a Mode 2 stream ends (or is cancelled) so a missing terminal
    /// trace can't leave a row shimmering forever. Missing completion is
    /// unknown, never proof the remote tool succeeded.
    @MainActor
    func finalizeRemoteToolActivity(endedBy reason: RemoteToolStreamEnd = .completed) {
        guard !remoteToolActivity.isEmpty else { return }
        var changed = false
        for call in remoteToolActivity
            where remoteToolResults[call.id] == nil && remoteToolUnobservedResults[call.id] == nil
        {
            remoteToolUnobservedResults[call.id] = reason
            changed = true
        }
        if changed { remoteToolActivityTick &+= 1 }
    }

    /// Appends a tool-argument fragment to the preview, keeping only the trailing window.
    func appendToolArgFragment(_ fragment: String) {
        pendingToolArgSize += fragment.utf8.count
        pendingToolArgFragmentCount += 1
        let current = pendingToolArgPreview ?? ""
        let updated = current + fragment
        pendingToolArgPreview =
            updated.count > Self.maxArgPreviewLength
            ? String(updated.suffix(Self.maxArgPreviewLength))
            : updated

        // Accumulate the full args for file-writing tools AND while the tool
        // name is still unknown (nil or the neutral in-progress placeholder) —
        // local models stream the raw envelope before any name hint, and the
        // name is derived from this buffer.
        let wantsFull =
            pendingToolName == nil
            || pendingToolName == ToolDisplayName.pendingToolSentinel
            || FileDiff.diffProducingToolNames.contains(pendingToolName!)
        if wantsFull {
            let full = pendingToolArgFull ?? ""
            if full.count < Self.maxFullArgAccumulation {
                pendingToolArgFull = full + fragment
            }
        }
    }

    /// Resets pending tool-call argument preview state.
    func clearPendingToolArgs() {
        pendingToolArgPreview = nil
        pendingToolArgSize = 0
        pendingToolArgFragmentCount = 0
        pendingToolArgFull = nil
    }

    // MARK: - Initializers

    init(
        role: MessageRole,
        content: String,
        attachments: [Attachment] = [],
        sharedArtifacts: [SharedArtifact] = [],
        id: UUID = UUID(),
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.createdAt = createdAt
        if !content.isEmpty {
            self.contentChunks = [content]
            self._cachedContent = content
            self._contentLength = content.count
        }
        self.attachments = attachments
        self.sharedArtifacts = sharedArtifacts
    }

    // MARK: - Computed Properties

    /// Whether this turn has any attachments
    var hasAttachments: Bool {
        !attachments.isEmpty
    }

    /// User-visible content. Assistant turns hide Gemini round-trip metadata
    /// and any leaked tool-call JSON a model emitted as text instead of a
    /// structured call.
    var visibleContent: String {
        guard role == .assistant else { return content }
        if let cached = _cachedVisibleContent { return cached }
        // Channel-label strip runs first: the label arrives on the leading line
        // ahead of anything the other two cleaners look for, so removing it
        // early keeps their inputs shaped the way they expect.
        let cleaned = StringCleaning.stripCallEndMarker(
            StringCleaning.stripLeakedActionJSON(
                StringCleaning.stripGeminiDisplayMetadata(
                    StringCleaning.stripLeakedChannelLabel(content)
                )
            )
        )
        _cachedVisibleContent = cleaned
        return cleaned
    }

    /// Whether this turn has any thinking/reasoning content
    var hasThinking: Bool {
        _thinkingLength > 0
    }

    /// Whether this turn has thinking/reasoning text worth showing.
    var hasRenderableThinking: Bool {
        hasThinking && !thinkingIsBlank
    }
}

// MARK: - Persistence

extension ChatTurn {
    /// Lightweight Codable snapshot. Production SQLite persistence uses
    /// `ChatTurnData` and `ChatHistoryDatabase`'s explicit column codec.
    struct Persisted: Codable {
        let id: String
        let role: String
        let content: String?
        let thinking: String?
        let toolCalls: [ToolCall]?
        let toolResults: [String: String]?
        let toolCallId: String?
        var injectedContextPrefix: String? = nil
        var modelContextExcluded: Bool? = nil
        var reasoningItemId: String? = nil
        var reasoningEncrypted: String? = nil
        var responsesOutputItems: [JSONValue]? = nil
        var anthropicThinkingBlocks: [JSONValue]? = nil
        var inputTokenCount: Int? = nil
        var cachedInputTokenCount: Int? = nil
        var generationControls: ChatTurnGenerationControls? = nil
    }

    /// Converts this turn to a persistable representation
    func toPersisted() -> Persisted {
        Persisted(
            id: id.uuidString,
            role: role.rawValue,
            content: contentIsEmpty ? nil : content,
            thinking: thinkingIsEmpty ? nil : thinking,
            toolCalls: toolCalls,
            toolResults: toolResults.isEmpty ? nil : toolResults,
            toolCallId: toolCallId,
            injectedContextPrefix: injectedContextPrefix,
            modelContextExcluded: modelContextExcluded ? true : nil,
            reasoningItemId: reasoningItemId,
            reasoningEncrypted: reasoningEncrypted,
            responsesOutputItems: responsesOutputItems.isEmpty ? nil : responsesOutputItems,
            anthropicThinkingBlocks: anthropicThinkingBlocks.isEmpty ? nil : anthropicThinkingBlocks,
            inputTokenCount: inputTokenCount,
            cachedInputTokenCount: cachedInputTokenCount,
            generationControls: generationControls
        )
    }

    /// Creates a ChatTurn from a persisted representation (preserves original UUID)
    @MainActor
    static func fromPersisted(_ p: Persisted) -> ChatTurn {
        let role = MessageRole(rawValue: p.role) ?? .assistant
        let restoredId = UUID(uuidString: p.id) ?? UUID()
        let turn = ChatTurn(role: role, content: p.content ?? "", id: restoredId)

        if let thinking = p.thinking, !thinking.isEmpty {
            turn.appendThinking(thinking)
        }
        if let toolCalls = p.toolCalls {
            turn.toolCalls = toolCalls
        }
        if let toolResults = p.toolResults {
            turn.toolResults = toolResults
        }
        turn.toolCallId = p.toolCallId
        turn.injectedContextPrefix = p.injectedContextPrefix
        turn.modelContextExcluded = p.modelContextExcluded ?? false
        turn.reasoningItemId = p.reasoningItemId
        turn.reasoningEncrypted = p.reasoningEncrypted
        turn.responsesOutputItems = p.responsesOutputItems ?? []
        turn.anthropicThinkingBlocks = p.anthropicThinkingBlocks ?? []
        turn.inputTokenCount = p.inputTokenCount
        turn.cachedInputTokenCount = p.cachedInputTokenCount
        turn.generationControls = p.generationControls

        return turn
    }
}
