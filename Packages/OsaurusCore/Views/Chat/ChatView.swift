//
//  ChatView.swift
//  osaurus
//
//  Created by Terence on 10/26/25.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class ChatSession: ObservableObject {
    @Published var turns: [ChatTurn] = []
    @Published var isStreaming: Bool = false
    @Published var lastStreamError: String?
    @Published var pendingSecretPrompt: SecretPromptState?
    /// Tracks expand/collapse state for tool calls, thinking blocks, etc.
    /// Lives on the session so state survives NSTableView cell reuse.
    let expandedBlocksStore = ExpandedBlocksStore()
    @Published var input: String = ""
    @Published var pendingAttachments: [Attachment] = []
    @Published var selectedModel: String? = nil
    @Published var pickerItems: [ModelPickerItem] = []
    @Published var activeModelOptions: [String: ModelOptionValue] = [:]
    @Published var hasAnyModel: Bool = false
    @Published var isDiscoveringModels: Bool = true
    /// When true, voice input auto-restarts after AI responds (continuous conversation mode)
    @Published var isContinuousVoiceMode: Bool = false
    /// Active state of the voice input overlay
    @Published var voiceInputState: VoiceInputState = .idle
    /// Whether the voice input overlay is currently visible
    @Published var showVoiceOverlay: Bool = false
    /// The agent this session belongs to
    @Published var agentId: UUID?

    // MARK: - Persistence Properties
    @Published var sessionId: UUID?
    @Published var title: String = "New Chat"
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    /// Tracks if session has unsaved content changes
    private var isDirty: Bool = false

    // MARK: - Memoization Cache
    private let blockMemoizer = BlockMemoizer()
    private var _cachedBreakdown: ContextTokenBreakdown = .zero
    private var _tokenCacheValid: Bool = false
    private var _lastTokenTurnsCount: Int = 0
    private var _lastTokenAttachmentsCount: Int = 0
    private var _memoryContextTokens: Int = 0
    private let budgetTracker = ContextBudgetTracker()

    /// Callback when session needs to be saved (called after streaming completes)
    var onSessionChanged: (() -> Void)?

    private var currentTask: Task<Void, Never>?
    private var activeRunId: UUID?
    private var activeRunContext: RunContext?
    var chatEngineFactory: @MainActor () -> ChatEngineProtocol = {
        ChatEngine(source: .chatUI)
    }
    // nonisolated(unsafe) allows deinit to access these for cleanup
    nonisolated(unsafe) private var remoteModelsObserver: NSObjectProtocol?
    nonisolated(unsafe) private var modelSelectionCancellable: AnyCancellable?
    /// Flag to prevent auto-persist during initial load or programmatic resets
    private var isLoadingModel: Bool = false

    nonisolated(unsafe) private var localModelsObserver: NSObjectProtocol?

    init() {
        let cache = ModelPickerItemCache.shared
        if cache.isLoaded {
            pickerItems = cache.items
            hasAnyModel = !cache.items.isEmpty
            isDiscoveringModels = false
        } else {
            pickerItems = []
            hasAnyModel = false
        }

        remoteModelsObserver = NotificationCenter.default.addObserver(
            forName: .remoteProviderModelsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refreshPickerItems() }
        }

        localModelsObserver = NotificationCenter.default.addObserver(
            forName: .localModelsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refreshPickerItems() }
        }

        // Auto-persist model selection and unload unused models on switch
        modelSelectionCancellable =
            $selectedModel
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] newModel in
                guard let self = self, !self.isLoadingModel, let model = newModel else { return }
                let pid = self.agentId ?? Agent.defaultId
                AgentManager.shared.updateDefaultModel(for: pid, model: model)

                // Load persisted options or use defaults
                if let persisted = ModelOptionsStore.shared.loadOptions(for: model) {
                    self.activeModelOptions = persisted
                } else {
                    self.activeModelOptions = ModelProfileRegistry.defaults(for: model)
                }

                Task { @MainActor in
                    let active = ChatWindowManager.shared.activeLocalModelNames()
                    await ModelRuntime.shared.unloadModelsNotIn(active)
                }
            }

        if !cache.isLoaded {
            Task { [weak self] in
                await self?.refreshPickerItems()
            }
        }

        if MockChatData.isEnabled {
            rebuildVisibleBlocks()
        }
    }

    deinit {
        print("[ChatSession] deinit")
        currentTask?.cancel()
        if let observer = remoteModelsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = localModelsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        modelSelectionCancellable = nil
    }

    /// Apply initial model selection after agentId is set (for cached picker items)
    func applyInitialModelSelection() {
        guard selectedModel == nil, !pickerItems.isEmpty else { return }
        isLoadingModel = true
        let effectiveModel = AgentManager.shared.effectiveModel(for: agentId ?? Agent.defaultId)
        if let model = effectiveModel, pickerItems.contains(where: { $0.id == model }) {
            selectedModel = model
        } else {
            selectedModel = pickerItems.first?.id
        }
        isLoadingModel = false
        Task { [weak self] in await self?.refreshMemoryTokens() }
    }

    func refreshPickerItems() async {
        let newOptions = await ModelPickerItemCache.shared.buildModelPickerItems()
        let newOptionIds = newOptions.map { $0.id }
        let optionsChanged = pickerItems.map({ $0.id }) != newOptionIds

        isDiscoveringModels = false

        guard optionsChanged else { return }

        // Options changed (e.g., remote models loaded) - re-check agent's preferred model.
        // This corrects the initial fallback to "foundation" when remote models weren't yet available.
        let effectiveModel = AgentManager.shared.effectiveModel(for: agentId ?? Agent.defaultId)
        let newSelected: String?

        if let model = effectiveModel, newOptionIds.contains(model) {
            newSelected = model
        } else if let prev = selectedModel, newOptionIds.contains(prev) {
            newSelected = prev
        } else {
            newSelected = newOptionIds.first
        }

        pickerItems = newOptions
        isLoadingModel = true
        selectedModel = newSelected
        isLoadingModel = false
        hasAnyModel = !newOptions.isEmpty
    }

    /// Check if the currently selected model supports images (VLM)
    var selectedModelSupportsImages: Bool {
        guard let model = selectedModel else { return false }
        if model.lowercased() == "foundation" { return false }
        guard let option = pickerItems.first(where: { $0.id == model }) else { return false }
        if case .remote = option.source { return true }
        return option.isVLM
    }

    /// Get the currently selected ModelPickerItem
    var selectedPickerItem: ModelPickerItem? {
        guard let model = selectedModel else { return nil }
        return pickerItems.first { $0.id == model }
    }

    /// Flattened content blocks for NSTableView rendering.
    /// Stored and updated explicitly (not recomputed on every body pass).
    /// Call `rebuildVisibleBlocks()` after any turn mutation to refresh.
    @Published private(set) var visibleBlocks: [ContentBlock] = []

    /// Precomputed group header map. Updated alongside `visibleBlocks`.
    @Published private(set) var visibleBlocksGroupHeaderMap: [UUID: UUID] = [:]

    /// Whether the message thread has content (includes USE_MOCK_CHAT_DATA stress data).
    var hasVisibleThreadMessages: Bool {
        if MockChatData.isEnabled {
            return !visibleBlocks.isEmpty
        }
        return !turns.isEmpty
    }

    /// Last assistant turn for hover/regen chrome; respects mock thread when enabled.
    var lastAssistantTurnIdForThread: UUID? {
        if MockChatData.isEnabled {
            return visibleBlocks.last { $0.role == .assistant }?.turnId
        }
        return turns.last { $0.role == .assistant }?.id
    }

    /// Rebuild `visibleBlocks` and `visibleBlocksGroupHeaderMap` from current turns.
    /// Cheap to call repeatedly — BlockMemoizer fast-paths when nothing changed.
    func rebuildVisibleBlocks() {
        let agent = AgentManager.shared.agent(for: agentId ?? Agent.defaultId)
        let displayName = agent?.isBuiltIn == true ? "Assistant" : (agent?.name ?? "Assistant")
        let streamingTurnId = isStreaming ? turns.last?.id : nil

        if MockChatData.isEnabled {
            let mockTurns = MockChatData.mockTurnsForPerformanceTest()
            let newBlocks = blockMemoizer.blocks(
                from: mockTurns,
                streamingTurnId: nil,
                agentName: displayName,
                thinkingEnabled: activeModelOptions["disableThinking"]?.boolValue == false
            )
            let newHeaderMap = blockMemoizer.groupHeaderMap
            withAnimation(.none) {
                visibleBlocks = newBlocks
                visibleBlocksGroupHeaderMap = newHeaderMap
            }
            return
        }

        let newBlocks = blockMemoizer.blocks(
            from: turns,
            streamingTurnId: streamingTurnId,
            agentName: displayName,
            thinkingEnabled: activeModelOptions["disableThinking"]?.boolValue == false
        )
        let newHeaderMap = blockMemoizer.groupHeaderMap

        // use withAnimation(.none) to suppress the warning about publishing during view updates
        // this wraps the changes in a proper SwiftUI transaction
        withAnimation(.none) {
            visibleBlocks = newBlocks
            visibleBlocksGroupHeaderMap = newHeaderMap
        }
    }

    /// Estimated token count for current session context (~4 chars per token).
    /// Throttled to at most once per 500ms during streaming.
    var estimatedContextTokens: Int {
        estimatedContextBreakdown.total
    }

    /// Per-category breakdown of estimated context tokens.
    /// During streaming, returns the snapshot from the active request with live
    /// output tokens (O(1)). Otherwise uses cached full recomputation.
    var estimatedContextBreakdown: ContextTokenBreakdown {
        if let active = budgetTracker.activeBreakdown(
            isActive: isStreaming,
            outputTurn: turns.last
        ) {
            return active
        }

        if _tokenCacheValid && !isStreaming && turns.count == _lastTokenTurnsCount
            && pendingAttachments.count == _lastTokenAttachmentsCount
        {
            return _cachedBreakdown
        }

        var breakdown = ContextTokenBreakdown()
        let effectiveId = agentId ?? Agent.defaultId
        let executionMode = estimatedChatExecutionMode(agentId: effectiveId)

        let compact = SystemPromptBuilder.isLocalModel(selectedModel)
        let systemPrompt = buildSystemPrompt(
            base: AgentManager.shared.effectiveSystemPrompt(for: effectiveId)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            agentId: effectiveId,
            executionMode: executionMode,
            compact: compact
        )
        breakdown.systemPrompt = ContextBudgetManager.estimateTokens(for: systemPrompt)

        breakdown.memory = _memoryContextTokens

        let toolSpecs = buildToolSpecs(executionMode: executionMode)
        breakdown.tools = ToolRegistry.shared.totalEstimatedTokens(for: toolSpecs)
        breakdown.output = ContextBudgetManager.estimateOutputTokens(for: turns)
        breakdown.conversation = ContextBudgetManager.estimateTokens(for: turns) - breakdown.output

        var inputTokens = 0
        if !input.isEmpty {
            inputTokens += ContextBudgetManager.estimateTokens(for: input)
        }
        for attachment in pendingAttachments {
            inputTokens += attachment.estimatedTokens
        }
        breakdown.input = inputTokens

        _cachedBreakdown = breakdown
        _tokenCacheValid = true
        _lastTokenTurnsCount = turns.count
        _lastTokenAttachmentsCount = pendingAttachments.count

        return breakdown
    }

    /// Builds the full user message text, prepending any attached document contents wrapped in XML tags.
    static func buildUserMessageText(content: String, attachments: [Attachment]) -> String {
        let docs = attachments.filter(\.isDocument)
        guard !docs.isEmpty else { return content }

        var parts: [String] = []
        for doc in docs {
            if let name = doc.filename, let text = doc.documentContent {
                parts.append("<attached_document name=\"\(name)\">\n\(text)\n</attached_document>")
            }
        }

        if !content.isEmpty {
            parts.append(content)
        }

        return parts.joined(separator: "\n\n")
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
        let attachments = pendingAttachments
        input = ""
        pendingAttachments = []
        send(text, attachments: attachments)
    }

    func stop() {
        let task = currentTask
        task?.cancel()
        if let runId = activeRunId {
            finalizeRun(runId: runId, persistConversationArtifacts: false)
        } else {
            completeRunCleanup()
        }
    }

    func reset() {
        stop()
        turns.removeAll()
        input = ""
        pendingAttachments = []
        voiceInputState = .idle
        showVoiceOverlay = false
        // Clear session identity for new chat
        sessionId = nil
        title = "New Chat"
        createdAt = Date()
        updatedAt = Date()
        isDirty = false
        // Keep current agentId - don't reset when creating new chat within same agent

        // Clear caches
        blockMemoizer.clear()
        _tokenCacheValid = false
        visibleBlocks = []
        visibleBlocksGroupHeaderMap = [:]

        // Apply model from agent or global config (don't auto-persist, it's already saved)
        isLoadingModel = true
        let effectiveModel = AgentManager.shared.effectiveModel(for: agentId ?? Agent.defaultId)
        if let defaultModel = effectiveModel,
            pickerItems.contains(where: { $0.id == defaultModel })
        {
            selectedModel = defaultModel
        } else {
            selectedModel = pickerItems.first?.id
        }
        isLoadingModel = false

        rebuildVisibleBlocks()
    }

    /// Reset for a specific agent
    func reset(for newAgentId: UUID?) {
        agentId = newAgentId
        reset()
        Task { [weak self] in await self?.refreshMemoryTokens() }
    }

    /// Invalidate the token cache (called when tools/skills change)
    func invalidateTokenCache() {
        _tokenCacheValid = false
        budgetTracker.clear()
        objectWillChange.send()
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
            agentId: agentId
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
        ChatSessionsManager.shared.save(data)
        onSessionChanged?()
    }

    /// Load session from persisted data
    func load(from data: ChatSessionData) {
        stop()
        sessionId = data.id
        title = data.title
        createdAt = data.createdAt
        updatedAt = data.updatedAt
        agentId = data.agentId

        // Restore saved model if available, otherwise use configured default
        // Don't auto-persist when loading - this is restoring existing state
        isLoadingModel = true
        if let savedModel = data.selectedModel,
            pickerItems.contains(where: { $0.id == savedModel })
        {
            selectedModel = savedModel
        } else {
            // Fall back to agent's model, then global config, then first available
            let effectiveModel = AgentManager.shared.effectiveModel(for: data.agentId ?? Agent.defaultId)
            if let defaultModel = effectiveModel,
                pickerItems.contains(where: { $0.id == defaultModel })
            {
                selectedModel = defaultModel
            } else {
                selectedModel = pickerItems.first?.id
            }
        }
        isLoadingModel = false

        turns = data.turns.map { ChatTurn(from: $0) }
        voiceInputState = .idle
        showVoiceOverlay = false
        input = ""
        pendingAttachments = []
        isDirty = false  // Fresh load, not dirty
        // Clear caches to force a clean block rebuild for the new session
        blockMemoizer.clear()
        _tokenCacheValid = false
        rebuildVisibleBlocks()

        Task { [weak self] in await self?.refreshMemoryTokens() }
    }

    private func refreshMemoryTokens() async {
        let effectiveAgentId = agentId ?? Agent.defaultId
        let config = MemoryConfigurationStore.load()
        let context = await MemoryContextAssembler.assembleContext(
            agentId: effectiveAgentId.uuidString,
            config: config
        )
        updateMemoryTokens(fromContext: context)
    }

    private func updateMemoryTokens(fromContext context: String) {
        let tokens = context.isEmpty ? 0 : max(1, context.count / MemoryConfiguration.charsPerToken)
        guard tokens != _memoryContextTokens else { return }
        _memoryContextTokens = tokens
        _tokenCacheValid = false
        objectWillChange.send()
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
        rebuildVisibleBlocks()
        save()
        send("")  // Empty send to trigger regeneration with existing history
    }

    /// Delete a turn and all subsequent turns
    func deleteTurn(id: UUID) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        turns = Array(turns.prefix(index))
        isDirty = true
        rebuildVisibleBlocks()
        save()
    }

    /// Regenerate an assistant response (removes it and regenerates)
    func regenerate(turnId: UUID) {
        guard let index = turns.firstIndex(where: { $0.id == turnId }) else { return }
        guard turns[index].role == .assistant else { return }

        // Remove this turn and all subsequent turns
        turns = Array(turns.prefix(index))
        isDirty = true
        rebuildVisibleBlocks()

        // Regenerate
        send("")
    }

    // MARK: - Share Artifact Processing

    /// Process share_artifact tool results in chat context.
    /// Uses the shared processing pipeline to copy files, persist to DB,
    /// and enrich the result metadata for ContentBlock display.
    private func processShareArtifactResult(
        toolResult: String,
        executionMode: WorkExecutionMode
    ) -> String {
        guard let sessionId else { return toolResult }
        let agentName = SandboxAgentProvisioner.linuxName(
            for: (agentId ?? Agent.defaultId).uuidString
        )
        if let processed = SharedArtifact.processToolResult(
            toolResult,
            contextId: sessionId.uuidString,
            contextType: .chat,
            executionMode: executionMode,
            sandboxAgentName: agentName
        ) {
            return processed.enrichedToolResult
        }
        return toolResult
    }

    private struct RunContext {
        let hasContent: Bool
        let userContent: String
        let memoryAgentId: String
        let memoryConversationId: String
    }

    private func isRunActive(_ runId: UUID) -> Bool {
        activeRunId == runId && !Task.isCancelled
    }

    private func trimTrailingEmptyAssistantTurn() {
        if let lastTurn = turns.last,
            lastTurn.role == .assistant,
            lastTurn.contentIsEmpty,
            lastTurn.toolCalls == nil,
            !lastTurn.hasThinking
        {
            turns.removeLast()
        }
    }

    private func consolidateAssistantTurns() {
        for turn in turns where turn.role == .assistant {
            turn.consolidateContent()
        }
    }

    private func beginRun(_ runId: UUID, context: RunContext) {
        activeRunId = runId
        activeRunContext = context
    }

    private func estimatedChatExecutionMode(agentId: UUID) -> WorkExecutionMode {
        AgentManager.shared.effectiveAutonomousExec(for: agentId)?.enabled == true ? .sandbox : .none
    }

    private func completeRunCleanup() {
        currentTask = nil
        isStreaming = false
        budgetTracker.clear()
        _tokenCacheValid = false
        ServerController.signalGenerationEnd()
        trimTrailingEmptyAssistantTurn()
        consolidateAssistantTurns()
        rebuildVisibleBlocks()
        save()
    }

    private func finalizeRun(runId: UUID?, persistConversationArtifacts: Bool) {
        guard let runId, activeRunId == runId else { return }

        let context = activeRunContext
        activeRunId = nil
        activeRunContext = nil
        completeRunCleanup()

        guard persistConversationArtifacts, let context else { return }

        let assistantContent = turns.last(where: { $0.role == .assistant })?.content

        if context.hasContent, let sid = sessionId {
            let convId = sid.uuidString
            let aid = context.memoryAgentId
            let chunkIdx = turns.count
            let db = MemoryDatabase.shared
            do { try db.upsertConversation(id: convId, agentId: aid, title: title) } catch {
                MemoryLogger.database.warning("Failed to upsert conversation: \(error)")
            }
            let userChunkIndex = chunkIdx - 1
            do {
                try db.insertChunk(
                    conversationId: convId,
                    chunkIndex: userChunkIndex,
                    role: "user",
                    content: context.userContent,
                    tokenCount: max(1, context.userContent.count / 4)
                )
            } catch {
                MemoryLogger.database.warning("Failed to insert user chunk: \(error)")
            }
            let userChunk = ConversationChunk(
                conversationId: convId,
                chunkIndex: userChunkIndex,
                role: "user",
                content: context.userContent,
                tokenCount: max(1, context.userContent.count / 4)
            )
            Task.detached {
                await EmbeddingService.awaitStartupInit()
                await MemorySearchService.shared.indexConversationChunk(userChunk)
            }
            if let assistantContent, !assistantContent.isEmpty {
                do {
                    try db.insertChunk(
                        conversationId: convId,
                        chunkIndex: chunkIdx,
                        role: "assistant",
                        content: assistantContent,
                        tokenCount: max(1, assistantContent.count / 4)
                    )
                } catch {
                    MemoryLogger.database.warning("Failed to insert assistant chunk: \(error)")
                }
                let assistantChunk = ConversationChunk(
                    conversationId: convId,
                    chunkIndex: chunkIdx,
                    role: "assistant",
                    content: assistantContent,
                    tokenCount: max(1, assistantContent.count / 4)
                )
                Task.detached {
                    await EmbeddingService.awaitStartupInit()
                    await MemorySearchService.shared.indexConversationChunk(assistantChunk)
                }
            }
        }

        if context.hasContent {
            let today = ISO8601DateFormatter.string(
                from: Date(),
                timeZone: .current,
                formatOptions: [.withFullDate, .withDashSeparatorInDate]
            )
            Task.detached {
                await MemoryService.shared.recordConversationTurn(
                    userMessage: context.userContent,
                    assistantMessage: assistantContent,
                    agentId: context.memoryAgentId,
                    conversationId: context.memoryConversationId,
                    sessionDate: today
                )
            }
        }

        ActivityTracker.shared.recordActivity(agentId: context.memoryAgentId)
    }

    func prepareChatExecutionMode(agentId: UUID) async -> WorkExecutionMode {
        guard AgentManager.shared.effectiveAutonomousExec(for: agentId)?.enabled == true else {
            return .none
        }

        await SandboxToolRegistrar.shared.registerTools(for: agentId)
        return ToolRegistry.shared.resolveWorkExecutionMode(folderContext: nil)
    }

    /// Build system prompt with execution-mode-specific sections (sandbox instructions, etc.).
    func buildSystemPrompt(
        base: String,
        agentId: UUID,
        executionMode: WorkExecutionMode,
        compact: Bool = false
    ) -> String {
        let prompt = base.trimmingCharacters(in: .whitespacesAndNewlines)

        guard executionMode.usesSandboxTools else { return prompt }
        let secretNames = Array(AgentSecretsKeychain.getAllSecrets(agentId: agentId).keys)
        let sandboxSection = WorkExecutionEngine.chatSandboxPromptSection(compact: compact, secretNames: secretNames)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if prompt.isEmpty {
            return sandboxSection
        }
        return prompt + "\n\n" + sandboxSection
    }

    /// Build tool specifications: always-loaded set for chat mode.
    func buildToolSpecs(executionMode: WorkExecutionMode, excludeCapabilityTools: Bool = false) -> [Tool] {
        ToolRegistry.shared.alwaysLoadedSpecs(mode: executionMode, excludeCapabilityTools: excludeCapabilityTools)
    }

    func send(_ text: String, attachments: [Attachment] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasContent = !trimmed.isEmpty || !attachments.isEmpty
        let isRegeneration = !hasContent && !turns.isEmpty
        guard hasContent || isRegeneration else { return }

        if hasContent {
            turns.append(ChatTurn(role: .user, content: trimmed, attachments: attachments))
            isDirty = true
            rebuildVisibleBlocks()

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
                ChatSessionsManager.shared.save(data)
                onSessionChanged?()
            }
        }

        let memoryAgentId = (agentId ?? Agent.defaultId).uuidString
        let memoryConversationId = (sessionId ?? UUID()).uuidString
        if hasContent {
            ActivityTracker.shared.recordActivity(agentId: memoryAgentId)
        }

        let runId = UUID()
        beginRun(
            runId,
            context: RunContext(
                hasContent: hasContent,
                userContent: trimmed,
                memoryAgentId: memoryAgentId,
                memoryConversationId: memoryConversationId
            )
        )

        currentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.isRunActive(runId) else { return }
            debugLog("send: task started runId=\(runId) model=\(self.selectedModel ?? "nil")")
            lastStreamError = nil
            isStreaming = true
            ServerController.signalGenerationStart()
            defer {
                finalizeRun(runId: runId, persistConversationArtifacts: true)
            }

            var assistantTurn = ChatTurn(role: .assistant, content: "")
            turns.append(assistantTurn)
            // Must refresh block memoizer before first delta — otherwise visibleBlocks stays
            // user-only while isStreaming is true and the table early-returns without assistant rows.
            rebuildVisibleBlocks()
            do {
                let engine = chatEngineFactory()
                let chatCfg = ChatConfigurationStore.load()

                // MARK: - Capability Setup
                let effectiveAgentId = agentId ?? Agent.defaultId
                let executionMode = await prepareChatExecutionMode(agentId: effectiveAgentId)
                guard isRunActive(runId) else { return }

                let baseSystemPrompt = SystemPromptBuilder.effectiveBasePrompt(
                    AgentManager.shared.effectiveSystemPrompt(for: effectiveAgentId)
                )

                let memoryConfig = MemoryConfigurationStore.load()
                let memoryContext = await MemoryContextAssembler.assembleContext(
                    agentId: effectiveAgentId.uuidString,
                    config: memoryConfig
                )
                guard isRunActive(runId) else { return }
                updateMemoryTokens(fromContext: memoryContext)

                // Pre-flight RAG: search capabilities based on user's message.
                // Skipped when disableTools is set or when the agent uses manual tool selection.
                let toolsDisabled = chatCfg.disableTools
                let toolMode = AgentManager.shared.effectiveToolSelectionMode(for: effectiveAgentId)
                let preflight: PreflightResult
                if !toolsDisabled && toolMode == .auto {
                    let preflightMode = chatCfg.preflightSearchMode ?? .balanced
                    preflight = await PreflightCapabilitySearch.search(query: trimmed, mode: preflightMode)
                } else {
                    preflight = PreflightResult(toolSpecs: [], contextSnippet: "", items: [])
                }
                guard isRunActive(runId) else { return }

                if !preflight.items.isEmpty {
                    assistantTurn.preflightCapabilities = preflight.items
                }

                let isCompact = SystemPromptBuilder.isLocalModel(selectedModel)
                var sys = buildSystemPrompt(
                    base: baseSystemPrompt,
                    agentId: effectiveAgentId,
                    executionMode: executionMode,
                    compact: isCompact
                )

                if !preflight.contextSnippet.isEmpty {
                    sys += "\n\n" + preflight.contextSnippet
                }

                sys = SystemPromptBuilder.prependMemoryContext(memoryContext, to: sys)
                let isManualTools = toolMode == .manual
                var toolSpecs =
                    toolsDisabled
                    ? []
                    : buildToolSpecs(executionMode: executionMode, excludeCapabilityTools: isManualTools)

                if !toolsDisabled {
                    if isManualTools {
                        if let manualNames = AgentManager.shared.effectiveManualToolNames(for: effectiveAgentId) {
                            let manualSpecs = ToolRegistry.shared.specs(forTools: manualNames)
                            for spec in manualSpecs
                            where !toolSpecs.contains(where: { $0.function.name == spec.function.name }) {
                                toolSpecs.append(spec)
                            }
                        }
                    } else {
                        for spec in preflight.toolSpecs
                        where !toolSpecs.contains(where: { $0.function.name == spec.function.name }) {
                            toolSpecs.append(spec)
                        }
                    }
                }

                if isManualTools,
                    let section = await SkillManager.shared.manualSkillPromptSection(for: effectiveAgentId)
                {
                    sys += "\n\n" + section
                }

                budgetTracker.snapshot(
                    systemPromptChars: sys.count,
                    memoryTokens: _memoryContextTokens,
                    toolTokens: ToolRegistry.shared.totalEstimatedTokens(for: toolSpecs)
                )

                let effectiveMaxTokensForAgent = AgentManager.shared.effectiveMaxTokens(for: effectiveAgentId)

                /// Convert a single turn to a ChatMessage (returns nil if should be skipped)
                @MainActor
                func turnToMessage(_ t: ChatTurn, isLastTurn: Bool) -> ChatMessage? {
                    switch t.role {
                    case .assistant:
                        // Skip the last assistant turn if it's empty (it's the streaming placeholder)
                        if isLastTurn && t.contentIsEmpty && t.toolCalls == nil {
                            return nil
                        }

                        if t.contentIsEmpty && (t.toolCalls == nil || t.toolCalls!.isEmpty) {
                            return nil
                        }

                        let content: String? = t.contentIsEmpty ? nil : t.content

                        return ChatMessage(
                            role: "assistant",
                            content: content,
                            tool_calls: t.toolCalls,
                            tool_call_id: nil
                        )
                    case .tool:
                        return ChatMessage(
                            role: "tool",
                            content: t.content,
                            tool_calls: nil,
                            tool_call_id: t.toolCallId
                        )
                    case .user:
                        let messageText = Self.buildUserMessageText(content: t.content, attachments: t.attachments)
                        let imageData = t.attachments.images
                        if !imageData.isEmpty {
                            return ChatMessage(role: "user", text: messageText, imageData: imageData)
                        } else {
                            return ChatMessage(role: t.role.rawValue, content: messageText)
                        }
                    default:
                        return ChatMessage(role: t.role.rawValue, content: t.content)
                    }
                }

                @MainActor
                func buildMessages() -> [ChatMessage] {
                    var msgs: [ChatMessage] = []
                    if !sys.isEmpty { msgs.append(ChatMessage(role: "system", content: sys)) }

                    for (index, t) in turns.enumerated() {
                        let isLastTurn = index == turns.count - 1
                        if let msg = turnToMessage(t, isLastTurn: isLastTurn) {
                            msgs.append(msg)
                        }
                    }

                    return msgs
                }

                let maxAttempts = max(chatCfg.maxToolAttempts ?? 15, 1)
                let toolBudgetWarningThreshold = 3
                var attempts = 0
                var reachedToolLimit = false
                var pendingBudgetNotice: String?
                let effectiveTemp = AgentManager.shared.effectiveTemperature(for: effectiveAgentId)

                outer: while attempts < maxAttempts {
                    attempts += 1
                    var msgs = buildMessages()
                    if let notice = pendingBudgetNotice {
                        msgs.append(ChatMessage(role: "user", content: notice))
                        pendingBudgetNotice = nil
                    }
                    let convTokens =
                        msgs
                        .filter { $0.role != "system" }
                        .reduce(0) { $0 + ContextBudgetManager.estimateTokens(for: $1.content) }
                    budgetTracker.updateConversation(tokens: convTokens, finishedOutputTurn: assistantTurn)
                    var req = ChatCompletionRequest(
                        model: selectedModel ?? "default",
                        messages: msgs,
                        temperature: effectiveTemp,
                        max_tokens: effectiveMaxTokensForAgent ?? 16384,
                        stream: true,
                        top_p: chatCfg.topPOverride,
                        frequency_penalty: nil,
                        presence_penalty: nil,
                        stop: nil,
                        n: nil,
                        tools: toolSpecs.isEmpty ? nil : toolSpecs,
                        tool_choice: toolSpecs.isEmpty ? nil : .auto,
                        session_id: sessionId?.uuidString
                    )
                    req.modelOptions = activeModelOptions.isEmpty ? nil : activeModelOptions
                    debugLog(
                        "send: attempt=\(attempts) model=\(req.model) tools=\(req.tools?.count ?? 0) sessionId=\(req.session_id ?? "nil")"
                    )
                    do {
                        let streamStartTime = Date()
                        var uiDeltaCount = 0

                        let processor = StreamingDeltaProcessor(
                            turn: assistantTurn,
                            modelId: selectedModel ?? "default",
                            modelOptions: activeModelOptions
                        ) { [weak self] in
                            // rebuildVisibleBlocks mutates @Published properties which already
                            // emit objectWillChange — the extra send() below is redundant.
                            self?.rebuildVisibleBlocks()
                        }

                        let stream = try await engine.streamChat(request: req)
                        debugLog("send: got stream, entering delta loop")
                        for try await delta in stream {
                            if !isRunActive(runId) {
                                processor.finalize()
                                break outer
                            }
                            if let toolName = StreamingToolHint.decode(delta) {
                                assistantTurn.pendingToolName = toolName
                                rebuildVisibleBlocks()
                                continue
                            }
                            if let argFragment = StreamingToolHint.decodeArgs(delta) {
                                assistantTurn.appendToolArgFragment(argFragment)
                                // throttle: only refresh every 5 fragments to avoid flooding the
                                // table with row reconfigurations during arg streaming.
                                if assistantTurn.pendingToolArgSize % 5 == 0 {
                                    rebuildVisibleBlocks()
                                }
                                continue
                            }
                            if !delta.isEmpty {
                                uiDeltaCount += 1
                                processor.receiveDelta(delta)
                            }
                        }

                        // Flush any remaining buffered content (including partial tags)
                        processor.finalize()

                        let totalTime = Date().timeIntervalSince(streamStartTime)
                        print(
                            "[Osaurus][UI] Stream consumption completed: \(uiDeltaCount) deltas in \(String(format: "%.2f", totalTime))s, final contentLen=\(assistantTurn.contentLength)"
                        )

                        break  // finished normally
                    } catch let inv as ServiceToolInvocation {
                        guard isRunActive(runId) else { break outer }
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
                            function: ToolCallFunction(name: inv.toolName, arguments: inv.jsonArguments),
                            geminiThoughtSignature: inv.geminiThoughtSignature
                        )
                        assistantTurn.pendingToolName = nil
                        assistantTurn.clearPendingToolArgs()
                        if assistantTurn.toolCalls == nil { assistantTurn.toolCalls = [] }
                        assistantTurn.toolCalls!.append(call)

                        // Execute tool and append hidden tool result turn
                        var resultText: String
                        do {
                            // Log tool execution start
                            let truncatedArgs = inv.jsonArguments.prefix(200)
                            print(
                                "[Osaurus][Tool] Executing: \(inv.toolName) with args: \(truncatedArgs)\(inv.jsonArguments.count > 200 ? "..." : "")"
                            )

                            if executionMode.usesSandboxTools {
                                await SandboxToolRegistrar.shared.registerTools(for: effectiveAgentId)
                                if !isRunActive(runId) { break outer }
                            }

                            resultText = try await WorkExecutionContext.$currentAgentId.withValue(effectiveAgentId) {
                                try await ToolRegistry.shared.execute(
                                    name: inv.toolName,
                                    argumentsJSON: inv.jsonArguments
                                )
                            }
                            if !isRunActive(runId) { break outer }

                            // Hot-load tools injected by capabilities_load or sandbox_plugin_register.
                            // Skipped in manual mode — the user's explicit tool set is fixed.
                            if !isManualTools,
                                inv.toolName == "capabilities_load"
                                    || inv.toolName == "sandbox_plugin_register"
                            {
                                let newTools = await CapabilityLoadBuffer.shared.drain()
                                for tool in newTools
                                where !toolSpecs.contains(where: { $0.function.name == tool.function.name }) {
                                    toolSpecs.append(tool)
                                }
                            }

                            if inv.toolName == "share_artifact" {
                                resultText = processShareArtifactResult(
                                    toolResult: resultText,
                                    executionMode: executionMode
                                )
                                if let artifact = SharedArtifact.fromEnrichedToolResult(resultText) {
                                    PluginManager.shared.notifyArtifactHandlers(artifact: artifact)
                                }
                            }

                            if inv.toolName == "sandbox_secret_set",
                                let prompt = SecretPromptParser.parse(resultText)
                            {
                                let stored: Bool = await withCheckedContinuation { continuation in
                                    let promptState = SecretPromptState(
                                        key: prompt.key,
                                        description: prompt.description,
                                        instructions: prompt.instructions,
                                        agentId: prompt.agentId
                                    ) { value in
                                        continuation.resume(returning: value != nil)
                                    }
                                    self.pendingSecretPrompt = promptState
                                }
                                self.pendingSecretPrompt = nil
                                resultText =
                                    stored
                                    ? SecretToolResult.stored(key: prompt.key)
                                    : SecretToolResult.cancelled(key: prompt.key)
                            }

                            // Log tool success (truncated result)
                            let truncatedResult = resultText.prefix(500)
                            print(
                                "[Osaurus][Tool] Success: \(inv.toolName) returned \(resultText.count) chars: \(truncatedResult)\(resultText.count > 500 ? "..." : "")"
                            )
                        } catch {
                            // Store rejection/error as the result so UI shows "Rejected" instead of hanging
                            let rejectionMessage = "[REJECTED] \(error.localizedDescription)"
                            assistantTurn.toolResults[callId] = rejectionMessage
                            let toolTurn = ChatTurn(role: .tool, content: rejectionMessage)
                            toolTurn.toolCallId = callId
                            turns.append(toolTurn)
                            break  // Stop tool loop on rejection
                        }
                        guard isRunActive(runId) else { break }
                        assistantTurn.toolResults[callId] = resultText
                        let toolTurn = ChatTurn(role: .tool, content: resultText)
                        toolTurn.toolCallId = callId

                        // Create a new assistant turn for subsequent content
                        // This ensures tool calls and text are rendered sequentially
                        let newAssistantTurn = ChatTurn(role: .assistant, content: "")

                        // Batch both appends into a single mutation to reduce
                        // the number of @Published change signals and SwiftUI layout passes.
                        turns.append(contentsOf: [toolTurn, newAssistantTurn])
                        assistantTurn = newAssistantTurn
                        rebuildVisibleBlocks()

                        let remaining = maxAttempts - attempts
                        if remaining <= 0 {
                            reachedToolLimit = true
                        } else if remaining <= toolBudgetWarningThreshold {
                            pendingBudgetNotice =
                                "[System Notice] Tool call budget: \(remaining) of \(maxAttempts) remaining. Wrap up your current work and provide a summary."
                        }
                        continue
                    }
                }

                if reachedToolLimit && isRunActive(runId) {
                    do {
                        var finalReq = ChatCompletionRequest(
                            model: selectedModel ?? "default",
                            messages: buildMessages(),
                            temperature: effectiveTemp,
                            max_tokens: effectiveMaxTokensForAgent ?? 16384,
                            stream: true,
                            top_p: chatCfg.topPOverride,
                            frequency_penalty: nil,
                            presence_penalty: nil,
                            stop: nil,
                            n: nil,
                            tools: nil,
                            tool_choice: nil,
                            session_id: sessionId?.uuidString
                        )
                        finalReq.modelOptions = activeModelOptions.isEmpty ? nil : activeModelOptions

                        let processor = StreamingDeltaProcessor(
                            turn: assistantTurn,
                            modelId: selectedModel ?? "default",
                            modelOptions: activeModelOptions
                        ) { [weak self] in
                            self?.rebuildVisibleBlocks()
                        }

                        let stream = try await engine.streamChat(request: finalReq)
                        for try await delta in stream {
                            if !isRunActive(runId) { break }
                            if !delta.isEmpty { processor.receiveDelta(delta) }
                        }
                        processor.finalize()
                    } catch {
                        debugLog("send: final wrap-up call failed: \(error.localizedDescription)")
                    }
                }
            } catch {
                assistantTurn.content = "Error: \(error.localizedDescription)"
                lastStreamError = error.localizedDescription
            }
        }
    }
}

