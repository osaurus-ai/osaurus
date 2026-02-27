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
    /// Tracks expand/collapse state for tool calls, thinking blocks, etc.
    /// Lives on the session so state survives NSTableView cell reuse.
    let expandedBlocksStore = ExpandedBlocksStore()
    @Published var input: String = ""
    @Published var pendingAttachments: [Attachment] = []
    @Published var selectedModel: String? = nil
    @Published var modelOptions: [ModelOption] = []
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

    // MARK: - Two-Phase Capability Selection (internal state, not @Published)
    var capabilitiesSelected: Bool = false
    var selectedToolNames: [String] = []
    var selectedSkillNames: [String] = []
    var selectedSkillInstructions: String = ""

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
    private var _lastTokenComputeTime: Date = .distantPast
    private var _memoryContextTokens: Int = 0

    /// Callback when session needs to be saved (called after streaming completes)
    var onSessionChanged: (() -> Void)?

    private var currentTask: Task<Void, Never>?
    // nonisolated(unsafe) allows deinit to access these for cleanup
    nonisolated(unsafe) private var remoteModelsObserver: NSObjectProtocol?
    nonisolated(unsafe) private var modelSelectionCancellable: AnyCancellable?
    /// Flag to prevent auto-persist during initial load or programmatic resets
    private var isLoadingModel: Bool = false

    nonisolated(unsafe) private var localModelsObserver: NSObjectProtocol?

    init() {
        let cache = ModelOptionsCache.shared
        if cache.isLoaded {
            modelOptions = cache.modelOptions
            hasAnyModel = !cache.modelOptions.isEmpty
            isDiscoveringModels = false
        } else {
            modelOptions = []
            hasAnyModel = false
        }

        remoteModelsObserver = NotificationCenter.default.addObserver(
            forName: .remoteProviderModelsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refreshModelOptions() }
        }

        localModelsObserver = NotificationCenter.default.addObserver(
            forName: .localModelsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refreshModelOptions() }
        }

        // Auto-persist model selection changes
        modelSelectionCancellable =
            $selectedModel
            .dropFirst()  // Skip initial value
            .removeDuplicates()
            .sink { [weak self] newModel in
                guard let self = self, !self.isLoadingModel, let model = newModel else { return }
                let pid = self.agentId ?? Agent.defaultId
                AgentManager.shared.updateDefaultModel(for: pid, model: model)
                self.activeModelOptions = ModelProfileRegistry.defaults(for: model)
            }

        if !cache.isLoaded {
            Task { [weak self] in
                await self?.refreshModelOptions()
            }
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

    /// Apply initial model selection after agentId is set (for cached model options)
    func applyInitialModelSelection() {
        guard selectedModel == nil, !modelOptions.isEmpty else { return }
        isLoadingModel = true
        let effectiveModel = AgentManager.shared.effectiveModel(for: agentId ?? Agent.defaultId)
        if let model = effectiveModel, modelOptions.contains(where: { $0.id == model }) {
            selectedModel = model
        } else {
            selectedModel = modelOptions.first?.id
        }
        isLoadingModel = false
        Task { [weak self] in await self?.refreshMemoryTokens() }
    }

    func refreshModelOptions() async {
        let newOptions = await ModelOptionsCache.shared.buildModelOptions()
        let newOptionIds = newOptions.map { $0.id }
        let optionsChanged = modelOptions.map({ $0.id }) != newOptionIds

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

        modelOptions = newOptions
        isLoadingModel = true
        selectedModel = newSelected
        isLoadingModel = false
        hasAnyModel = !newOptions.isEmpty
    }

    /// Check if the currently selected model supports images (VLM)
    var selectedModelSupportsImages: Bool {
        guard let model = selectedModel else { return false }
        if model.lowercased() == "foundation" { return false }
        guard let option = modelOptions.first(where: { $0.id == model }) else { return false }
        if case .remote = option.source { return true }
        return option.isVLM
    }

    /// Get the currently selected ModelOption
    var selectedModelOption: ModelOption? {
        guard let model = selectedModel else { return nil }
        return modelOptions.first { $0.id == model }
    }

    /// Flattened content blocks for efficient LazyVStack rendering
    /// Each block is a paragraph, header, tool call, etc. that can be independently recycled
    ///
    /// PERFORMANCE: Uses BlockMemoizer for incremental updates during streaming.
    /// Only regenerates blocks for the last turn instead of all blocks (O(1) vs O(n)).
    var visibleBlocks: [ContentBlock] {
        // Get agent name for assistant messages
        let agent = AgentManager.shared.agent(for: agentId ?? Agent.defaultId)
        let displayName = agent?.isBuiltIn == true ? "Assistant" : (agent?.name ?? "Assistant")

        // Determine streaming turn ID
        let streamingTurnId = isStreaming ? turns.last?.id : nil

        return blockMemoizer.blocks(
            from: turns,
            streamingTurnId: streamingTurnId,
            agentName: displayName
        )
    }

    /// Precomputed group header map from BlockMemoizer.
    var visibleBlocksGroupHeaderMap: [UUID: UUID] {
        blockMemoizer.groupHeaderMap
    }

    /// Estimated token count for current session context (~4 chars per token).
    /// Throttled to at most once per 500ms during streaming.
    var estimatedContextTokens: Int {
        estimatedContextBreakdown.total
    }

    /// Per-category breakdown of estimated context tokens.
    /// Uses the same caching / throttling as the scalar total.
    var estimatedContextBreakdown: ContextTokenBreakdown {
        if _tokenCacheValid && !isStreaming && turns.count == _lastTokenTurnsCount
            && pendingAttachments.count == _lastTokenAttachmentsCount
        {
            return _cachedBreakdown
        }

        if isStreaming && _tokenCacheValid && Date().timeIntervalSince(_lastTokenComputeTime) < 0.5 {
            return _cachedBreakdown
        }

        var breakdown = ContextTokenBreakdown()
        let effectiveId = agentId ?? Agent.defaultId

        // System prompt
        let systemPrompt = AgentManager.shared.effectiveSystemPrompt(for: effectiveId)
        if !systemPrompt.isEmpty {
            breakdown.systemPrompt = max(1, systemPrompt.count / 4)
        }

        // Memory context (profile, working memory, summaries, graph)
        breakdown.memory = _memoryContextTokens

        // Tool and skill tokens depend on two-phase loading state
        let toolOverrides = AgentManager.shared.effectiveToolOverrides(for: effectiveId)
        let allTools = ToolRegistry.shared.listTools(withOverrides: toolOverrides)

        let catalog = CapabilityCatalogBuilder.build(for: effectiveId)
        let hasCapabilities = !catalog.isEmpty
        let phasedLoading = ChatConfigurationStore.load().phasedContextLoading

        func isEnabled(_ tool: ToolRegistry.ToolEntry) -> Bool {
            if let override = toolOverrides?[tool.name] { return override }
            return tool.enabled
        }

        if phasedLoading && !capabilitiesSelected {
            breakdown.tools = allTools.filter(isEnabled).reduce(0) { $0 + $1.catalogEntryTokens }
            if hasCapabilities {
                breakdown.tools += ToolRegistry.shared.estimatedTokens(for: "select_capabilities")
            }
            breakdown.skills = CapabilityService.shared.estimateCatalogSkillTokens(for: effectiveId)
        } else if phasedLoading && capabilitiesSelected {
            breakdown.tools = selectedToolNames.reduce(0) { $0 + ToolRegistry.shared.estimatedTokens(for: $1) }
            if hasCapabilities {
                breakdown.tools += ToolRegistry.shared.estimatedTokens(for: "select_capabilities")
            }
            if !selectedSkillInstructions.isEmpty {
                breakdown.skills = max(1, selectedSkillInstructions.count / 4)
            }
        } else {
            breakdown.tools = allTools.filter(isEnabled).reduce(0) { $0 + $1.estimatedTokens }
            breakdown.skills = CapabilityService.shared.estimateSkillTokens()
        }

        // All turns
        var conversationTokens = 0
        for turn in turns {
            if !turn.contentIsEmpty {
                conversationTokens += max(1, turn.contentLength / 4)
            }
            if let toolCalls = turn.toolCalls {
                for call in toolCalls {
                    conversationTokens += max(1, (call.function.name.count + call.function.arguments.count) / 4)
                }
            }
            for (_, result) in turn.toolResults {
                conversationTokens += max(1, result.count / 4)
            }
            if turn.hasThinking {
                conversationTokens += max(1, turn.thinkingLength / 4)
            }
            for attachment in turn.attachments {
                conversationTokens += attachment.estimatedTokens
            }
        }
        breakdown.conversation = conversationTokens

        // Current input + pending attachments
        var inputTokens = 0
        if !input.isEmpty {
            inputTokens += max(1, input.count / 4)
        }
        for attachment in pendingAttachments {
            inputTokens += attachment.estimatedTokens
        }
        breakdown.input = inputTokens

        // Update cache
        _cachedBreakdown = breakdown
        _tokenCacheValid = true
        _lastTokenTurnsCount = turns.count
        _lastTokenAttachmentsCount = pendingAttachments.count
        _lastTokenComputeTime = Date()

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
        currentTask?.cancel()
        currentTask = nil
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
        // Reset capability selection for new conversation
        resetCapabilitySelection()
        // Keep current agentId - don't reset when creating new chat within same agent

        // Clear caches
        blockMemoizer.clear()
        _tokenCacheValid = false

        // Apply model from agent or global config (don't auto-persist, it's already saved)
        isLoadingModel = true
        let effectiveModel = AgentManager.shared.effectiveModel(for: agentId ?? Agent.defaultId)
        if let defaultModel = effectiveModel,
            modelOptions.contains(where: { $0.id == defaultModel })
        {
            selectedModel = defaultModel
        } else {
            selectedModel = modelOptions.first?.id
        }
        isLoadingModel = false
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
        // Notify SwiftUI to re-render views that depend on estimatedContextTokens
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
            modelOptions.contains(where: { $0.id == savedModel })
        {
            selectedModel = savedModel
        } else {
            // Fall back to agent's model, then global config, then first available
            let effectiveModel = AgentManager.shared.effectiveModel(for: data.agentId ?? Agent.defaultId)
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
        voiceInputState = .idle
        showVoiceOverlay = false
        input = ""
        pendingAttachments = []
        isDirty = false  // Fresh load, not dirty
        // Reset capability selection for loaded conversation
        // (capabilities will be re-selected on next message if skills are enabled)
        resetCapabilitySelection()

        // Clear caches to force a clean block rebuild for the new session
        blockMemoizer.clear()
        _tokenCacheValid = false

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

    // MARK: - Two-Phase Capability Selection

    /// Handle the select_capabilities tool call and update session state
    private func handleSelectCapabilities(argumentsJSON: String) async throws -> String {
        // Parse the arguments
        guard let data = argumentsJSON.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw NSError(
                domain: "ChatSession",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Invalid arguments for select_capabilities"
                ]
            )
        }

        let requestedTools = (json["tools"] as? [String]) ?? []
        let requestedSkills = (json["skills"] as? [String]) ?? []

        // Load selected capabilities
        var loadedTools: [String] = []
        var loadedSkillInstructions: [String] = []
        var errors: [String] = []

        // Get agent-level overrides for validation
        let effectiveAgentId = agentId ?? Agent.defaultId
        let toolOverrides = AgentManager.shared.effectiveToolOverrides(for: effectiveAgentId)

        // Validate and collect tools (respecting agent overrides)
        let enabledToolNames = Set(
            ToolRegistry.shared.listUserTools(withOverrides: toolOverrides)
                .filter { tool in
                    if let override = toolOverrides?[tool.name] { return override }
                    return tool.enabled
                }
                .map { $0.name }
        )

        for toolName in requestedTools {
            if enabledToolNames.contains(toolName) {
                loadedTools.append(toolName)
            } else {
                errors.append("Tool '\(toolName)' not found or not enabled")
            }
        }

        // Validate and collect skills (respecting agent overrides)
        // Filter requested skills to only those enabled for this agent
        let enabledRequestedSkills = requestedSkills.filter { skillName in
            CapabilityService.shared.isSkillEnabled(skillName, for: effectiveAgentId)
        }

        // Load instructions for enabled skills (includes reference file contents)
        let skillInstructionsMap = SkillManager.shared.loadInstructions(for: enabledRequestedSkills)
        for skillName in requestedSkills {
            if enabledRequestedSkills.contains(skillName), let instructions = skillInstructionsMap[skillName] {
                loadedSkillInstructions.append("## \(skillName)\n\n\(instructions)")
            } else {
                errors.append("Skill '\(skillName)' not found or not enabled")
            }
        }

        // Update session state - replace previous selection for context efficiency
        capabilitiesSelected = true
        selectedToolNames = loadedTools
        selectedSkillNames = enabledRequestedSkills
        selectedSkillInstructions =
            loadedSkillInstructions.isEmpty
            ? ""
            : loadedSkillInstructions.joined(separator: "\n\n---\n\n")

        // Build response (keep it minimal)
        var response: [String] = []
        response.append("# Capabilities Loaded")

        if !loadedTools.isEmpty {
            response.append("Tools: \(loadedTools.joined(separator: ", "))")
        }

        if !enabledRequestedSkills.isEmpty {
            response.append("Skills: \(enabledRequestedSkills.joined(separator: ", "))")
        }

        if !errors.isEmpty {
            response.append("")
            for error in errors {
                response.append("Warning: \(error)")
            }
        }

        if loadedTools.isEmpty && enabledRequestedSkills.isEmpty {
            response.append("No capabilities loaded.")
        }

        return response.joined(separator: "\n")
    }

    /// Reset capability selection state (for new conversations)
    func resetCapabilitySelection() {
        capabilitiesSelected = false
        selectedToolNames = []
        selectedSkillNames = []
        selectedSkillInstructions = ""
    }

    /// Build system prompt based on capability selection state
    private func buildSystemPrompt(base: String, agentId: UUID, needsSelection: Bool) -> String {
        if needsSelection {
            // Phase 1: Include full capability catalog for selection
            return CapabilityService.shared.buildSystemPromptWithCatalog(
                basePrompt: base,
                agentId: agentId
            )
        } else if capabilitiesSelected {
            // Phase 2: Include selected skill instructions + available capabilities reminder
            var prompt = base

            // Add active skill instructions
            if !selectedSkillInstructions.isEmpty {
                if !prompt.isEmpty { prompt += "\n\n" }
                prompt += "# Active Skills\n\n"
                prompt += selectedSkillInstructions
            }

            // Add compact reminder of other available capabilities
            let catalog = CapabilityCatalogBuilder.build(for: agentId)
            let unselectedTools = catalog.tools.map { $0.name }.filter { !selectedToolNames.contains($0) }
            let unselectedSkills = catalog.skills.map { $0.name }.filter { !selectedSkillNames.contains($0) }

            if !unselectedTools.isEmpty || !unselectedSkills.isEmpty {
                if !prompt.isEmpty { prompt += "\n\n" }
                prompt += "# Additional Capabilities Available\n"
                prompt += "Call `select_capabilities` to add more:\n"
                if !unselectedTools.isEmpty {
                    prompt += "- tools: \(unselectedTools.joined(separator: ", "))\n"
                }
                if !unselectedSkills.isEmpty {
                    prompt += "- skills: \(unselectedSkills.joined(separator: ", "))"
                }
            }

            return prompt
        } else {
            // No capability selection needed, use base prompt
            return base
        }
    }

    /// Build tool specifications based on capability selection state
    private func buildToolSpecs(needsSelection: Bool, hasCapabilities: Bool, overrides: [String: Bool]?) -> [Tool] {
        if needsSelection {
            // Phase 1: Only select_capabilities available
            return ToolRegistry.shared.selectCapabilitiesSpec()
        } else if capabilitiesSelected && !selectedToolNames.isEmpty {
            // Phase 2: Selected tools + select_capabilities for adding more
            var toolNames = selectedToolNames
            if hasCapabilities && !toolNames.contains("select_capabilities") {
                toolNames.append("select_capabilities")
            }
            return ToolRegistry.shared.specs(forTools: toolNames)
        } else {
            // Default: All enabled tools + select_capabilities (if capabilities exist)
            var specs = ToolRegistry.shared.userSpecs(withOverrides: overrides)
            if hasCapabilities && !specs.contains(where: { $0.function.name == "select_capabilities" }) {
                specs.append(contentsOf: ToolRegistry.shared.selectCapabilitiesSpec())
            }
            return specs
        }
    }

    func send(_ text: String, attachments: [Attachment] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasContent = !trimmed.isEmpty || !attachments.isEmpty
        let isRegeneration = !hasContent && !turns.isEmpty
        guard hasContent || isRegeneration else { return }

        if hasContent {
            turns.append(ChatTurn(role: .user, content: trimmed, attachments: attachments))
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
                ChatSessionsManager.shared.save(data)
                onSessionChanged?()
            }
        }

        let memoryAgentId = (agentId ?? Agent.defaultId).uuidString
        let memoryConversationId = (sessionId ?? UUID()).uuidString
        if hasContent {
            ActivityTracker.shared.recordActivity(agentId: memoryAgentId)
        }

        currentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            isStreaming = true
            ServerController.signalGenerationStart()
            defer {
                isStreaming = false
                ServerController.signalGenerationEnd()
                // Remove trailing empty assistant turn if present
                if let lastTurn = turns.last,
                    lastTurn.role == .assistant,
                    lastTurn.contentIsEmpty,
                    lastTurn.toolCalls == nil,
                    !lastTurn.hasThinking
                {
                    turns.removeLast()
                }
                // Consolidate chunks and save
                for turn in turns where turn.role == .assistant {
                    turn.consolidateContent()
                }
                save()

                // Memory: persist conversation chunk and trigger signal processing
                let assistantContent = turns.last(where: { $0.role == .assistant })?.content
                let userContent = trimmed

                if hasContent, let sid = sessionId {
                    let convId = sid.uuidString
                    let aid = memoryAgentId
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
                            content: userContent,
                            tokenCount: max(1, userContent.count / 4)
                        )
                    } catch {
                        MemoryLogger.database.warning("Failed to insert user chunk: \(error)")
                    }
                    let userChunk = ConversationChunk(
                        conversationId: convId,
                        chunkIndex: userChunkIndex,
                        role: "user",
                        content: userContent,
                        tokenCount: max(1, userContent.count / 4)
                    )
                    Task.detached { await MemorySearchService.shared.indexConversationChunk(userChunk) }
                    if let ac = assistantContent, !ac.isEmpty {
                        do {
                            try db.insertChunk(
                                conversationId: convId,
                                chunkIndex: chunkIdx,
                                role: "assistant",
                                content: ac,
                                tokenCount: max(1, ac.count / 4)
                            )
                        } catch {
                            MemoryLogger.database.warning("Failed to insert assistant chunk: \(error)")
                        }
                        let assistantChunk = ConversationChunk(
                            conversationId: convId,
                            chunkIndex: chunkIdx,
                            role: "assistant",
                            content: ac,
                            tokenCount: max(1, ac.count / 4)
                        )
                        Task.detached { await MemorySearchService.shared.indexConversationChunk(assistantChunk) }
                    }
                }

                if hasContent {
                    let userMsg = userContent
                    let asstMsg = assistantContent
                    let agentStr = memoryAgentId
                    let convStr = memoryConversationId
                    let today = ISO8601DateFormatter.string(
                        from: Date(),
                        timeZone: .current,
                        formatOptions: [.withFullDate, .withDashSeparatorInDate]
                    )
                    Task.detached {
                        await MemoryService.shared.recordConversationTurn(
                            userMessage: userMsg,
                            assistantMessage: asstMsg,
                            agentId: agentStr,
                            conversationId: convStr,
                            sessionDate: today
                        )
                    }
                }

                ActivityTracker.shared.recordActivity(agentId: memoryAgentId)
            }

            var assistantTurn = ChatTurn(role: .assistant, content: "")
            turns.append(assistantTurn)
            do {
                let engine = ChatEngine(source: .chatUI)
                let chatCfg = ChatConfigurationStore.load()

                // MARK: - Two-Phase Capability Selection
                let effectiveAgentId = agentId ?? Agent.defaultId
                let effectiveToolOverrides = AgentManager.shared.effectiveToolOverrides(for: effectiveAgentId)

                // Check if there are any capabilities to select
                let catalog = CapabilityCatalogBuilder.build(for: effectiveAgentId)
                let hasCapabilities = !catalog.isEmpty
                let phasedLoading = chatCfg.phasedContextLoading
                let needsCapabilitySelection = phasedLoading && !capabilitiesSelected && hasCapabilities

                let baseSystemPrompt = AgentManager.shared.effectiveSystemPrompt(for: effectiveAgentId)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                // Inject memory context before the system prompt (async to avoid main thread blocking)
                let memoryConfig = MemoryConfigurationStore.load()
                let memoryContext = await MemoryContextAssembler.assembleContext(
                    agentId: effectiveAgentId.uuidString,
                    config: memoryConfig
                )
                updateMemoryTokens(fromContext: memoryContext)

                // Build system prompt and tool specs based on capability selection state
                var sys = buildSystemPrompt(
                    base: baseSystemPrompt,
                    agentId: effectiveAgentId,
                    needsSelection: needsCapabilitySelection
                )

                if !memoryContext.isEmpty {
                    sys = memoryContext + "\n\n" + sys
                }
                var toolSpecs = buildToolSpecs(
                    needsSelection: needsCapabilitySelection,
                    hasCapabilities: phasedLoading && hasCapabilities,
                    overrides: effectiveToolOverrides
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
                var attempts = 0
                let effectiveTemp = AgentManager.shared.effectiveTemperature(for: effectiveAgentId)

                outer: while attempts < maxAttempts {
                    attempts += 1
                    var req = ChatCompletionRequest(
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
                        tools: toolSpecs.isEmpty ? nil : toolSpecs,
                        tool_choice: toolSpecs.isEmpty ? nil : .auto,
                        session_id: nil
                    )
                    req.modelOptions = activeModelOptions.isEmpty ? nil : activeModelOptions
                    do {
                        let streamStartTime = Date()
                        var uiDeltaCount = 0

                        let processor = StreamingDeltaProcessor(
                            turn: assistantTurn,
                            modelId: selectedModel ?? "default"
                        ) { [weak self] in
                            self?.objectWillChange.send()
                        }

                        let stream = try await engine.streamChat(request: req)
                        for try await delta in stream {
                            if Task.isCancelled {
                                processor.finalize()
                                break outer
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

                            // Handle select_capabilities specially for two-phase loading
                            if inv.toolName == "select_capabilities" {
                                resultText = try await handleSelectCapabilities(argumentsJSON: inv.jsonArguments)
                                if Task.isCancelled { break }

                                // Rebuild system prompt and tool specs using helper methods
                                sys = buildSystemPrompt(
                                    base: baseSystemPrompt,
                                    agentId: effectiveAgentId,
                                    needsSelection: false
                                )
                                toolSpecs = buildToolSpecs(
                                    needsSelection: false,
                                    hasCapabilities: hasCapabilities,
                                    overrides: effectiveToolOverrides
                                )
                            } else {
                                // Build effective overrides: if capabilities were selected, allow those tools
                                var executionOverrides = effectiveToolOverrides ?? [:]
                                if capabilitiesSelected && selectedToolNames.contains(inv.toolName) {
                                    // Tool was explicitly selected via select_capabilities, allow it
                                    executionOverrides[inv.toolName] = true
                                }

                                resultText = try await ToolRegistry.shared.execute(
                                    name: inv.toolName,
                                    argumentsJSON: inv.jsonArguments,
                                    overrides: executionOverrides.isEmpty ? nil : executionOverrides
                                )
                                if Task.isCancelled { break }
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
                    windowState.workSession?.stopExecution()
                    ChatWindowManager.shared.closeWindow(id: windowState.windowId)
                },
                .cancel("Cancel"),
            ]
        )
        .themedAlertScope(.chat(windowState.windowId))
        .overlay(ThemedAlertHost(scope: .chat(windowState.windowId)))
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
                            if session.turns.isEmpty {
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
                                            session.selectedModel = session.modelOptions.first?.id ?? "foundation"
                                        } : nil,
                                    onQuickAction: { prompt in
                                        session.input = prompt
                                    },
                                    onSelectAgent: { newAgentId in
                                        windowState.switchAgent(to: newAgentId)
                                    },
                                    onOpenOnboarding: nil
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
                                modelOptions: observedSession.modelOptions,
                                activeModelOptions: $observedSession.activeModelOptions,
                                isStreaming: observedSession.isStreaming,
                                supportsImages: observedSession.selectedModelSupportsImages,
                                estimatedContextTokens: observedSession.estimatedContextTokens,
                                contextBreakdown: observedSession.estimatedContextBreakdown,
                                onSend: { observedSession.sendCurrent() },
                                onStop: { observedSession.stop() },
                                focusTrigger: focusTrigger,
                                agentId: windowState.agentId,
                                windowId: windowState.windowId
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
                                        session.selectedModel = session.modelOptions.first?.id ?? "foundation"
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
                                            await session.refreshModelOptions()
                                        }
                                        return
                                    }
                                    // Only reset for users who never completed onboarding
                                    OnboardingService.shared.resetOnboarding()
                                    // Close this window so user can focus on onboarding
                                    ChatWindowManager.shared.closeWindow(id: windowState.windowId)
                                    // Show onboarding window
                                    AppDelegate.shared?.showOnboardingWindow()
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
        .ignoresSafeArea()
        .animation(theme.animationMedium(), value: session.turns.isEmpty)
        .animation(theme.springAnimation(responseMultiplier: 0.9), value: windowState.showSidebar)
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
        // Interactive titlebar controls are hosted in the window's `NSToolbar`.
        // Keep a spacer here so content starts below the titlebar.
        Color.clear
            .frame(height: 52)
            .allowsHitTesting(false)
    }

    /// Close this window via ChatWindowManager
    private func closeWindow() {
        ChatWindowManager.shared.closeWindow(id: windowState.windowId)
    }

    // MARK: - Message Thread

    /// Isolated message thread view to prevent cascading re-renders
    private func messageThread(_ width: CGFloat) -> some View {
        let blocks = session.visibleBlocks
        let groupHeaderMap = session.visibleBlocksGroupHeaderMap
        let displayName = windowState.cachedAgentDisplayName
        let lastAssistantTurnId = session.turns.last { $0.role == .assistant }?.id

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
                onCancelEdit: cancelEditing
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
                        hasTurns: !session.turns.isEmpty,
                        onTap: {
                            isPinnedToBottom = true
                            scrollToBottomTrigger += 1
                        }
                    )
                }
            }
        }
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
            textToCopy += turn.content
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

    // MARK: - Helpers

    private func displayModelName(_ raw: String?) -> String {
        guard let raw else { return "Model" }
        if raw.lowercased() == "foundation" { return "Foundation" }
        if let last = raw.split(separator: "/").last { return String(last) }
        return raw
    }

    private func resizeWindowForContent(isEmpty: Bool) {
        guard let window = ChatWindowManager.shared.getNSWindow(id: windowId) else { return }

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

// MARK: - Shared Header Components
// HeaderActionButton, SettingsButton, CloseButton, PinButton are now in SharedHeaderComponents.swift
