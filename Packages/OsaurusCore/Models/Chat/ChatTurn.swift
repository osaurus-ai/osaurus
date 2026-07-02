//
//  ChatTurn.swift
//  osaurus
//
//  Reference-type chat turn for efficient UI updates
//  Uses lazy string joining for O(1) append operations during streaming
//

import Combine
import Foundation

final class ChatTurn: ObservableObject, Identifiable {
    let id: UUID
    let role: MessageRole
    /// Wall-clock when the turn was created. Used by the chat-export
    /// timing flags; persisted via `ChatTurnData`.
    let createdAt: Date
    /// Wall-clock when an assistant stream finished. Set by the
    /// streaming completion site; nil on user / tool turns and on
    /// assistant turns that were cancelled or errored.
    var completedAt: Date?

    // MARK: - Content with lazy joining

    /// Internal storage for content chunks - O(1) append
    private var contentChunks: [String] = []
    /// Cached joined content - invalidated on append
    private var _cachedContent: String?
    /// Cached content length - updated on append/set without joining
    private var _contentLength: Int = 0

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
            objectWillChange.send()
        }
    }

    /// Cached content length - O(1) access without forcing lazy join
    var contentLength: Int { _contentLength }

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
        _cachedContent = nil  // Invalidate cache
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
            _cachedContent = cleanedContent
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
            objectWillChange.send()
        }
    }

    /// Cached thinking length - O(1) access without forcing lazy join
    var thinkingLength: Int { _thinkingLength }

    /// Whether thinking is empty - O(1) access without forcing lazy join
    var thinkingIsEmpty: Bool { _thinkingLength == 0 }

    /// Whether thinking has no renderable text.
    var thinkingIsBlank: Bool {
        thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Efficiently append thinking without triggering immediate UI update.
    func appendThinking(_ s: String) {
        guard !s.isEmpty else { return }
        if thinkingStartedAt == nil { thinkingStartedAt = Date() }
        thinkingChunks.append(s)
        _thinkingLength += s.count
        _cachedThinking = nil  // Invalidate cache
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
    @Published var attachments: [Attachment] = []
    /// Chat-local artifacts rendered in the transcript without being sent as
    /// model-visible tool calls.
    @Published var sharedArtifacts: [SharedArtifact] = []
    /// Assistant-issued tool calls attached to this turn (OpenAI compatible)
    @Published var toolCalls: [ToolCall]? = nil
    /// OpenAI Responses reasoning item captured for this assistant turn: the
    /// opaque `id` and `encrypted_content`. Re-emitted before the turn's
    /// function_call(s) next request so a reasoning model resumes its chain.
    /// Populated only on the Responses path; nil everywhere else.
    var reasoningItemId: String? = nil
    var reasoningEncrypted: String? = nil
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
    @Published var toolResults: [String: String] = [:]
    /// Wall-clock duration (seconds) each tool call took to finish, keyed by call
    /// id. Recorded by `setToolResult(_:for:)` and persisted so a reloaded chat
    /// still shows "· 1.2s" next to the tool title.
    @Published var toolCallDurations: [String: TimeInterval] = [:]

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

    // MARK: - Generation Benchmarks

    /// Wall-clock time from request start to first visible token.
    /// Persisted with the turn for billing / latency reporting.
    var timeToFirstToken: TimeInterval?
    /// Tokens generated per second (GPU-timed for MLX, UI-estimated for
    /// remote APIs). Ephemeral — not persisted. The exporter recomputes
    /// it from token count and stream duration when needed, which
    /// avoids storing a number whose precision varies by provider.
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
    private func finalizeThinkingDuration() {
        guard thinkingDuration == nil, let start = thinkingStartedAt else { return }
        let elapsed = Date().timeIntervalSince(start)
        if elapsed >= Self.minDisplayableToolDuration {
            thinkingDuration = elapsed
        }
    }

    /// Set a tool call's result and record how long it took (if we saw it start).
    /// Use this instead of assigning `toolResults` directly so durations persist.
    func setToolResult(_ result: String, for callId: String) {
        toolResults[callId] = result
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

    /// Flip any still-"running" remote tool rows to a neutral completed state.
    /// Called when a Mode 2 stream ends (or is cancelled) so a missing terminal
    /// trace can't leave a row shimmering forever.
    @MainActor
    func finalizeRemoteToolActivity() {
        guard !remoteToolActivity.isEmpty else { return }
        var changed = false
        for call in remoteToolActivity where remoteToolResults[call.id] == nil {
            remoteToolResults[call.id] = Self.remoteToolSuccessResult
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
    }

    /// Resets pending tool-call argument preview state.
    func clearPendingToolArgs() {
        pendingToolArgPreview = nil
        pendingToolArgSize = 0
        pendingToolArgFragmentCount = 0
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
        return StringCleaning.stripLeakedActionJSON(
            StringCleaning.stripGeminiDisplayMetadata(content)
        )
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
    /// Lightweight Codable representation for database persistence
    struct Persisted: Codable {
        let id: String
        let role: String
        let content: String?
        let thinking: String?
        let toolCalls: [ToolCall]?
        let toolResults: [String: String]?
        let toolCallId: String?
        var injectedContextPrefix: String? = nil
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
            injectedContextPrefix: injectedContextPrefix
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

        return turn
    }
}
