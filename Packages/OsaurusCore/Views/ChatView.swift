//
//  ChatView.swift
//  osaurus
//
//  Created by Terence on 10/26/25.
//

import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

@MainActor
final class ChatSession: ObservableObject {
    @Published var turns: [ChatTurn] = []
    @Published var isStreaming: Bool = false
    @Published var input: String = ""
    @Published var pendingImages: [Data] = []
    @Published var selectedModel: String? = nil
    @Published var modelOptions: [ModelOption] = []
    @Published var scrollTick: Int = 0
    @Published var hasAnyModel: Bool = false
    @Published var isDiscoveringModels: Bool = true
    /// Per-session tool overrides. Empty = use global config, otherwise map of tool name -> enabled
    @Published var enabledToolOverrides: [String: Bool] = [:]
    /// The persona this session belongs to
    @Published var personaId: UUID?

    // MARK: - Persistence Properties
    @Published var sessionId: UUID?
    @Published var title: String = "New Chat"
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    /// Tracks if session has unsaved content changes
    private var isDirty: Bool = false

    /// Callback when session needs to be saved (called after streaming completes)
    var onSessionChanged: (() -> Void)?

    private var currentTask: Task<Void, Never>?
    private var remoteModelsObserver: NSObjectProtocol?
    private var modelSelectionCancellable: AnyCancellable?
    /// Flag to prevent auto-persist during initial load or programmatic resets
    private var isLoadingModel: Bool = false

    init() {
        // Start with empty options to avoid blocking initialization
        modelOptions = []
        hasAnyModel = false

        // Listen for remote provider model changes
        remoteModelsObserver = NotificationCenter.default.addObserver(
            forName: .remoteProviderModelsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshModelOptions()
            }
        }

        // Auto-persist model selection changes
        modelSelectionCancellable =
            $selectedModel
            .dropFirst()  // Skip initial value
            .removeDuplicates()
            .sink { [weak self] newModel in
                guard let self = self, !self.isLoadingModel, let model = newModel else { return }
                let pid = self.personaId ?? Persona.defaultId
                PersonaManager.shared.updateDefaultModel(for: pid, model: model)
            }

