//
//  ChatView.swift
//  osaurus
//
//  Created by Terence on 10/26/25.
//

import AppKit
import Combine
import LocalAuthentication
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

    /// Skill ID to inject as one-off context for the next outgoing message.
    /// Set when the user selects a skill from the slash command popup; cleared after send.
    @Published var pendingOneOffSkillId: UUID?

    // MARK: - Persistence Properties
    @Published var sessionId: UUID?
    @Published var title: String = "New Chat"
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    /// Tracks if session has unsaved content changes
    private var isDirty: Bool = false

    // MARK: - Memoization Cache
    private let blockMemoizer = BlockMemoizer()
    private var cachedContext: ComposedContext?
    private let budgetTracker = ContextBudgetTracker()

    /// Callback when session needs to be saved (called after streaming completes)
    var onSessionChanged: (() -> Void)?

    /// Weak back-reference to the owning window state (set by ChatWindowState).
    weak var windowState: ChatWindowState?

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

                // Clear pending image attachments when switching to a non-VLM model
                let newModelSupportsImages: Bool = {
                    if model.lowercased() == "foundation" { return false }
                    guard let option = self.pickerItems.first(where: { $0.id == model }) else { return false }
                    if case .remote = option.source { return true }
                    return option.isVLM
                }()
                if !newModelSupportsImages {
                    self.pendingAttachments = []
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
    /// During streaming, returns the active snapshot with live output tokens.
    /// Otherwise derives from the cached `ComposedContext` or a preview manifest.
    var estimatedContextBreakdown: ContextBreakdown {
        if let active = budgetTracker.activeBreakdown(
            isActive: isStreaming,
            outputTurn: turns.last
        ) {
            return active
        }

        let effectiveId = agentId ?? Agent.defaultId
        let executionMode = estimatedChatExecutionMode(agentId: effectiveId)

        let outputTokens = ContextBudgetManager.estimateOutputTokens(for: turns)
        let conversationTokens = ContextBudgetManager.estimateTokens(for: turns) - outputTokens
        var inputTokens = 0
        if !input.isEmpty { inputTokens += ContextBudgetManager.estimateTokens(for: input) }
        for attachment in pendingAttachments { inputTokens += attachment.estimatedTokens }

        if let ctx = cachedContext {
            return .from(
                context: ctx,
                conversationTokens: conversationTokens,
                inputTokens: inputTokens,
                outputTokens: outputTokens
            )
        }

        let manifest = buildPreviewManifest(agentId: effectiveId, executionMode: executionMode)
        let toolTokens =
            AgentManager.shared.effectiveToolsDisabled(for: effectiveId)
            ? 0
            : ToolRegistry.shared.totalEstimatedTokens(
                for: ToolRegistry.shared.alwaysLoadedSpecs(mode: executionMode)
            )
        return .from(
            manifest: manifest,
            toolTokens: toolTokens,
            conversationTokens: conversationTokens,
            inputTokens: inputTokens,
            outputTokens: outputTokens
        )
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
        pendingOneOffSkillId = nil
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
        cachedContext = nil
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
        cachedContext = nil
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
        cachedContext = nil
        rebuildVisibleBlocks()

        Task { [weak self] in await self?.refreshMemoryTokens() }
    }

    private func refreshMemoryTokens() async {
        let effectiveAgentId = agentId ?? Agent.defaultId
        guard !AgentManager.shared.effectiveMemoryDisabled(for: effectiveAgentId) else {
            if cachedContext?.manifest.memoryTokens ?? 0 > 0 {
                cachedContext = nil
                objectWillChange.send()
            }
            return
        }
        let context = await MemoryContextAssembler.assembleContext(
            agentId: effectiveAgentId.uuidString,
            config: MemoryConfigurationStore.load()
        )
        let newTokens = ContextBudgetManager.estimateTokens(for: context)
        guard newTokens != cachedContext?.manifest.memoryTokens ?? 0 else { return }
        cachedContext = nil
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

        let agentUUID = UUID(uuidString: context.memoryAgentId) ?? Agent.defaultId
        let memoryOff = AgentManager.shared.effectiveMemoryDisabled(for: agentUUID)

        if !memoryOff, context.hasContent, let sid = sessionId {
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
                    await MemorySearchService.shared.indexConversationChunk(assistantChunk)
                }
            }
        }

        if !memoryOff, context.hasContent {
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

    /// Synchronous manifest for offline token estimation (UI popover).
    private func buildPreviewManifest(
        agentId: UUID,
        executionMode: WorkExecutionMode,
        memoryContext: String = ""
    ) -> PromptManifest {
        var composer = SystemPromptComposer.forChat(
            agentId: agentId,
            executionMode: executionMode,
            model: selectedModel
        )
        composer.append(.dynamic(id: "memory", label: "Memory", content: memoryContext))
        return composer.manifest()
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
            #if DEBUG
                let ttftTrace: TTFTTrace? = TTFTTrace()
            #else
                let ttftTrace: TTFTTrace? = nil
            #endif
            do {
                let engine = chatEngineFactory()
                let chatCfg = ChatConfigurationStore.load()

                // MARK: - Capability Setup
                let effectiveAgentId = agentId ?? Agent.defaultId
                ttftTrace?.mark("prepare_exec_mode_start")
                let executionMode = await prepareChatExecutionMode(agentId: effectiveAgentId)
                ttftTrace?.mark("prepare_exec_mode_done")
                guard isRunActive(runId) else { return }

                let context = await SystemPromptComposer.composeChatContext(
                    agentId: effectiveAgentId,
                    executionMode: executionMode,
                    model: selectedModel,
                    query: trimmed,
                    toolsDisabled: chatCfg.disableTools,
                    trace: ttftTrace
                )
                guard isRunActive(runId) else { return }

                // Inject one-off skill if the user selected one via slash command
                var sys = context.prompt
                if let skillId = pendingOneOffSkillId {
                    pendingOneOffSkillId = nil
                    if let skill = SkillManager.shared.skill(for: skillId) {
                        let section = await SkillManager.shared.buildFullInstructions(for: skill)
                        sys += "\n\n## Active Skill: \(skill.name)\n\n\(section)"
                    }
                }

                var toolSpecs = context.tools
                let isManualTools = AgentManager.shared.effectiveToolSelectionMode(for: effectiveAgentId) == .manual
                cachedContext = context

                if !context.preflightItems.isEmpty {
                    assistantTurn.preflightCapabilities = context.preflightItems
                }

                budgetTracker.snapshot(context: context)

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
                        let imageData = selectedModelSupportsImages ? t.attachments.images : []
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

                ttftTrace?.mark("pre_ttft_done")

                outer: while attempts < maxAttempts {
                    attempts += 1
                    ttftTrace?.mark("build_messages_start")
                    var msgs = buildMessages()
                    ttftTrace?.mark("build_messages_done")
                    ttftTrace?.set("messageCount", msgs.count)
                    ttftTrace?.set("conversationTurns", turns.count)

                    #if DEBUG
                        // Dump full prompt to debug log for TTFT analysis
                        if attempts == 1 {
                            var promptDump = "═══ FULL PROMPT DUMP ═══\n"
                            for (i, m) in msgs.enumerated() {
                                promptDump += "── [\(i)] role=\(m.role) chars=\(m.content?.count ?? 0) ──\n"
                                promptDump += (m.content ?? "(nil)") + "\n"
                            }
                            if let tools = toolSpecs.isEmpty ? nil : toolSpecs {
                                promptDump += "── TOOLS (\(tools.count)) ──\n"
                                for t in tools {
                                    promptDump += "  - \(t.function.name): \(t.function.description)\n"
                                }
                            }
                            promptDump += "═══ END PROMPT DUMP ═══"
                            debugLog(promptDump)
                        }
                    #endif
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
                    req.cache_hint = context.cacheHint
                    req.staticPrefix = context.staticPrefix
                    req.modelOptions = activeModelOptions.isEmpty ? nil : activeModelOptions
                    req.ttftTrace = ttftTrace
                    debugLog(
                        "send: attempt=\(attempts) model=\(req.model) tools=\(req.tools?.count ?? 0) sessionId=\(req.session_id ?? "nil")"
                    )
                    do {
                        var uiDeltaCount = 0
                        var firstDeltaTime: Date?
                        // Track the wall-clock time of the last non-empty delta so
                        // the fallback tok/s calculation uses the actual last-token
                        // moment as the denominator, not the stream's close time
                        // (which is after cancellation / teardown).
                        var lastDeltaTime: Date?

                        var processor = StreamingDeltaProcessor(
                            turn: assistantTurn,
                            modelId: selectedModel ?? "default",
                            modelOptions: activeModelOptions
                        ) { [weak self] in
                            // rebuildVisibleBlocks mutates @Published properties which already
                            // emit objectWillChange — the extra send() below is redundant.
                            self?.rebuildVisibleBlocks()
                        }

                        ttftTrace?.mark("engine_streamChat_start")
                        let stream = try await engine.streamChat(request: req)
                        ttftTrace?.mark("engine_streamChat_returned")
                        // Start TTFT timer after model is loaded and stream is ready.
                        // This excludes model loading time from the displayed TTFT.
                        let streamStartTime = Date()
                        debugLog("send: got stream, entering delta loop")
                        for try await delta in stream {
                            if !isRunActive(runId) {
                                processor.finalize()
                                break outer
                            }
                            // Server-side tool call complete: add the call card + result turn to the chat log
                            if let done = StreamingToolHint.decodeDone(delta) {
                                processor.finalize()
                                let call = ToolCall(
                                    id: done.callId,
                                    type: "function",
                                    function: ToolCallFunction(name: done.name, arguments: done.arguments)
                                )
                                assistantTurn.pendingToolName = nil
                                assistantTurn.clearPendingToolArgs()
                                if assistantTurn.toolCalls == nil { assistantTurn.toolCalls = [] }
                                assistantTurn.toolCalls!.append(call)
                                assistantTurn.toolResults[done.callId] = done.result
                                let toolTurn = ChatTurn(role: .tool, content: done.result)
                                toolTurn.toolCallId = done.callId
                                let newAssistantTurn = ChatTurn(role: .assistant, content: "")
                                turns.append(contentsOf: [toolTurn, newAssistantTurn])
                                assistantTurn = newAssistantTurn
                                processor = StreamingDeltaProcessor(
                                    turn: newAssistantTurn,
                                    modelId: selectedModel ?? "default",
                                    modelOptions: activeModelOptions
                                ) { [weak self] in self?.rebuildVisibleBlocks() }
                                rebuildVisibleBlocks()
                                continue
                            }
                            if let toolName = StreamingToolHint.decode(delta) {
                                assistantTurn.pendingToolName = toolName.isEmpty ? nil : toolName
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
                            if let stats = StreamingStatsHint.decode(delta) {
                                assistantTurn.generationTokenCount = stats.tokenCount
                                assistantTurn.generationTokensPerSecond = stats.tokensPerSecond
                                continue
                            }
                            if !delta.isEmpty {
                                let now = Date()
                                if firstDeltaTime == nil {
                                    firstDeltaTime = now
                                    ttftTrace?.mark("first_text_delta")
                                    ttftTrace?.set("model", selectedModel ?? "unknown")
                                    ttftTrace?.emit()
                                }
                                lastDeltaTime = now
                                uiDeltaCount += 1
                                processor.receiveDelta(delta)
                            }
                        }

                        // Flush any remaining buffered content (including partial tags)
                        processor.finalize()

                        if let first = firstDeltaTime {
                            assistantTurn.timeToFirstToken = first.timeIntervalSince(streamStartTime)
                            // Fall back to estimated tok/s when MLX stats weren't propagated (remote APIs).
                            // Use the codebase's chars/4 heuristic to approximate tokens from generated text
                            // rather than raw delta count, which doesn't map 1:1 to tokens for most providers.
                            if assistantTurn.generationTokensPerSecond == nil,
                                !assistantTurn.contentIsEmpty || !assistantTurn.thinkingIsEmpty
                            {
                                let endTime = lastDeltaTime ?? Date()
                                let genTime = endTime.timeIntervalSince(first)
                                // Reasoning tokens are generated on the same clock as the
                                // answer; leaving them out of the numerator while keeping
                                // them in the denominator under-reports throughput on
                                // thinking models. Count both.
                                let answerTokens = ContextBudgetManager.estimateTokens(for: assistantTurn.content)
                                let reasoningTokens =
                                    assistantTurn.thinkingIsEmpty
                                    ? 0
                                    : ContextBudgetManager.estimateTokens(for: assistantTurn.thinking)
                                let estimatedTokens = answerTokens + reasoningTokens
                                if genTime > 0 && estimatedTokens > 0 {
                                    assistantTurn.generationTokenCount = estimatedTokens
                                    assistantTurn.generationTokensPerSecond = Double(estimatedTokens) / genTime
                                }
                            }
                        }

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
                                    await PluginManager.shared.notifyArtifactHandlers(artifact: artifact)
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

    /// Picker items filtered to the active Bonjour provider's models when a remote agent is selected,
    /// or local/foundation models only when no remote agent is active.
    private var filteredPickerItems: [ModelPickerItem] {
        if let providerId = windowState.selectedDiscoveredAgentProviderId {
            return session.pickerItems.filter {
                if case .remote(_, let id) = $0.source { return id == providerId }
                return false
            }
        }
        // No remote agent selected: hide all remote models so the picker stays local.
        return session.pickerItems.filter {
            if case .remote = $0.source { return false }
            return true
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
            let effectiveContentWidth = min(chatWidth, 1100)

            HStack(alignment: .top, spacing: 0) {
                // Sidebar
                VStack(alignment: .leading, spacing: 0) {
                    if windowState.showSidebar {
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
                }
                .frame(width: sidebarWidth, alignment: .top)
                .frame(maxHeight: .infinity, alignment: .top)
                .clipped()
                .zIndex(1)

                // Main chat area
                ZStack {
                    // Background
                    chatBackground

                    // Main content — centered with a max readable width
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
                                    onSelectDiscoveredAgent: { agent in selectDiscoveredAgent(agent) },
                                    activeDiscoveredAgent: windowState.selectedDiscoveredAgent,
                                    pairedRelayAgents: windowState.pairedRelayAgents,
                                    onSelectRelayAgent: { relay in connectToRelayAgent(relay) },
                                    activeRelayAgent: windowState.selectedRelayAgent
                                )
                                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                            } else {
                                // Message thread
                                messageThread(effectiveContentWidth)
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
                                isCompact: windowState.showSidebar,
                                onClearChat: { observedSession.reset() },
                                onSkillSelected: { skillId in
                                    observedSession.pendingOneOffSkillId = skillId
                                },
                                pendingSkillId: $observedSession.pendingOneOffSkillId
                            )
                            .frame(maxWidth: 1100)
                            .frame(maxWidth: .infinity)
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
                                onSelectDiscoveredAgent: { agent in selectDiscoveredAgent(agent) },
                                pairedRelayAgents: windowState.pairedRelayAgents,
                                onSelectRelayAgent: { relay in connectToRelayAgent(relay) }
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
            if agent.address != nil {
                PairingSheet(agent: agent) { apiKey, isPermanent in
                    connectToDiscoveredAgent(agent, token: apiKey, isEphemeral: !isPermanent)
                    pendingDiscoveredAgent = nil
                } onCancel: {
                    pendingDiscoveredAgent = nil
                }
                .environment(\.theme, windowState.theme)
            } else {
                BonjourTokenSheet(agentName: agent.name) { token in
                    connectToDiscoveredAgent(agent, token: token)
                    pendingDiscoveredAgent = nil
                } onCancel: {
                    pendingDiscoveredAgent = nil
                }
                .environment(\.theme, windowState.theme)
            }
        }
    }

    /// Called when the user picks a discovered agent from the menu.
    /// If a persistent (non-ephemeral) paired provider already exists for this agent,
    /// connect directly without showing the pairing sheet.
    private func selectDiscoveredAgent(_ agent: DiscoveredAgent) {
        let manager = RemoteProviderManager.shared
        let hasPersistentProvider = manager.configuration.providers.contains(where: {
            $0.providerType == .osaurus
                && $0.remoteAgentId == agent.id
                && !manager.isEphemeral(id: $0.id)
        })
        if hasPersistentProvider {
            connectToDiscoveredAgent(agent, token: "", isEphemeral: false)
        } else {
            pendingDiscoveredAgent = agent
        }
    }

    private func connectToDiscoveredAgent(_ agent: DiscoveredAgent, token: String, isEphemeral: Bool = true) {
        // Strip trailing dot from mDNS hostnames (e.g. "device.local." -> "device.local")
        let rawHost = agent.host ?? "localhost"
        let host = rawHost.hasSuffix(".") ? String(rawHost.dropLast()) : rawHost
        let manager = RemoteProviderManager.shared

        let providerId: UUID
        // Reuse an existing Osaurus provider that already targets the same agent
        if let existing = manager.configuration.providers.first(where: {
            $0.providerType == .osaurus && $0.remoteAgentId == agent.id
        }) {
            providerId = existing.id
            var updated = existing
            updated.host = host
            updated.providerProtocol = .http
            updated.port = agent.port
            updated.enabled = true
            if let address = agent.address { updated.remoteAgentAddress = address }
            if !token.isEmpty {
                updated.authType = .apiKey
                manager.updateProvider(updated, apiKey: token)
            } else {
                manager.updateProvider(updated, apiKey: nil)
            }
            Task { try? await manager.connect(providerId: existing.id) }
        } else {
            // Use basePath="" so URLs are constructed directly as /agents/{id}/run
            let provider = RemoteProvider(
                name: agent.name,
                host: host,
                providerProtocol: .http,
                port: agent.port,
                basePath: "",
                authType: token.isEmpty ? .none : .apiKey,
                providerType: .osaurus,
                enabled: true,
                autoConnect: true,
                remoteAgentId: agent.id,
                remoteAgentAddress: agent.address
            )
            providerId = provider.id
            manager.addProvider(provider, apiKey: token.isEmpty ? nil : token, isEphemeral: isEphemeral)
        }

        windowState.selectedRelayAgent = nil
        windowState.selectedDiscoveredAgent = agent
        windowState.selectedDiscoveredAgentProviderId = providerId
        windowState.refreshPairedRelayAgents()
        session.reset()
        Task { await session.refreshPickerItems() }
    }

    private func connectToRelayAgent(_ relay: PairedRelayAgent) {
        let relayHost = "\(relay.remoteAgentAddress).agent.osaurus.ai"
        let manager = RemoteProviderManager.shared

        guard let existing = manager.configuration.providers.first(where: { $0.id == relay.providerId }) else {
            return
        }

        var updated = existing
        updated.host = relayHost
        updated.providerProtocol = .https
        updated.port = nil
        updated.enabled = true
        manager.updateProvider(updated, apiKey: nil)
        Task { try? await manager.connect(providerId: relay.providerId) }

        windowState.selectedDiscoveredAgent = nil
        windowState.selectedRelayAgent = relay
        windowState.selectedDiscoveredAgentProviderId = relay.providerId
        session.reset()
        Task { await session.refreshPickerItems() }
    }

    // MARK: - Background

    private var chatBackground: some View {
        ThemedBackgroundLayer(
            cachedBackgroundImage: windowState.cachedBackgroundImage,
            showSidebar: windowState.showSidebar
        )
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

                // Stage 0: Slash command popup is open — let the text view delegate handle it
                if SlashCommandRegistry.shared.isPopupVisible {
                    return event
                }

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
                Text("Connect to \(agentName)", bundle: .module)
                    .font(theme.font(size: 16, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Text("Enter the server token for this agent, or leave blank if none is required.", bundle: .module)
                    .font(theme.font(size: 13))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SecureField("Server token (optional)", text: $token)
                .textFieldStyle(.roundedBorder)
                .font(theme.font(size: 13))

            HStack {
                Button {
                    onCancel()
                } label: {
                    Text("Cancel", bundle: .module)
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    onConnect(token)
                } label: {
                    Text("Connect", bundle: .module)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}

// MARK: - Pairing Sheet

/// Sheet shown when the user selects a Bonjour-discovered agent that has a crypto address.
/// Performs cryptographic pairing instead of prompting for a manual server token.
private struct PairingSheet: View {
    let agent: DiscoveredAgent
    let onSuccess: (String, Bool) -> Void  // (apiKey, isPermanent)
    let onCancel: () -> Void

    @State private var isPairing = false
    @State private var errorMessage: String? = nil
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Pair with \(agent.name)", bundle: .module)
                    .font(theme.font(size: 16, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Text(
                    "This will cryptographically verify both devices. The remote device will show an approval prompt.",
                    bundle: .module
                )
                .font(theme.font(size: 13))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let error = errorMessage {
                Text(error)
                    .font(theme.font(size: 12))
                    .foregroundColor(theme.errorColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button { onCancel() } label: { Text("Cancel", bundle: .module) }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isPairing)
                Spacer()
                if isPairing {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.trailing, 4)
                } else {
                    Button {
                        Task { await performPairing() }
                    } label: {
                        Text("Pair", bundle: .module)
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    private func performPairing() async {
        isPairing = true
        errorMessage = nil
        defer { isPairing = false }

        do {
            let (apiKey, isPermanent) = try await PairingClient.pair(with: agent)
            onSuccess(apiKey, isPermanent)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Pairing Client

private enum PairingClient {
    struct PairRequestBody: Codable {
        let connectorAddress: String
        let agentId: String
        let nonce: String
        let signature: String
    }

    struct PairResponseBody: Codable {
        let agentAddress: String
        let apiKey: String
        let isPermanent: Bool
    }

    enum PairingError: LocalizedError {
        case missingHost
        case signFailed
        case networkError(Int)
        case decodingFailed
        case denied

        var errorDescription: String? {
            switch self {
            case .missingHost: return "Could not resolve the agent's network address."
            case .signFailed: return "Failed to sign the pairing request."
            case .networkError(let code): return "Pairing request failed (HTTP \(code))."
            case .decodingFailed: return "Unexpected response from the remote device."
            case .denied: return "Pairing was denied by the remote device."
            }
        }
    }

    static func pair(with agent: DiscoveredAgent) async throws -> (apiKey: String, isPermanent: Bool) {
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 300

        var masterKey = try MasterKey.getPrivateKey(context: context)
        defer {
            masterKey.withUnsafeMutableBytes { ptr in
                if let base = ptr.baseAddress { memset(base, 0, ptr.count) }
            }
        }

        let connectorAddress = try PairingKey.deriveAddress(masterKey: masterKey)
        let nonce = UUID().uuidString

        let signature = try PairingKey.sign(payload: Data(nonce.utf8), masterKey: masterKey)
        let hexSig = "0x" + signature.hexEncodedString

        let rawHost = agent.host ?? ""
        guard !rawHost.isEmpty else { throw PairingError.missingHost }
        let host = rawHost.hasSuffix(".") ? String(rawHost.dropLast()) : rawHost

        let urlString = "http://\(host):\(agent.port)/pair"
        guard let url = URL(string: urlString) else { throw PairingError.missingHost }

        let body = PairRequestBody(
            connectorAddress: connectorAddress,
            agentId: agent.id.uuidString,
            nonce: nonce,
            signature: hexSig
        )
        let bodyData = try JSONEncoder().encode(body)

        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        let (responseData, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        if statusCode == 403 { throw PairingError.denied }
        guard statusCode == 200 else { throw PairingError.networkError(statusCode) }

        guard let decoded = try? JSONDecoder().decode(PairResponseBody.self, from: responseData) else {
            throw PairingError.decodingFailed
        }

        return (apiKey: decoded.apiKey, isPermanent: decoded.isPermanent)
    }
}

// MARK: - Shared Header Components
// HeaderActionButton, SettingsButton, CloseButton, PinButton are now in SharedHeaderComponents.swift