// MARK: - ChatView

struct ChatView: View {
    // MARK: - Window State

    /// Per-window state container (isolates this window from shared singletons)
    @ObservedObject private var windowState: ChatWindowState

    // MARK: - Environment & State

    @Environment(\.colorScheme) private var colorScheme

    @State private var focusTrigger: Int = 0
    @State private var isPinnedToBottom: Bool = true
    @State private var scrollToBottomTrigger: Int = 0
    @State private var keyMonitor: Any?
    // Inline editing state
    @State private var editingTurnId: UUID?
    @State private var editText: String = ""
    @State private var userImagePreview: NSImage?
    // Bonjour agent connection
    @State private var pendingDiscoveredAgent: DiscoveredAgent? = nil

    /// Convenience accessor for the window's theme
    private var theme: ThemeProtocol { windowState.theme }

    /// Convenience accessor for the window ID
    private var windowId: UUID { windowState.windowId }

    /// Picker items filtered to the active Bonjour provider, or all items when no Bonjour agent is selected.
    private var filteredPickerItems: [ModelPickerItem] {
        guard let providerId = windowState.selectedDiscoveredAgentProviderId else {
            return session.pickerItems
        }
        return session.pickerItems.filter {
            if case .remote(_, let id) = $0.source { return id == providerId }
            return false
        }
    }