        // Load models asynchronously
        Task {
            await refreshModelOptions()
        }
    }

    /// Build rich model options from all sources
    private static func buildModelOptions() async -> [ModelOption] {
        var options: [ModelOption] = []

        // Add foundation model first if available
        if FoundationModelService.isDefaultModelAvailable() {
            options.append(.foundation())
        }

        // Add local MLX models with rich metadata
        // Run in detached task to avoid blocking main thread with file I/O
        let localModels = await Task.detached(priority: .userInitiated) {
            ModelManager.discoverLocalModels()
        }.value

        for model in localModels {
            options.append(.fromMLXModel(model))
        }

        // Add remote provider models - must access on MainActor
        let remoteModels = await MainActor.run {
            RemoteProviderManager.shared.cachedAvailableModels()
        }

        for providerInfo in remoteModels {
            for modelId in providerInfo.models {
                options.append(
                    .fromRemoteModel(
                        modelId: modelId,
                        providerName: providerInfo.providerName,
                        providerId: providerInfo.providerId
                    )
                )
            }
        }

        return options
    }

    func refreshModelOptions() async {
        let newOptions = await Self.buildModelOptions()

        let prev = selectedModel
        let newSelected: String?

        // If we have a previous selection that's still valid, keep it
        if let prev = prev, newOptions.contains(where: { $0.id == prev }) {
            newSelected = prev
        } else {
            // Otherwise try to load from config/persona defaults
            let chatConfig = ChatConfigurationStore.load()

            // Logic adapted from original init:
            if let defaultModel = chatConfig.defaultModel,
                newOptions.contains(where: { $0.id == defaultModel })
            {
                newSelected = defaultModel
            } else {
                newSelected = newOptions.first?.id
            }
        }

        let newHasAnyModel = !newOptions.isEmpty

        // Always update discovery state
        isDiscoveringModels = false

        // Check if anything changed
        let optionIds = modelOptions.map { $0.id }
        let newOptionIds = newOptions.map { $0.id }
        if optionIds == newOptionIds && selectedModel == newSelected && hasAnyModel == newHasAnyModel {
            return
        }

        modelOptions = newOptions
        // Don't auto-persist when refreshing options (model list changed, not user selection)
        isLoadingModel = true
        selectedModel = newSelected
        isLoadingModel = false
        hasAnyModel = newHasAnyModel
    }

    /// Check if the currently selected model supports images (VLM)
    var selectedModelSupportsImages: Bool {
        guard let model = selectedModel else { return false }
        // Foundation models don't support images yet
        if model.lowercased() == "foundation" { return false }

        // Check ModelOption first
        if let option = modelOptions.first(where: { $0.id == model }) {
            // Remote models: assume they support images (many do, and we can't detect)
            if case .remote = option.source {
                return true
            }
            // Local models: check VLM status
            if option.isVLM {
                return true
            }
        }

        // Fall back to ModelManager detection for downloaded models
        return ModelManager.isVisionModel(named: model)
    }

    /// Get the currently selected ModelOption
    var selectedModelOption: ModelOption? {
        guard let model = selectedModel else { return nil }
        return modelOptions.first { $0.id == model }
    }

    /// Filtered turns excluding tool messages (cached computation)
    var visibleTurns: [ChatTurn] {
        turns.filter { $0.role != .tool }
    }

    /// Grouped turns for display
    var visibleGroups: [MessageGroup] {
        var groups: [MessageGroup] = []

        for turn in visibleTurns {
            if let lastGroup = groups.last, lastGroup.role == turn.role {
                // Append to existing group
                var updatedGroup = lastGroup
                updatedGroup.turns.append(turn)
                groups[groups.count - 1] = updatedGroup
            } else {
                // Start new group with stable ID from first turn
                groups.append(MessageGroup(id: turn.id, role: turn.role, turns: [turn]))
            }
        }
        return groups
    }

    /// Estimated token count for current session context (rough heuristic: ~4 chars per token)
    var estimatedContextTokens: Int {
        var total = 0

        // System prompt (use persona's effective system prompt)
        let systemPrompt = PersonaManager.shared.effectiveSystemPrompt(for: personaId ?? Persona.defaultId)
        if !systemPrompt.isEmpty {
            total += max(1, systemPrompt.count / 4)
        }

        // Enabled tool definitions
        let enabledTools = ToolRegistry.shared.listTools(withOverrides: enabledToolOverrides)
            .filter { tool in
                if let override = enabledToolOverrides[tool.name] {
                    return override
                }
                return tool.enabled
            }
        for tool in enabledTools {
            total += tool.estimatedTokens
        }

        // All turns
        for turn in turns {
            if !turn.content.isEmpty {
                total += max(1, turn.content.count / 4)
            }
            // Tool calls (serialized as JSON)
            if let toolCalls = turn.toolCalls {
                for call in toolCalls {
                    total += max(1, (call.function.name.count + call.function.arguments.count) / 4)
                }
            }
            // Tool results
            for (_, result) in turn.toolResults {
                total += max(1, result.count / 4)
            }
            // Thinking content
            if !turn.thinking.isEmpty {
                total += max(1, turn.thinking.count / 4)
            }
            // Images (base64 ~1.33x size, then /4 for tokens)
            for img in turn.attachedImages {
                total += max(1, (img.count * 4) / 3 / 4)
            }
        }

        // Current input (what user is typing)
        if !input.isEmpty {
            total += max(1, input.count / 4)
        }

        // Pending images
        for img in pendingImages {
            total += max(1, (img.count * 4) / 3 / 4)
        }

        return total
    }

    /// Format token count for display (e.g., "1.2K", "15K")
    static func formatTokenCount(_ tokens: Int) -> String {
        if tokens < 1000 {
            return "\(tokens)"
        } else if tokens < 10000 {
            let k = Double(tokens) / 1000.0
            return String(format: "%.1fK", k)
        } else {
            let k = tokens / 1000
            return "\(k)K"
        }
    }

    func sendCurrent() {
        guard !isStreaming else { return }
        let text = input
        let images = pendingImages
        input = ""
        pendingImages = []
        send(text, images: images)
    }

    func stop() {
        currentTask?.cancel()
        currentTask = nil
    }

    func reset() {
        stop()
        turns.removeAll()
        input = ""
        pendingImages = []
        enabledToolOverrides = [:]
        // Clear session identity for new chat
        sessionId = nil
        title = "New Chat"
        createdAt = Date()
        updatedAt = Date()
        isDirty = false
        // Keep current personaId - don't reset when creating new chat within same persona

        // Apply model from persona or global config (don't auto-persist, it's already saved)
        isLoadingModel = true
        let effectiveModel = PersonaManager.shared.effectiveModel(for: personaId ?? Persona.defaultId)
        if let defaultModel = effectiveModel,
            modelOptions.contains(where: { $0.id == defaultModel })
        {
            selectedModel = defaultModel
        } else {
            selectedModel = modelOptions.first?.id
        }
        isLoadingModel = false

        // Apply tool overrides from persona
        if let toolOverrides = PersonaManager.shared.effectiveToolOverrides(for: personaId ?? Persona.defaultId) {
            enabledToolOverrides = toolOverrides
        }
    }

    /// Reset for a specific persona
    func reset(for newPersonaId: UUID?) {
        personaId = newPersonaId
        reset()
    }

    // MARK: - Persistence Methods

    /// Convert current state to persistable data
    func toSessionData() -> ChatSessionData {
        let turnData = turns.map { ChatTurnData(from: $0) }
        return ChatSessionData(
            id: sessionId ?? UUID(),
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            selectedModel: selectedModel,
            turns: turnData,
            enabledToolOverrides: enabledToolOverrides.isEmpty ? nil : enabledToolOverrides,
            personaId: personaId
        )
    }

    /// Save current session state
    func save() {
        // Only save if there are turns
        guard !turns.isEmpty else { return }

        // Create session ID if this is a new session
        if sessionId == nil {
            sessionId = UUID()
            createdAt = Date()
            isDirty = true
        }

        // Only update timestamp if content actually changed
        if isDirty {
            updatedAt = Date()
            isDirty = false
        }

        // Auto-generate title from first user message if still default
        if title == "New Chat" {
            let turnData = turns.map { ChatTurnData(from: $0) }
            title = ChatSessionData.generateTitle(from: turnData)
        }

        let data = toSessionData()
        ChatSessionStore.save(data)
        onSessionChanged?()
    }

    /// Load session from persisted data
    func load(from data: ChatSessionData) {
        stop()
        sessionId = data.id
        title = data.title
        createdAt = data.createdAt
        updatedAt = data.updatedAt
        personaId = data.personaId

        // Restore saved model if available, otherwise use configured default
        // Don't auto-persist when loading - this is restoring existing state
        isLoadingModel = true
        if let savedModel = data.selectedModel,
            modelOptions.contains(where: { $0.id == savedModel })
        {
            selectedModel = savedModel
        } else {
            // Fall back to persona's model, then global config, then first available
            let effectiveModel = PersonaManager.shared.effectiveModel(for: data.personaId ?? Persona.defaultId)
            if let defaultModel = effectiveModel,
                modelOptions.contains(where: { $0.id == defaultModel })
            {
                selectedModel = defaultModel
            } else {
                selectedModel = modelOptions.first?.id
            }
        }
        isLoadingModel = false

        turns = data.turns.map { ChatTurn(from: $0) }
        enabledToolOverrides = data.enabledToolOverrides ?? [:]
        input = ""
        pendingImages = []
        isDirty = false  // Fresh load, not dirty
    }

    /// Edit a user message and regenerate from that point
    func editAndRegenerate(turnId: UUID, newContent: String) {
        guard let index = turns.firstIndex(where: { $0.id == turnId }) else { return }
        guard turns[index].role == .user else { return }

        // Update the content
        turns[index].content = newContent

        // Remove all turns after this one
        turns = Array(turns.prefix(index + 1))

        // Mark as dirty and save
        isDirty = true
        save()
        send("")  // Empty send to trigger regeneration with existing history
    }

    /// Delete a turn and all subsequent turns
    func deleteTurn(id: UUID) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        turns = Array(turns.prefix(index))
        isDirty = true
        save()
    }

    /// Regenerate an assistant response (removes it and regenerates)
    func regenerate(turnId: UUID) {
        guard let index = turns.firstIndex(where: { $0.id == turnId }) else { return }
        guard turns[index].role == .assistant else { return }

        // Remove this turn and all subsequent turns
        turns = Array(turns.prefix(index))
        isDirty = true

        // Regenerate
        send("")
    }

    func send(_ text: String, images: [Data] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Allow sending with just images, or regenerating from existing history
        let isRegeneration = trimmed.isEmpty && images.isEmpty && !turns.isEmpty
        guard !trimmed.isEmpty || !images.isEmpty || isRegeneration else { return }

        // Only append user turn if there's actual content
        if !trimmed.isEmpty || !images.isEmpty {
            turns.append(ChatTurn(role: .user, content: trimmed, images: images))
            isDirty = true

            // Immediately save new session so it appears in sidebar
            if sessionId == nil {
                sessionId = UUID()
                createdAt = Date()
                updatedAt = Date()
                isDirty = false  // Already set updatedAt
                // Auto-generate title from first user message
                let turnData = turns.map { ChatTurnData(from: $0) }
                title = ChatSessionData.generateTitle(from: turnData)
                let data = toSessionData()
                ChatSessionStore.save(data)
                onSessionChanged?()
            }
        }

        currentTask = Task { @MainActor in
            isStreaming = true
            ServerController.signalGenerationStart()
            defer {
                isStreaming = false
                ServerController.signalGenerationEnd()
                // Remove trailing empty assistant turn if present (can happen after tool calls)
                if let lastTurn = turns.last,
                    lastTurn.role == .assistant,
                    lastTurn.content.isEmpty,
                    lastTurn.toolCalls == nil,
                    lastTurn.thinking.isEmpty
                {
                    turns.removeLast()
                }
                // Auto-save after streaming completes
                save()
            }

            var assistantTurn = ChatTurn(role: .assistant, content: "")
            turns.append(assistantTurn)
            do {
                let engine = ChatEngine(source: .chatUI)
                let chatCfg = ChatConfigurationStore.load()
                // Use persona's system prompt if available, otherwise fall back to global
                let sys = PersonaManager.shared.effectiveSystemPrompt(for: personaId ?? Persona.defaultId)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // Use per-session tool overrides if any, otherwise check persona, then global config
                let effectiveOverrides: [String: Bool]? =
                    enabledToolOverrides.isEmpty
                    ? PersonaManager.shared.effectiveToolOverrides(for: personaId ?? Persona.defaultId)
                    : enabledToolOverrides
                let toolSpecs = ToolRegistry.shared.specs(
                    withOverrides: effectiveOverrides
                )

                // Estimate tokens for a message (heuristic: ~4 chars per token)
                func estimateTokens(for msg: ChatMessage) -> Int {
                    let charCount = (msg.content ?? "").count
                    return max(1, charCount / 4)
                }

                // Get model context length (with fallback)
                // This logic is complex, so we break it down for the compiler
                let modelContextLength: Int = {
                    guard let model = selectedModel else { return 8192 }
                    // Foundation model has ~4096 token context
                    if model == "foundation" || model == "default" {
                        return 4096
                    }
                    if let info = ModelInfo.load(modelId: model),
                        let ctx = info.model.contextLength
                    {
                        return ctx
                    }

                    // For remote models (where we don't have local ModelInfo), assume a modern context window
                    // Most modern providers (OpenRouter, OpenAI, Anthropic) support at least 128k
                    // IMPORTANT: We use modelOptions directly, not session.modelOptions, because we're inside the task
                    // and session is an ObservableObject on the main actor.
                    // Instead of trying to access `session` which is not available in this scope,
                    // we re-fetch the options or just check the registry.
                    // For simplicity in this isolated task, we'll check RemoteProviderManager directly.
                    let isRemote = RemoteProviderManager.shared.cachedAvailableModels().contains { provider in
                        provider.models.contains(model)
                    }

                    if isRemote {
                        // Use configured default or fall back to 128k
                        return chatCfg.contextLength ?? 128_000
                    }

                    // Default fallback
                    return chatCfg.contextLength ?? 8192
                }()

                // Get persona-specific generation settings early for context calculation
                let effectiveMaxTokensForPersona = PersonaManager.shared.effectiveMaxTokens(
                    for: personaId ?? Persona.defaultId
                )

                // Reserve space for model response
                // If maxTokens is not explicitly set in persona/config, use a reasonable default for reservation
                // rather than the maximum possible (which would starve input context)
                let reserveResponseTokens = effectiveMaxTokensForPersona ?? 4096
                let availableContextTokens = max(2048, modelContextLength - reserveResponseTokens)

                @MainActor
                func buildMessages() -> [ChatMessage] {
                    var msgs: [ChatMessage] = []
                    if !sys.isEmpty { msgs.append(ChatMessage(role: "system", content: sys)) }
                    for (index, t) in turns.enumerated() {
                        switch t.role {
                        case .assistant:
                            // Skip the last assistant turn if it's empty (it's the streaming placeholder)
                            let isLastTurn = index == turns.count - 1
                            if isLastTurn && t.content.isEmpty && t.toolCalls == nil {
                                continue
                            }

                            // For assistant messages with tool_calls but no content, use empty string?
                            // OpenAI API usually rejects null content unless tool_calls are present.
                            // Some providers (like Groq/Anthropic/xAI) are strict: content must be non-empty string OR null/absent if tool_calls present.
                            // If neither content nor tool_calls, it's invalid.

                            // If we have content, use it.
                            // If we have tool_calls but no content, use nil for content (let encoder handle it).
                            // If we have neither, this is a malformed turn that should be skipped or fixed.

                            if t.content.isEmpty && (t.toolCalls == nil || t.toolCalls!.isEmpty) {
                                // Invalid assistant message (no content, no tools). Skip it to prevent 400s.
                                print("[Osaurus] Warning: Skipping empty assistant message at index \(index)")
                                continue
                            }

                            let content: String? = t.content.isEmpty ? nil : t.content

                            msgs.append(
                                ChatMessage(
                                    role: "assistant",
                                    content: content,
                                    tool_calls: t.toolCalls,
                                    tool_call_id: nil
                                )
                            )
                        case .tool:
                            msgs.append(
                                ChatMessage(
                                    role: "tool",
                                    content: t.content,
                                    tool_calls: nil,
                                    tool_call_id: t.toolCallId
                                )
                            )
                        case .user:
                            // Include images if present
                            if t.hasImages {
                                msgs.append(ChatMessage(role: "user", text: t.content, imageData: t.attachedImages))
                            } else {
                                msgs.append(ChatMessage(role: t.role.rawValue, content: t.content))
                            }
                        default:
                            msgs.append(ChatMessage(role: t.role.rawValue, content: t.content))
                        }
                    }

                    // Prune older messages if context limit is exceeded
                    // Keep system prompt (index 0 if present) and remove from oldest non-system messages
                    let hasSystemPrompt = !sys.isEmpty && !msgs.isEmpty && msgs[0].role == "system"
                    let startIndex = hasSystemPrompt ? 1 : 0

                    var totalTokens = msgs.reduce(0) { $0 + estimateTokens(for: $1) }

                    while totalTokens > availableContextTokens && msgs.count > startIndex + 1 {
                        // Remove the oldest non-system message
                        let removed = msgs.remove(at: startIndex)
                        totalTokens -= estimateTokens(for: removed)
                    }

                    // Ensure we don't leave orphaned tool messages at the start of the conversation history
                    // (e.g. if we pruned the Assistant message that called the tool)
                    while msgs.count > startIndex && msgs[startIndex].role == "tool" {
                        let removed = msgs.remove(at: startIndex)
                        totalTokens -= estimateTokens(for: removed)
                    }

                    return msgs
                }

                let maxAttempts = max(chatCfg.maxToolAttempts ?? 15, 1)
                var attempts = 0
                // Get persona-specific generation settings
                let effectiveTemp = PersonaManager.shared.effectiveTemperature(for: personaId ?? Persona.defaultId)

                outer: while attempts < maxAttempts {
                    attempts += 1
                    let req = ChatCompletionRequest(
                        model: selectedModel ?? "default",
                        messages: buildMessages(),
                        temperature: effectiveTemp,
                        max_tokens: effectiveMaxTokensForPersona ?? 16384,
                        stream: true,
                        top_p: chatCfg.topPOverride,
                        frequency_penalty: nil,
                        presence_penalty: nil,
                        stop: nil,
                        n: nil,
                        tools: toolSpecs.isEmpty ? nil : toolSpecs,
                        tool_choice: toolSpecs.isEmpty ? nil : .auto,
                        session_id: nil
                    )
                    do {
                        let streamStartTime = Date()
                        var uiDeltaCount = 0
                        print("[Osaurus][UI] Starting stream consumption on MainActor")

                        // Batching: accumulate deltas and flush periodically to reduce UI updates
                        var deltaBuffer = ""
                        var lastFlushTime = Date()
                        // Adaptive flush tuning: as output grows, reduce update frequency to avoid
                        // markdown/layout churn that can beachball the UI on large responses.
                        var flushIntervalMs: Double = 50  // baseline
                        var maxBufferSize: Int = 256  // baseline
                        var longestFlushMs: Double = 0

                        // Track approximate output sizes without repeatedly calling String.count on huge buffers.
                        var assistantContentLen: Int = 0
                        var assistantThinkingLen: Int = 0

                        func recomputeFlushTuning() {
                            let totalChars = assistantContentLen + assistantThinkingLen

                            // Base tuning by total output size
                            let base: (intervalMs: Double, maxBuf: Int) = {
                                switch totalChars {
                                case 0 ..< 4_000:
                                    return (50, 256)
                                case 4_000 ..< 16_000:
                                    return (75, 384)
                                case 16_000 ..< 48_000:
                                    return (110, 512)
                                case 48_000 ..< 96_000:
                                    return (160, 768)
                                case 96_000 ..< 160_000:
                                    return (220, 1_024)
                                case 160_000 ..< 260_000:
                                    return (300, 1_536)
                                case 260_000 ..< 420_000:
                                    return (380, 2_048)
                                default:
                                    return (500, 3_072)
                                }
                            }()

                            // Backpressure based on the worst observed flush cost (includes markdown parsing + SwiftUI invalidation).
                            let factor: Double = {
                                switch longestFlushMs {
                                case 0 ..< 16:
                                    return 1.0
                                case 16 ..< 33:
                                    return 1.25
                                case 33 ..< 60:
                                    return 1.5
                                default:
                                    return 2.0
                                }
                            }()

                            flushIntervalMs = min(500, base.intervalMs * factor)
                            maxBufferSize = min(4_096, Int(Double(base.maxBuf) * factor))
                        }

                        // Thinking tag parsing state
                        var isInsideThinking = false
                        var pendingTagBuffer = ""  // Buffer for partial tag detection

                        @MainActor
                        func appendContent(_ s: String) {
                            guard !s.isEmpty else { return }
                            assistantTurn.content += s
                            assistantContentLen += s.count
                        }

                        @MainActor
                        func appendThinking(_ s: String) {
                            guard !s.isEmpty else { return }
                            assistantTurn.thinking += s
                            assistantThinkingLen += s.count
                        }

                        @MainActor
                        func flushBuffer() {
                            guard !deltaBuffer.isEmpty else { return }
                            let flushStart = Date()

                            // Combine pending tag buffer with new delta for parsing
                            var textToProcess = pendingTagBuffer + deltaBuffer
                            pendingTagBuffer = ""
                            deltaBuffer = ""

                            // Process text, routing thinking content appropriately
                            while !textToProcess.isEmpty {
                                if isInsideThinking {
                                    // Look for </think> closing tag
                                    if let closeRange = textToProcess.range(of: "</think>", options: .caseInsensitive) {
                                        // Add content before closing tag to thinking
                                        let thinkingContent = String(textToProcess[..<closeRange.lowerBound])
                                        appendThinking(thinkingContent)
                                        // Remove processed content including the tag
                                        textToProcess = String(textToProcess[closeRange.upperBound...])
                                        isInsideThinking = false
                                    } else {
                                        // Check if we might have a partial </think> tag at the end
                                        let possiblePartialTags = ["</", "</t", "</th", "</thi", "</thin", "</think"]
                                        var foundPartial = false
                                        for partial in possiblePartialTags.reversed() {
                                            if textToProcess.lowercased().hasSuffix(partial) {
                                                // Buffer the potential partial tag
                                                let safePart = String(textToProcess.dropLast(partial.count))
                                                appendThinking(safePart)
                                                pendingTagBuffer = String(textToProcess.suffix(partial.count))
                                                textToProcess = ""
                                                foundPartial = true
                                                break
                                            }
                                        }
                                        if !foundPartial {
                                            // All content goes to thinking
                                            appendThinking(textToProcess)
                                            textToProcess = ""
                                        }
                                    }
                                } else {
                                    // Look for <think> opening tag
                                    if let openRange = textToProcess.range(of: "<think>", options: .caseInsensitive) {
                                        // Add content before opening tag to regular content
                                        let regularContent = String(textToProcess[..<openRange.lowerBound])
                                        appendContent(regularContent)
                                        // Remove processed content including the tag
                                        textToProcess = String(textToProcess[openRange.upperBound...])
                                        isInsideThinking = true
                                    } else {
                                        // Check if we might have a partial <think> tag at the end
                                        let possiblePartialTags = ["<", "<t", "<th", "<thi", "<thin", "<think"]
                                        var foundPartial = false
                                        for partial in possiblePartialTags.reversed() {
                                            if textToProcess.lowercased().hasSuffix(partial) {
                                                // Buffer the potential partial tag
                                                let safePart = String(textToProcess.dropLast(partial.count))
                                                appendContent(safePart)
                                                pendingTagBuffer = String(textToProcess.suffix(partial.count))
                                                textToProcess = ""
                                                foundPartial = true
                                                break
                                            }
                                        }
                                        if !foundPartial {
                                            // All content goes to regular content
                                            appendContent(textToProcess)
                                            textToProcess = ""
                                        }
                                    }
                                }
                            }

                            scrollTick &+= 1
                            lastFlushTime = Date()

                            let flushMs = lastFlushTime.timeIntervalSince(flushStart) * 1000
                            if flushMs > longestFlushMs { longestFlushMs = flushMs }
                        }

                        /// Final flush that handles any remaining buffered content
                        @MainActor
                        func finalFlush() {
                            // First flush any remaining delta buffer
                            if !deltaBuffer.isEmpty || !pendingTagBuffer.isEmpty {
                                // On final flush, treat any pending partial tags as regular content
                                let remaining = pendingTagBuffer + deltaBuffer
                                pendingTagBuffer = ""
                                deltaBuffer = ""
                                if isInsideThinking {
                                    appendThinking(remaining)
                                } else {
                                    appendContent(remaining)
                                }
                                scrollTick &+= 1
                            }
                        }

                        let stream = try await engine.streamChat(request: req)
                        for try await delta in stream {
                            if Task.isCancelled {
                                flushBuffer()  // Flush remaining before breaking
                                break outer
                            }
                            if !delta.isEmpty {
                                uiDeltaCount += 1

                                deltaBuffer += delta

                                // Flush if buffer is large enough or enough time has passed
                                let now = Date()
                                let timeSinceFlush = now.timeIntervalSince(lastFlushTime) * 1000  // ms
                                recomputeFlushTuning()
                                if deltaBuffer.count >= maxBufferSize || timeSinceFlush >= flushIntervalMs {
                                    flushBuffer()
                                }
                            }
                        }

                        // Flush any remaining buffered content (including partial tags)
                        finalFlush()

                        let totalTime = Date().timeIntervalSince(streamStartTime)
                        print(
                            "[Osaurus][UI] Stream consumption completed: \(uiDeltaCount) deltas in \(String(format: "%.2f", totalTime))s, final contentLen=\(assistantTurn.content.count)"
                        )

                        break  // finished normally
                    } catch let inv as ServiceToolInvocation {
                        // Use preserved tool call ID from stream if available, otherwise generate one
                        let callId: String
                        if let preservedId = inv.toolCallId, !preservedId.isEmpty {
                            callId = preservedId
                        } else {
                            let raw = UUID().uuidString.replacingOccurrences(of: "-", with: "")
                            callId = "call_" + String(raw.prefix(24))
                        }
                        let call = ToolCall(
                            id: callId,
                            type: "function",
                            function: ToolCallFunction(name: inv.toolName, arguments: inv.jsonArguments)
                        )
                        if assistantTurn.toolCalls == nil { assistantTurn.toolCalls = [] }
                        assistantTurn.toolCalls!.append(call)

                        // Execute tool and append hidden tool result turn
                        let resultText: String
                        do {
                            // Log tool execution start
                            let truncatedArgs = inv.jsonArguments.prefix(200)
                            print(
                                "[Osaurus][Tool] Executing: \(inv.toolName) with args: \(truncatedArgs)\(inv.jsonArguments.count > 200 ? "..." : "")"
                            )

                            resultText = try await ToolRegistry.shared.execute(
                                name: inv.toolName,
                                argumentsJSON: inv.jsonArguments,
                                overrides: effectiveOverrides
                            )

                            // Log tool success (truncated result)
                            let truncatedResult = resultText.prefix(500)
                            print(
                                "[Osaurus][Tool] Success: \(inv.toolName) returned \(resultText.count) chars: \(truncatedResult)\(resultText.count > 500 ? "..." : "")"
                            )
                        } catch {
                            // Log tool error
                            print("[Osaurus][Tool] Error: \(inv.toolName) failed: \(error.localizedDescription)")

                            // Store rejection/error as the result so UI shows "Rejected" instead of hanging
                            let rejectionMessage = "[REJECTED] \(error.localizedDescription)"
                            assistantTurn.toolResults[callId] = rejectionMessage
                            let toolTurn = ChatTurn(role: .tool, content: rejectionMessage)
                            toolTurn.toolCallId = callId
                            turns.append(toolTurn)
                            break  // Stop tool loop on rejection
                        }
                        assistantTurn.toolResults[callId] = resultText
                        let toolTurn = ChatTurn(role: .tool, content: resultText)
                        toolTurn.toolCallId = callId
                        turns.append(toolTurn)

                        // Create a new assistant turn for subsequent content
                        // This ensures tool calls and text are rendered sequentially
                        let newAssistantTurn = ChatTurn(role: .assistant, content: "")
                        turns.append(newAssistantTurn)
                        assistantTurn = newAssistantTurn

                        // Continue loop with new history
                        continue
                    }
                }
            } catch {
                assistantTurn.content = "Error: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - ChatView

struct ChatView: View {
    // MARK: - Window State

    /// Per-window state container (isolates this window from shared singletons)
    @StateObject private var windowState: ChatWindowState

    // MARK: - Environment & State

    @EnvironmentObject var server: ServerController
    @ObservedObject private var toolRegistry = ToolRegistry.shared
    @Environment(\.colorScheme) private var colorScheme

    @State private var focusTrigger: Int = 0
    @State private var isPinnedToBottom: Bool = true
    @State private var hostWindow: NSWindow?
    @State private var keyMonitor: Any?
    @State private var isHeaderHovered: Bool = false
    @State private var showSidebar: Bool = false
    @State private var lastScrollTime: Date = .distantPast

    private static let scrollThrottleInterval: TimeInterval = 0.15

    /// Convenience accessor for the window's theme
    private var theme: ThemeProtocol { windowState.theme }

    /// Convenience accessor for the window ID
    private var windowId: UUID { windowState.windowId }

    /// Observed session - needed to properly propagate @Published changes from ChatSession
    @ObservedObject private var observedSession: ChatSession

    /// Convenience accessor for the session (uses observedSession for proper SwiftUI updates)
    private var session: ChatSession { observedSession }

    // MARK: - Initializers

    /// Multi-window initializer with window state
    init(windowState: ChatWindowState) {
        _windowState = StateObject(wrappedValue: windowState)
        _observedSession = ObservedObject(wrappedValue: windowState.session)
    }

    /// Convenience initializer with window ID and optional initial state
    init(
        windowId: UUID,
        initialPersonaId: UUID? = nil,
        initialSessionData: ChatSessionData? = nil
    ) {
        let personaId = initialSessionData?.personaId ?? initialPersonaId ?? Persona.defaultId
        let state = ChatWindowState(
            windowId: windowId,
            personaId: personaId,
            sessionData: initialSessionData
        )
        _windowState = StateObject(wrappedValue: state)
        _observedSession = ObservedObject(wrappedValue: state.session)
    }

    /// Legacy single-window initializer (for backward compatibility)
    init() {
        let windowId = UUID()
        let state = ChatWindowState(
            windowId: windowId,
            personaId: Persona.defaultId,
            sessionData: nil
        )
        _windowState = StateObject(wrappedValue: state)
        _observedSession = ObservedObject(wrappedValue: state.session)
    }

    var body: some View {
        GeometryReader { proxy in
            let sidebarWidth: CGFloat = showSidebar ? 240 : 0
            let chatWidth = proxy.size.width - sidebarWidth

            HStack(alignment: .top, spacing: 0) {
                // Sidebar
                if showSidebar {
                    VStack(alignment: .leading, spacing: 0) {
                        ChatSessionSidebar(
                            sessions: windowState.filteredSessions,
                            currentSessionId: session.sessionId,
                            onSelect: { data in
                                windowState.loadSession(data)
                                isPinnedToBottom = true
                            },
                            onNewChat: {
                                windowState.startNewChat()
                            },
                            onDelete: { id in
                                ChatSessionsManager.shared.delete(id: id)
                                // If we deleted the current session, reset
                                if session.sessionId == id {
                                    session.reset()
                                }
                                windowState.refreshSessions()
                            },
                            onRename: { id, title in
                                ChatSessionsManager.shared.rename(id: id, title: title)
                                windowState.refreshSessions()
                            },
                            onOpenInNewWindow: { sessionData in
                                // Open session in a new window via ChatWindowManager
                                ChatWindowManager.shared.createWindow(
                                    personaId: sessionData.personaId,
                                    sessionData: sessionData
                                )
                            }
                        )
                    }
                    .frame(width: 240, alignment: .top)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .zIndex(1)
                    .transition(.move(edge: .leading))
                }

                // Main chat area
                ZStack {
                    // Background
                    chatBackground

                    // Main content
                    VStack(spacing: 0) {
                        // Header
                        chatHeader

                        // Content area
                        if session.isDiscoveringModels && !session.hasAnyModel {
                            VStack {
                                Spacer()
                                ProgressView()
                                    .controlSize(.small)
                                Spacer()
                            }
                        } else if session.hasAnyModel {
                            if session.turns.isEmpty {
                                // Empty state
                                ChatEmptyState(
                                    hasModels: true,
                                    selectedModel: session.selectedModel,
                                    personas: windowState.personas,
                                    activePersonaId: windowState.personaId,
                                    onOpenModelManager: {
                                        AppDelegate.shared?.showManagementWindow(initialTab: .models)
                                    },
                                    onUseFoundation: FoundationModelService.isDefaultModelAvailable()
                                        ? {
                                            session.selectedModel = session.modelOptions.first?.id ?? "foundation"
                                        } : nil,
                                    onQuickAction: { prompt in
                                        session.input = prompt
                                    },
                                    onSelectPersona: { newPersonaId in
                                        windowState.switchPersona(to: newPersonaId)
                                    }
                                )
                                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                            } else {
                                // Message thread
                                messageThread(chatWidth)
                                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                            }

                            // Floating input card
                            FloatingInputCard(
                                text: $observedSession.input,
                                selectedModel: $observedSession.selectedModel,
                                pendingImages: $observedSession.pendingImages,
                                enabledToolOverrides: $observedSession.enabledToolOverrides,
                                modelOptions: observedSession.modelOptions,
                                availableTools: ToolRegistry.shared.listTools(
                                    withOverrides: observedSession.enabledToolOverrides
                                ),
                                personaToolOverrides: windowState.effectiveToolOverrides,
                                isStreaming: observedSession.isStreaming,
                                supportsImages: observedSession.selectedModelSupportsImages,
                                estimatedContextTokens: observedSession.estimatedContextTokens,
                                onSend: { observedSession.sendCurrent() },
                                onStop: { observedSession.stop() },
                                focusTrigger: focusTrigger,
                                personaId: windowState.personaId
                            )
                        } else {
                            // No models empty state
                            ChatEmptyState(
                                hasModels: false,
                                selectedModel: nil,
                                personas: windowState.personas,
                                activePersonaId: windowState.personaId,
                                onOpenModelManager: {
                                    AppDelegate.shared?.showManagementWindow(initialTab: .models)
                                },
                                onUseFoundation: FoundationModelService.isDefaultModelAvailable()
                                    ? {
                                        session.selectedModel = session.modelOptions.first?.id ?? "foundation"
                                    } : nil,
                                onQuickAction: { _ in },
                                onSelectPersona: { newPersonaId in
                                    windowState.switchPersona(to: newPersonaId)
                                }
                            )
                        }
                    }
                    .animation(theme.springAnimation(), value: session.turns.isEmpty)
                }
            }
        }
        .frame(
            minWidth: 800,
            idealWidth: 950,
            maxWidth: .infinity,
            minHeight: session.turns.isEmpty ? 550 : 610,
            idealHeight: session.turns.isEmpty ? 610 : 760,
            maxHeight: .infinity
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(alignment: .topTrailing) {
            windowControls
        }
        .ignoresSafeArea()
        .animation(theme.animationMedium(), value: session.turns.isEmpty)
        .animation(theme.animationQuick(), value: showSidebar)
        .background(WindowAccessor(window: $hostWindow))
        .onExitCommand { closeWindow() }
        .onReceive(NotificationCenter.default.publisher(for: .chatOverlayActivated)) { _ in
            focusTrigger &+= 1
            isPinnedToBottom = true
            Task {
                await windowState.refreshAll()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .vadStartNewSession)) { notification in
            // VAD requested a new session for a specific persona
            // Only handle if this is the targeted window
            if let personaId = notification.object as? UUID {
                // Only switch if this window's persona matches the VAD request
                if personaId == windowState.personaId {
                    windowState.startNewChat()
                }
            }
        }
        .onAppear {
            setupKeyMonitor()

            // Register close callback with ChatWindowManager
            ChatWindowManager.shared.setCloseCallback(for: windowState.windowId) { [weak windowState] in
                windowState?.session.save()
            }
        }
        .onDisappear {
            cleanupKeyMonitor()
        }
        .onChange(of: session.turns.isEmpty) { _, newValue in
            resizeWindowForContent(isEmpty: newValue)
        }
        .environment(\.theme, windowState.theme)
        .tint(theme.accentColor)
    }

    // MARK: - Background

    private var chatBackground: some View {
        ZStack {
            // Layer 1: Base background (solid, gradient, or image)
            baseBackgroundLayer
                .clipShape(backgroundShape)

            // Layer 2: Glass effect (if enabled)
            if theme.glassEnabled {
                ThemedGlassSurface(
                    cornerRadius: 24,
                    topLeadingRadius: showSidebar ? 0 : nil,
                    bottomLeadingRadius: showSidebar ? 0 : nil
                )
                .allowsHitTesting(false)

                // Solid backing layer for text contrast - uses theme glass opacity to determine
                // how solid the background should be (higher glass opacity = more solid backing)
                // Minimum backing ensures readable text even with low theme opacity settings
                let baseBackingOpacity = theme.isDark ? 0.6 : 0.7
                let themeBoost = theme.glassOpacityPrimary * 0.8  // Theme can add up to ~0.15 more
                let backingOpacity = min(0.92, baseBackingOpacity + themeBoost)

                backgroundShape
                    .fill(theme.primaryBackground.opacity(backingOpacity))
                    .allowsHitTesting(false)

                // Gradient overlay for depth and polish - scales with theme settings
                LinearGradient(
                    colors: [
                        theme.primaryBackground.opacity(theme.glassOpacityPrimary * 1.5),
                        theme.primaryBackground.opacity(theme.glassOpacitySecondary),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .clipShape(backgroundShape)
                .allowsHitTesting(false)
            }
        }
    }

    private var backgroundShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: showSidebar ? 0 : 24,
            bottomLeadingRadius: showSidebar ? 0 : 24,
            bottomTrailingRadius: 24,
            topTrailingRadius: 24,
            style: .continuous
        )
    }

    @ViewBuilder
    private var baseBackgroundLayer: some View {
        if let customTheme = theme.customThemeConfig {
            // Use custom theme's background settings
            switch customTheme.background.type {
            case .solid:
                let color = Color(themeHex: customTheme.background.solidColor ?? customTheme.colors.primaryBackground)
                color

            case .gradient:
                let colors = (customTheme.background.gradientColors ?? ["#000000", "#333333"])
                    .map { Color(themeHex: $0) }
                LinearGradient(
                    colors: colors,
                    startPoint: .top,
                    endPoint: .bottom
                )

            case .image:
                if let image = customTheme.background.decodedImage() {
                    ZStack {
                        backgroundImageView(
                            image: image,
                            fit: customTheme.background.imageFit ?? .fill,
                            opacity: customTheme.background.imageOpacity ?? 1.0
                        )

                        // Overlay if configured
                        if let overlayHex = customTheme.background.overlayColor {
                            Color(themeHex: overlayHex)
                                .opacity(customTheme.background.overlayOpacity ?? 0.5)
                        }
                    }
                } else {
                    // Fallback to primary background if image fails to load
                    Color(themeHex: customTheme.colors.primaryBackground)
                }
            }
        } else {
            // Default theme - use primary background with transparency for glass
            theme.primaryBackground
        }
    }

    @ViewBuilder
    private func backgroundImageView(image: NSImage, fit: ThemeBackground.ImageFit, opacity: Double) -> some View {
        GeometryReader { geo in
            switch fit {
            case .fill:
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .opacity(opacity)
            case .fit:
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .opacity(opacity)
            case .stretch:
                Image(nsImage: image)
                    .resizable()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .opacity(opacity)
            case .tile:
                // Tile the image
                tiledImage(image: image, size: geo.size)
                    .opacity(opacity)
            }
        }
    }

    private func tiledImage(image: NSImage, size: CGSize) -> some View {
        let imageSize = image.size
        let cols = Int(ceil(size.width / imageSize.width))
        let rows = Int(ceil(size.height / imageSize.height))

        return VStack(spacing: 0) {
            ForEach(0 ..< rows, id: \.self) { _ in
                HStack(spacing: 0) {
                    ForEach(0 ..< cols, id: \.self) { _ in
                        Image(nsImage: image)
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    // MARK: - Header

    private var chatHeader: some View {
        ZStack {
            // Full-size drag area behind content
            WindowDragArea()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Header content on top
            HStack(spacing: 12) {
                // Sidebar toggle
                HeaderActionButton(
                    icon: showSidebar ? "sidebar.left" : "sidebar.left",
                    help: showSidebar ? "Hide sidebar" : "Show sidebar",
                    action: {
                        withAnimation(theme.animationQuick()) {
                            showSidebar.toggle()
                        }
                    }
                )

                // Model indicator
                if let model = session.selectedModel, session.modelOptions.count <= 1 {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                        Text(displayModelName(model))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.secondaryText)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(theme.secondaryBackground.opacity(0.6))
                    )
                }

                Spacer()
            }
            .padding(.leading, 20)
            .padding(.trailing, 56)  // Leave room for close button
        }
        .frame(height: 72)  // Fixed height for consistent drag area
        .onHover { hovering in
            isHeaderHovered = hovering
        }
    }

    private var windowControls: some View {
        HStack(spacing: 8) {
            if session.turns.isEmpty {
                SettingsButton(action: {
                    AppDelegate.shared?.showManagementWindow(initialTab: .settings)
                })
            } else {
                HeaderActionButton(
                    icon: "plus",
                    help: "New chat",
                    action: {
                        windowState.startNewChat()
                    }
                )
            }
            PinButton(windowId: windowState.windowId)
            CloseButton(action: closeWindow)
        }
        .padding(16)
    }

    /// Close this window via ChatWindowManager
    private func closeWindow() {
        ChatWindowManager.shared.closeWindow(id: windowState.windowId)
    }

    // MARK: - Message Thread

    private func messageThread(_ width: CGFloat) -> some View {
        let groups = session.visibleGroups
        // Use "Assistant" for default persona, otherwise use persona name
        let displayName = windowState.activePersona.isBuiltIn ? "Assistant" : windowState.activePersona.name

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(groups) { group in
                        MessageGroupView(
                            group: group,
                            width: width,
                            isStreaming: session.isStreaming,
                            personaName: displayName,
                            onCopy: copyToPasteboard,
                            onEdit: { turnId, newContent in
                                session.editAndRegenerate(turnId: turnId, newContent: newContent)
                            },
                            onRegenerate: { turnId in
                                session.regenerate(turnId: turnId)
                            }
                        )
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                    }

                    // Bottom anchor
                    Color.clear
                        .frame(height: 1)
                        .id("BOTTOM")
                        .onAppear { isPinnedToBottom = true }
                        .onDisappear { isPinnedToBottom = false }
                }
                .padding(.vertical, 8)
            }
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
            .overlay(alignment: .bottomTrailing) {
                scrollToBottomButton(proxy: proxy)
            }
            .onChange(of: session.turns.count) { _, _ in
                if isPinnedToBottom {
                    withAnimation(theme.animationQuick()) {
                        proxy.scrollTo("BOTTOM", anchor: .bottom)
                    }
                }
            }
            .onChange(of: session.scrollTick) { _, _ in
                guard isPinnedToBottom,
                    Date().timeIntervalSince(lastScrollTime) >= Self.scrollThrottleInterval
                else { return }
                lastScrollTime = .now
                proxy.scrollTo("BOTTOM", anchor: .bottom)
            }
            .onReceive(NotificationCenter.default.publisher(for: .chatOverlayActivated)) { _ in
                proxy.scrollTo("BOTTOM", anchor: .bottom)
                isPinnedToBottom = true
            }
        }
    }

    @ViewBuilder
    private func scrollToBottomButton(proxy: ScrollViewProxy) -> some View {
        if !isPinnedToBottom && !session.turns.isEmpty {
            Button(action: {
                withAnimation(theme.springAnimation()) {
                    proxy.scrollTo("BOTTOM", anchor: .bottom)
                }
                isPinnedToBottom = true
            }) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle()
                            .fill(theme.secondaryBackground)
                            .shadow(color: Color.black.opacity(0.2), radius: 8, x: 0, y: 2)
                    )
            }
            .buttonStyle(.plain)
            .padding(20)
            .transition(.scale.combined(with: .opacity))
        }
    }

    // MARK: - Helpers

    private func displayModelName(_ raw: String?) -> String {
        guard let raw else { return "Model" }
        if raw.lowercased() == "foundation" { return "Foundation" }
        if let last = raw.split(separator: "/").last { return String(last) }
        return raw
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func resizeWindowForContent(isEmpty: Bool) {
        guard let window = hostWindow else { return }

        let targetHeight: CGFloat = isEmpty ? 610 : 760
        let currentFrame = window.frame

        let currentCenterY = currentFrame.origin.y + (currentFrame.height / 2)
        let currentCenterX = currentFrame.origin.x + (currentFrame.width / 2)

        let newFrame = NSRect(
            x: currentCenterX - (currentFrame.width / 2),
            y: currentCenterY - (targetHeight / 2),
            width: currentFrame.width,
            height: targetHeight
        )

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(newFrame, display: true)
        })
    }

    // Key monitor for Esc to cancel voice or close window
    private func setupKeyMonitor() {
        if keyMonitor != nil { return }

        // Capture windowId for use in closure
        let capturedWindowId = windowState.windowId

        // Monitor for KeyDown events in the local event loop
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Esc key code is 53
            if event.keyCode == 53 {
                // Only handle Esc if this event is for our specific window
                // This prevents closed windows' monitors from handling events for other windows
                guard let ourWindow = ChatWindowManager.shared.getNSWindow(id: capturedWindowId),
                    event.window === ourWindow
                else {
                    return event
                }

                // Check if voice input is active
                if WhisperKitService.shared.isRecording {
                    // Stage 1: Cancel voice input
                    print("[ChatView] Esc pressed: Cancelling voice input")
                    Task {
                        // Stop streaming and clear transcription
                        _ = await WhisperKitService.shared.stopStreamingTranscription()
                        WhisperKitService.shared.clearTranscription()
                    }
                    return nil  // Swallow event
                } else {
                    // Stage 2: Close chat window
                    print("[ChatView] Esc pressed: Closing chat window")
                    Task { @MainActor in
                        ChatWindowManager.shared.closeWindow(id: capturedWindowId)
                    }
                    return nil  // Swallow event
                }
            }
            return event
        }
    }

    private func cleanupKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
}

