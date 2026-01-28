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
    let id = UUID()
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

    /// Attached images for multimodal messages (stored as PNG data)
    @Published var attachedImages: [Data] = []
    /// Assistant-issued tool calls attached to this turn (OpenAI compatible)
    @Published var toolCalls: [ToolCall]? = nil
    /// For role==.tool messages, associates this result with the originating call id
    var toolCallId: String? = nil
    /// Convenience map for UI to show tool results grouped under the assistant turn
    @Published var toolResults: [String: String] = [:]
    /// Execution plan for agent mode (displayed as PlanBlockView)
    var plan: ExecutionPlan? = nil
    /// Current step index in the plan (for progress indication)
    var currentPlanStep: Int? = nil

    // MARK: - Initializers

    init(role: MessageRole, content: String) {
        self.role = role
        if !content.isEmpty {
            self.contentChunks = [content]
            self._cachedContent = content
            self._contentLength = content.count
        }
    }

    init(role: MessageRole, content: String, images: [Data]) {
        self.role = role
        if !content.isEmpty {
            self.contentChunks = [content]
            self._cachedContent = content
            self._contentLength = content.count
        }
        self.attachedImages = images
    }

    // MARK: - Computed Properties

    /// Whether this turn has any attached images
    var hasImages: Bool {
        !attachedImages.isEmpty
    }

    /// Whether this turn has any thinking/reasoning content
    var hasThinking: Bool {
        _thinkingLength > 0
    }
}