    /// Observed session - needed to properly propagate @Published changes from ChatSession
    @ObservedObject private var observedSession: ChatSession

    /// Convenience accessor for the session (uses observedSession for proper SwiftUI updates)
    private var session: ChatSession { observedSession }

    // MARK: - Initializers

    /// Multi-window initializer with window state
    init(windowState: ChatWindowState) {
        _windowState = ObservedObject(wrappedValue: windowState)
        _observedSession = ObservedObject(wrappedValue: windowState.session)
    }

    /// Convenience initializer with window ID and optional initial state
    init(
        windowId: UUID,
        initialAgentId: UUID? = nil,
        initialSessionData: ChatSessionData? = nil
    ) {
        let agentId = initialSessionData?.agentId ?? initialAgentId ?? Agent.defaultId
        let state = ChatWindowState(
            windowId: windowId,
            agentId: agentId,
            sessionData: initialSessionData
        )
        _windowState = ObservedObject(wrappedValue: state)
        _observedSession = ObservedObject(wrappedValue: state.session)
    }

    var body: some View {
        Group {
            // Switch between Chat and Work modes
            if windowState.mode == .work, let workSession = windowState.workSession {
                WorkView(windowState: windowState, session: workSession)
            } else {
                chatModeContent
            }
        }
        .themedAlert(
            "Work Task Running",
            isPresented: workCloseConfirmationPresented,
            message:
                "This work task is still active. You can keep it running in the background (with a live toast), or stop it and close this window.",
            buttons: [
                .primary("Run in Background") {
                    if let session = windowState.workSession {
                        BackgroundTaskManager.shared.detachWindow(
                            windowState.windowId,
                            session: session,
                            windowState: windowState
                        )
                    }
                    ChatWindowManager.shared.closeWindow(id: windowState.windowId)
                },
                .destructive("Stop Task & Close") {
                    windowState.workSession?.cancelExecution()
                    ChatWindowManager.shared.closeWindow(id: windowState.windowId)
                },
                .cancel("Cancel"),
            ]
        )
        .themedAlertScope(.chat(windowState.windowId))
        .overlay(ThemedAlertHost(scope: .chat(windowState.windowId)))
        .overlay {
            if let promptState = session.pendingSecretPrompt {
                SecretPromptOverlay(state: promptState) {
                    promptState.cancel()
                    session.pendingSecretPrompt = nil
                }
            }
        }
    }