// MARK: - Header Action Button

private struct HeaderActionButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isHovered ? theme.primaryText : theme.secondaryText)
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(theme.secondaryBackground.opacity(isHovered ? 0.8 : 0.5))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(theme.animationQuick()) {
                isHovered = hovering
            }
        }
        .help(help)
    }
}

// MARK: - Settings Button

private struct SettingsButton: View {
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(isHovered ? theme.primaryText : theme.secondaryText)
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(theme.secondaryBackground.opacity(isHovered ? 0.8 : 0.5))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(theme.animationQuick()) {
                isHovered = hovering
            }
        }
        .help("Settings")
    }
}

// MARK: - Close Button

private struct CloseButton: View {
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(isHovered ? theme.primaryText : theme.secondaryText)
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(theme.secondaryBackground.opacity(isHovered ? 0.8 : 0.5))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(theme.animationQuick()) {
                isHovered = hovering
            }
        }
        .help("Close")
    }
}

// MARK: - Pin Button

private struct PinButton: View {
    /// Window ID for this window
    let windowId: UUID

    @State private var isHovered = false
    @State private var isPinned = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button {
            isPinned.toggle()
            // Set window level via ChatWindowManager
            ChatWindowManager.shared.setWindowPinned(id: windowId, pinned: isPinned)
        } label: {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(isPinned ? theme.accentColor : (isHovered ? theme.primaryText : theme.secondaryText))
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(theme.secondaryBackground.opacity(isHovered ? 0.8 : 0.5))
                )
                .rotationEffect(.degrees(isPinned ? 0 : 45))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(theme.animationQuick()) {
                isHovered = hovering
            }
        }
        .help(isPinned ? "Unpin from top" : "Pin to top")
        .animation(theme.animationQuick(), value: isPinned)
    }
}

// MARK: - Window Accessor Helper

struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        Task { @MainActor in
            self.window = view.window
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if window == nil {
            Task { @MainActor in
                self.window = nsView.window
            }
        }
    }
}

// MARK: - Window Drag Area

/// An NSViewRepresentable that makes its area draggable to move the window
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = WindowDragView()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Custom NSView that enables window dragging
private class WindowDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        // Start window drag
        window?.performDrag(with: event)
    }
}
