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

    /// Efficiently append content without triggering immediate UI update.
    /// Call `notifyContentChanged()` after batch appends to update UI.
    func appendContent(_ s: String) {
        guard !s.isEmpty else { return }
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

    /// Efficiently append thinking without triggering immediate UI update.
    func appendThinking(_ s: String) {
        guard !s.isEmpty else { return }
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
    /// Assistant-issued tool calls attached to this turn (OpenAI compatible)
    @Published var toolCalls: [ToolCall]? = nil
    /// For role==.tool messages, associates this result with the originating call id
    var toolCallId: String? = nil
    /// Convenience map for UI to show tool results grouped under the assistant turn
    @Published var toolResults: [String: String] = [:]
    /// Tool name detected during streaming before the full invocation is ready.
    var pendingToolName: String? = nil
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
    /// Capabilities selected by preflight search (ephemeral, not persisted)
    var preflightCapabilities: [PreflightCapabilityItem]? = nil

    // MARK: - Generation Benchmarks (ephemeral, not persisted)

    /// Wall-clock time from request start to first visible token
    var timeToFirstToken: TimeInterval?
    /// Tokens generated per second (GPU-timed for MLX, UI-estimated for remote APIs)
    var generationTokensPerSecond: Double?
    /// Total tokens generated in this turn
    var generationTokenCount: Int?
    /// `true` when vmlx's `GenerateCompletionInfo.unclosedReasoning` fired —
    /// the model ended the stream still inside a `<think>` block (trapped
    /// thinking). Reasoning-trained Qwen3.6-A3B / DeepSeek-V4 fine-tunes
    /// hit this on validation-style prompts; the visible content channel
    /// is typically empty while the answer is buried in `.reasoning`.
    /// The chat UI uses this to surface a fallback banner suggesting the
    /// user toggle "Disable Thinking" for the next turn.
    var unclosedReasoning: Bool = false

    private static let maxArgPreviewLength = 500

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

    init(role: MessageRole, content: String, attachments: [Attachment] = [], id: UUID = UUID()) {
        self.id = id
        self.role = role
        if !content.isEmpty {
            self.contentChunks = [content]
            self._cachedContent = content
            self._contentLength = content.count
        }
        self.attachments = attachments
    }

    // MARK: - Computed Properties

    /// Whether this turn has any attachments
    var hasAttachments: Bool {
        !attachments.isEmpty
    }

    /// User-visible content. Assistant turns hide Gemini round-trip metadata.
    var visibleContent: String {
        role == .assistant ? StringCleaning.stripGeminiDisplayMetadata(content) : content
    }

    /// Whether this turn has any thinking/reasoning content
    var hasThinking: Bool {
        _thinkingLength > 0
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
            toolCallId: toolCallId
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

        return turn
    }
}