    private var workCloseConfirmationPresented: Binding<Bool> {
        Binding(
            get: { windowState.workCloseConfirmation != nil },
            set: { newValue in
                if !newValue {
                    windowState.workCloseConfirmation = nil
                }
            }
        )
    }

    /// Chat mode content - the original ChatView implementation
    @ViewBuilder
    private var chatModeContent: some View {
        GeometryReader { proxy in
            let sidebarWidth: CGFloat = windowState.showSidebar ? 240 : 0
            let chatWidth = proxy.size.width - sidebarWidth

            HStack(alignment: .top, spacing: 0) {
                // Sidebar
                if windowState.showSidebar {
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
                                    agentId: sessionData.agentId,
                                    sessionData: sessionData
                                )
                            }
                        )
                    }
                    .frame(width: 240, alignment: .top)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 0)
                    .zIndex(1)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }

                // Main chat area
                ZStack {
                    // Background
                    chatBackground

                    // Main content
                    VStack(spacing: 0) {
                        // Header
                        chatHeader

                        // Content area (show immediately, model discovery is async)
                        if session.hasAnyModel || session.isDiscoveringModels {
                            if !session.hasVisibleThreadMessages {
                                // Empty state
                                ChatEmptyState(
                                    hasModels: true,
                                    selectedModel: session.selectedModel,
                                    agents: windowState.agents,
                                    activeAgentId: windowState.agentId,
                                    quickActions: windowState.activeAgent.chatQuickActions
                                        ?? AgentQuickAction.defaultChatQuickActions,
                                    onOpenModelManager: {
                                        AppDelegate.shared?.showManagementWindow(initialTab: .models)
                                    },
                                    onUseFoundation: windowState.foundationModelAvailable
                                        ? {
                                            session.selectedModel = session.pickerItems.first?.id ?? "foundation"
                                        } : nil,
                                    onQuickAction: { prompt in
                                        session.input = prompt
                                    },
                                    onSelectAgent: { newAgentId in
                                        windowState.switchAgent(to: newAgentId)
                                    },
                                    onOpenOnboarding: nil,
                                    discoveredAgents: windowState.discoveredAgents,
                                    onSelectDiscoveredAgent: { agent in pendingDiscoveredAgent = agent },
                                    activeDiscoveredAgent: windowState.selectedDiscoveredAgent
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
                                pendingAttachments: $observedSession.pendingAttachments,
                                isContinuousVoiceMode: $observedSession.isContinuousVoiceMode,
                                voiceInputState: $observedSession.voiceInputState,
                                showVoiceOverlay: $observedSession.showVoiceOverlay,
                                pickerItems: filteredPickerItems,
                                activeModelOptions: $observedSession.activeModelOptions,
                                isStreaming: observedSession.isStreaming,
                                supportsImages: observedSession.selectedModelSupportsImages,
                                estimatedContextTokens: observedSession.estimatedContextTokens,
                                contextBreakdown: observedSession.estimatedContextBreakdown,
                                onSend: { manualText in
                                    if let manualText = manualText {
                                        observedSession.input = manualText
                                    }
                                    observedSession.sendCurrent()
                                },
                                onStop: { observedSession.stop() },
                                focusTrigger: focusTrigger,
                                agentId: windowState.agentId,
                                windowId: windowState.windowId,
                                isCompact: windowState.showSidebar
                            )
                        } else {
                            // No models empty state
                            ChatEmptyState(
                                hasModels: false,
                                selectedModel: nil,
                                agents: windowState.agents,
                                activeAgentId: windowState.agentId,
                                quickActions: windowState.activeAgent.chatQuickActions
                                    ?? AgentQuickAction.defaultChatQuickActions,
                                onOpenModelManager: {
                                    AppDelegate.shared?.showManagementWindow(initialTab: .models)
                                },
                                onUseFoundation: windowState.foundationModelAvailable
                                    ? {
                                        session.selectedModel = session.pickerItems.first?.id ?? "foundation"
                                    } : nil,
                                onQuickAction: { _ in },
                                onSelectAgent: { newAgentId in
                                    windowState.switchAgent(to: newAgentId)
                                },
                                onOpenOnboarding: {
                                    // If onboarding was already completed, just refresh models
                                    // Don't reset onboarding - the user just finished it
                                    if !OnboardingService.shared.shouldShowOnboarding {
                                        Task { @MainActor in
                                            await session.refreshPickerItems()
                                        }
                                        return
                                    }
                                    // Only reset for users who never completed onboarding
                                    OnboardingService.shared.resetOnboarding()
                                    // Close this window so user can focus on onboarding
                                    ChatWindowManager.shared.closeWindow(id: windowState.windowId)
                                    // Show onboarding window
                                    AppDelegate.shared?.showOnboardingWindow()
                                },
                                discoveredAgents: windowState.discoveredAgents,
                                onSelectDiscoveredAgent: { agent in pendingDiscoveredAgent = agent }
                            )
                        }
                    }
                    .animation(theme.springAnimation(responseMultiplier: 0.9), value: session.hasVisibleThreadMessages)
                }
            }
        }
        .frame(
            minWidth: 800,
            idealWidth: 950,
            maxWidth: .infinity,
            minHeight: 575,
            idealHeight: 610,
            maxHeight: .infinity
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .ignoresSafeArea()
        .onReceive(NotificationCenter.default.publisher(for: .chatOverlayActivated)) { _ in
            // Lightweight state updates only - refreshAll() removed to prevent excessive re-renders
            focusTrigger &+= 1
            isPinnedToBottom = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .vadStartNewSession)) { notification in
            // VAD requested a new session for a specific agent
            // Only handle if this is the targeted window
            if let agentId = notification.object as? UUID {
                // Only switch if this window's agent matches the VAD request
                if agentId == windowState.agentId {
                    windowState.startNewChat()
                }
            }
        }
        .onAppear {
            setupKeyMonitor()

            // Register close callback with ChatWindowManager
            ChatWindowManager.shared.setCloseCallback(for: windowState.windowId) { [weak windowState] in
                windowState?.cleanup()
                windowState?.session.save()
            }
        }
        .onDisappear {
            cleanupKeyMonitor()
        }
        .onChange(of: observedSession.pickerItems) { _, newItems in
            guard let providerId = windowState.selectedDiscoveredAgentProviderId else { return }
            let providerItems = newItems.filter {
                if case .remote(_, let id) = $0.source { return id == providerId }
                return false
            }
            guard let firstItem = providerItems.first else { return }
            let currentIsFromProvider =
                newItems.first(where: { $0.id == session.selectedModel }).map {
                    if case .remote(_, let id) = $0.source { return id == providerId }
                    return false
                } ?? false
            if !currentIsFromProvider {
                session.selectedModel = firstItem.id
            }
        }
        .onChange(of: windowState.selectedDiscoveredAgentProviderId) { _, providerId in
            guard providerId == nil else { return }
            // Bonjour agent deselected — restore agent's preferred model
            let agentModel = AgentManager.shared.effectiveModel(for: windowState.agentId)
            if let model = agentModel, session.pickerItems.contains(where: { $0.id == model }) {
                session.selectedModel = model
            } else {
                session.selectedModel = session.pickerItems.first?.id
            }
        }
        .environment(\.theme, windowState.theme)
        .tint(theme.accentColor)
        .sheet(item: $pendingDiscoveredAgent) { agent in
            BonjourTokenSheet(agentName: agent.name) { token in
                connectToDiscoveredAgent(agent, token: token)
                pendingDiscoveredAgent = nil
            } onCancel: {
                pendingDiscoveredAgent = nil
            }
            .environment(\.theme, windowState.theme)
        }
    }

    private func connectToDiscoveredAgent(_ agent: DiscoveredAgent, token: String) {
        // Strip trailing dot from mDNS hostnames (e.g. "device.local." -> "device.local")
        let rawHost = agent.host ?? "localhost"
        let host = rawHost.hasSuffix(".") ? String(rawHost.dropLast()) : rawHost
        let manager = RemoteProviderManager.shared

        let providerId: UUID
        // Reuse an existing provider that points to the same host:port
        if let existing = manager.configuration.providers.first(where: {
            $0.host == host && $0.effectivePort == agent.port
        }) {
            providerId = existing.id
            if !token.isEmpty {
                var updated = existing
                updated.authType = .apiKey
                updated.enabled = true
                manager.updateProvider(updated, apiKey: token)
            }
            Task { try? await manager.connect(providerId: existing.id) }
        } else {
            let provider = RemoteProvider(
                name: agent.name,
                host: host,
                providerProtocol: .http,
                port: agent.port,
                basePath: "/v1",
                authType: token.isEmpty ? .none : .apiKey,
                providerType: .openai,
                enabled: true,
                autoConnect: true
            )
            providerId = provider.id
            manager.addProvider(provider, apiKey: token.isEmpty ? nil : token, isEphemeral: true)
        }

        windowState.selectedDiscoveredAgent = agent
        windowState.selectedDiscoveredAgentProviderId = providerId
        Task { await session.refreshPickerItems() }
    }

    // MARK: - Background

    private var chatBackground: some View {
        ZStack {
            // Layer 1: Base background (solid, gradient, or image)
            baseBackgroundLayer
                .clipShape(backgroundShape)

            // Layer 2: Glass effect (if enabled)
            /*
            if theme.glassEnabled {
                ThemedGlassSurface(
                    cornerRadius: 24,
                    topLeadingRadius: windowState.showSidebar ? 0 : nil,
                    bottomLeadingRadius: windowState.showSidebar ? 0 : nil
                )
                .allowsHitTesting(false)
            
                // Solid backing scaled by glass opacity so low values produce real transparency
                let baseBacking = theme.windowBackingOpacity
                let backingOpacity = baseBacking * (0.4 + theme.glassOpacityPrimary * 0.6)
            
                LinearGradient(
                    colors: [
                        theme.primaryBackground.opacity(backingOpacity + theme.glassOpacityPrimary * 0.3),
                        theme.primaryBackground.opacity(backingOpacity + theme.glassOpacitySecondary * 0.2),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .clipShape(backgroundShape)
                .allowsHitTesting(false)
            }
            */
        }
    }

    private var backgroundShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: windowState.showSidebar ? 0 : 24,
            bottomLeadingRadius: windowState.showSidebar ? 0 : 24,
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
                // Use pre-decoded background image from windowState (decoded once, not on every render)
                if let image = windowState.cachedBackgroundImage {
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
        Color.clear
            .frame(height: 52)
            .allowsHitTesting(false)
    }

    // MARK: - Message Thread

    /// Isolated message thread view to prevent cascading re-renders
    private func messageThread(_ width: CGFloat) -> some View {
        // read stored @Published values — no blockMemoizer call on every body pass
        let blocks = session.visibleBlocks
        let groupHeaderMap = session.visibleBlocksGroupHeaderMap
        let displayName = windowState.cachedAgentDisplayName
        let lastAssistantTurnId = session.lastAssistantTurnIdForThread

        return ZStack {
            MessageThreadView(
                blocks: blocks,
                groupHeaderMap: groupHeaderMap,
                width: width,
                agentName: displayName,
                isStreaming: session.isStreaming,
                lastAssistantTurnId: lastAssistantTurnId,
                expandedBlocksStore: session.expandedBlocksStore,
                scrollToBottomTrigger: scrollToBottomTrigger,
                onScrolledToBottom: { isPinnedToBottom = true },
                onScrolledAwayFromBottom: { isPinnedToBottom = false },
                onCopy: copyTurnContent,
                onRegenerate: regenerateTurn,
                onEdit: beginEditingTurn,
                onDelete: deleteTurn,
                editingTurnId: editingTurnId,
                editText: $editText,
                onConfirmEdit: confirmEditAndRegenerate,
                onCancelEdit: cancelEditing,
                onUserImagePreview: openUserAttachmentPreview(attachmentId:)
            )
            .onReceive(NotificationCenter.default.publisher(for: .chatOverlayActivated)) { _ in
                isPinnedToBottom = true
            }

            // Scroll button overlay - isolated from content
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    ScrollToBottomButton(
                        isPinnedToBottom: isPinnedToBottom,
                        hasTurns: session.hasVisibleThreadMessages,
                        onTap: {
                            isPinnedToBottom = true
                            scrollToBottomTrigger += 1
                        }
                    )
                }
            }
        }
        .sheet(
            isPresented: Binding(
                get: { userImagePreview != nil },
                set: { if !$0 { userImagePreview = nil } }
            )
        ) {
            if let img = userImagePreview {
                ImageFullScreenView(image: img, altText: "")
                    .imageFullScreenSheetPresentation()
            }
        }
    }

    private func openUserAttachmentPreview(attachmentId: String) {
        if let img = ChatImageCache.shared.cachedImage(for: attachmentId) {
            userImagePreview = img
            return
        }
        for turn in session.turns {
            for att in turn.attachments where att.id.uuidString == attachmentId {
                if let data = att.imageData, let img = NSImage(data: data) {
                    userImagePreview = img
                    return
                }
            }
        }
        if let url = sharedArtifactImageURL(artifactId: attachmentId),
            let data = try? Data(contentsOf: url),
            let img = NSImage(data: data)
        {
            userImagePreview = img
        }
    }

    private func sharedArtifactImageURL(artifactId: String) -> URL? {
        for block in session.visibleBlocks {
            guard case let .sharedArtifact(art) = block.kind else { continue }
            guard art.id == artifactId, art.isImage, !art.hostPath.isEmpty else { continue }
            return URL(fileURLWithPath: art.hostPath)
        }
        return nil
    }

    /// Copy a turn's thinking + content to the clipboard
    private func copyTurnContent(turnId: UUID) {
        guard let turn = session.turns.first(where: { $0.id == turnId }) else { return }
        var textToCopy = ""
        if turn.hasThinking {
            textToCopy += turn.thinking
        }
        if !turn.contentIsEmpty {
            if !textToCopy.isEmpty { textToCopy += "\n\n" }
            textToCopy += turn.visibleContent
        }
        guard !textToCopy.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textToCopy, forType: .string)
    }

    /// Stable callback for regenerate action - prevents closure recreation
    private func regenerateTurn(turnId: UUID) {
        session.regenerate(turnId: turnId)
    }

    /// Stop any active generation and remove the turn (plus all subsequent turns)
    private func deleteTurn(turnId: UUID) {
        if session.isStreaming { session.stop() }
        session.deleteTurn(id: turnId)
    }

    // MARK: - Inline Editing

    /// Begin inline editing of a user message
    private func beginEditingTurn(turnId: UUID) {
        guard let turn = session.turns.first(where: { $0.id == turnId }),
            turn.role == .user
        else { return }
        editText = turn.content
        editingTurnId = turnId
    }

    /// Confirm the edit and regenerate the assistant response
    private func confirmEditAndRegenerate() {
        guard let turnId = editingTurnId else { return }
        let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        session.editAndRegenerate(turnId: turnId, newContent: trimmed)
        editingTurnId = nil
        editText = ""
    }

    /// Dismiss the inline editor without changes
    private func cancelEditing() {
        editingTurnId = nil
        editText = ""
    }

    // Key monitor for Esc to cancel voice or close window
    private func setupKeyMonitor() {
        if keyMonitor != nil { return }

        let capturedWindowId = windowState.windowId
        let session = windowState.session

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak session] event in
            // Esc key code is 53
            if event.keyCode == 53 {
                // Only handle Esc if this event is for our specific window
                // This prevents closed windows' monitors from handling events for other windows
                guard let ourWindow = ChatWindowManager.shared.getNSWindow(id: capturedWindowId),
                    event.window === ourWindow
                else {
                    return event
                }

                // Session deallocated means the window is gone — pass through
                guard let session else { return event }

                // Check if voice input is active AND overlay is visible
                if SpeechService.shared.isRecording && session.showVoiceOverlay {
                    // Stage 1: Cancel voice input
                    print("[ChatView] Esc pressed: Cancelling voice input")
                    Task {
                        // Stop streaming and clear transcription
                        _ = await SpeechService.shared.stopStreamingTranscription()
                        SpeechService.shared.clearTranscription()
                    }
                    return nil  // Swallow event
                } else {
                    // Stage 2: Close chat window
                    print("[ChatView] Esc pressed: Closing chat window")

                    // Also ensure we cleanup any zombie recording if it exists (hidden but recording)
                    if SpeechService.shared.isRecording {
                        print("[ChatView] Cleaning up zombie voice recording on window close")
                        Task {
                            _ = await SpeechService.shared.stopStreamingTranscription()
                            SpeechService.shared.clearTranscription()
                        }
                    }

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

// MARK: - Bonjour Token Sheet

/// Sheet shown when the user selects a Bonjour-discovered remote agent.
/// Prompts for an optional server token before connecting.
private struct BonjourTokenSheet: View {
    let agentName: String
    let onConnect: (String) -> Void
    let onCancel: () -> Void

    @State private var token: String = ""
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Connect to \(agentName)")
                    .font(theme.font(size: 16, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Text("Enter the server token for this agent, or leave blank if none is required.")
                    .font(theme.font(size: 13))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SecureField("Server token (optional)", text: $token)
                .textFieldStyle(.roundedBorder)
                .font(theme.font(size: 13))

            HStack {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Connect") { onConnect(token) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}

// MARK: - Shared Header Components
// HeaderActionButton, SettingsButton, CloseButton, PinButton are now in SharedHeaderComponents.swift
