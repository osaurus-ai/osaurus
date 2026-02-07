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
    @Published var input: String = ""
    @Published var pendingImages: [Data] = []
    @Published var selectedModel: String? = nil
    @Published var modelOptions: [ModelOption] = []
    @Published var hasAnyModel: Bool = false
    @Published var isDiscoveringModels: Bool = true
    /// When true, voice input auto-restarts after AI responds (continuous conversation mode)
    @Published var isContinuousVoiceMode: Bool = false
    /// Active state of the voice input overlay
    @Published var voiceInputState: VoiceInputState = .idle
    /// Whether the voice input overlay is currently visible
    @Published var showVoiceOverlay: Bool = false
    /// The persona this session belongs to
    @Published var personaId: UUID?

    // MARK: - Two-Phase Capability Selection
    /// Whether capabilities have been selected for this conversation
    @Published var capabilitiesSelected: Bool = false
    /// Names of selected tools after select_capabilities is called
    @Published var selectedToolNames: [String] = []
    /// Names of selected skills after select_capabilities is called
    @Published var selectedSkillNames: [String] = []
    /// Combined instructions from selected skills (injected after selection)
    @Published var selectedSkillInstructions: String = ""

    // MARK: - Persistence Properties
    @Published var sessionId: UUID?
    @Published var title: String = "New Chat"
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    /// Tracks if session has unsaved content changes
    private var isDirty: Bool = false

    // MARK: - Memoization Cache
    private let blockMemoizer = BlockMemoizer()
    private var _cachedEstimatedTokens: Int = 0
    private var _tokenCacheValid: Bool = false
    private var _lastTokenTurnsCount: Int = 0

    /// Callback when session needs to be saved (called after streaming completes)
    var onSessionChanged: (() -> Void)?

    private var currentTask: Task<Void, Never>?
    // nonisolated(unsafe) allows deinit to access these for cleanup
    nonisolated(unsafe) private var remoteModelsObserver: NSObjectProtocol?
    nonisolated(unsafe) private var modelSelectionCancellable: AnyCancellable?
    /// Flag to prevent auto-persist during initial load or programmatic resets
    private var isLoadingModel: Bool = false

    nonisolated(unsafe) private var localModelsObserver: NSObjectProtocol?

    // MARK: - App-level Model Options Cache
    private static var cachedModelOptions: [ModelOption]?
    private static var cacheValid = false

    init() {
        if let cached = Self.cachedModelOptions, Self.cacheValid {
            modelOptions = cached
            hasAnyModel = !cached.isEmpty
            isDiscoveringModels = false
        } else {
            modelOptions = []
            hasAnyModel = false
        }

        // Listen for remote provider model changes
        remoteModelsObserver = NotificationCenter.default.addObserver(
            forName: .remoteProviderModelsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                Self.cacheValid = false
                await self?.refreshModelOptions()
            }
        }

        // Listen for local model changes (download completed, deleted)
        localModelsObserver = NotificationCenter.default.addObserver(
            forName: .localModelsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                Self.cacheValid = false
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

        // Only load models if cache wasn't valid (first window or after invalidation)
        if !Self.cacheValid {
            Task {
                await refreshModelOptions()
            }
        }
    }

    deinit {
        // Clean up notification observers to prevent leaks
        if let observer = remoteModelsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = localModelsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        modelSelectionCancellable = nil
    }

    /// Apply initial model selection after personaId is set (for cached model options)
    func applyInitialModelSelection() {
        guard selectedModel == nil, !modelOptions.isEmpty else { return }
        isLoadingModel = true
        let effectiveModel = PersonaManager.shared.effectiveModel(for: personaId ?? Persona.defaultId)
        if let model = effectiveModel, modelOptions.contains(where: { $0.id == model }) {
            selectedModel = model
        } else {
            selectedModel = modelOptions.first?.id
        }
        isLoadingModel = false
    }

    /// Build rich model options from all sources
    private static func buildModelOptions() async -> [ModelOption] {
        var options: [ModelOption] = []

        // Add foundation model first if available (use cached value)
        if AppConfiguration.shared.foundationModelAvailable {
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

        // Cache the result for subsequent windows
        cachedModelOptions = options
        cacheValid = true

        return options
    }

    /// Pre-warm the full model cache (local + remote) at app launch
    public static func prewarmModelCache() async {
        _ = await buildModelOptions()
    }

    /// Quick prewarm with just local models (no network wait)
    /// Call this early at launch so first window has something to show immediately
    public static func prewarmLocalModelsOnly() {
        Task {
            // Run discovery in background
            let localModels = await Task.detached(priority: .userInitiated) {
                ModelManager.discoverLocalModels()
            }.value

            await MainActor.run {
                var options: [ModelOption] = []

                // Foundation model (instant check)
                if AppConfiguration.shared.foundationModelAvailable {
                    options.append(.foundation())
                }

                for model in localModels {
                    options.append(.fromMLXModel(model))
                }

                // Cache what we have - remote models will be added by prewarmModelCache later
                cachedModelOptions = options
                cacheValid = true
            }
        }
    }

    /// Invalidate model cache to force rediscovery
    /// Call this when models change outside of normal notification flow (e.g., after onboarding)
    public static func invalidateModelCache() {
        cacheValid = false
        cachedModelOptions = nil
    }

    func refreshModelOptions() async {
        let newOptions = await Self.buildModelOptions()

        let prev = selectedModel
        let newSelected: String?

        // If we have a previous selection that's still valid, keep it
        if let prev = prev, newOptions.contains(where: { $0.id == prev }) {
            newSelected = prev
        } else {
            // Otherwise try to load from persona's model, falling back to global config
            let effectiveModel = PersonaManager.shared.effectiveModel(for: personaId ?? Persona.defaultId)

            if let defaultModel = effectiveModel,
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
        // Get persona name for assistant messages
        let persona = PersonaManager.shared.persona(for: personaId ?? Persona.defaultId)
        let displayName = persona?.isBuiltIn == true ? "Assistant" : (persona?.name ?? "Assistant")

        // Determine streaming turn ID
        let streamingTurnId = isStreaming ? turns.last?.id : nil

        return blockMemoizer.blocks(
            from: turns,
            streamingTurnId: streamingTurnId,
            personaName: displayName
        )
    }

    /// Estimated token count for current session context (rough heuristic: ~4 chars per token)
    /// Memoized - only recomputes when turns/tools change or streaming ends
    var estimatedContextTokens: Int {
        // Use cache if valid and not streaming (during streaming, estimate changes frequently)
        if _tokenCacheValid && !isStreaming && turns.count == _lastTokenTurnsCount {
            return _cachedEstimatedTokens
        }

        var total = 0
        let effectiveId = personaId ?? Persona.defaultId

        // System prompt
        let systemPrompt = PersonaManager.shared.effectiveSystemPrompt(for: effectiveId)
        if !systemPrompt.isEmpty {
            total += max(1, systemPrompt.count / 4)
        }

        // Tool and skill tokens depend on two-phase loading state
        let toolOverrides = PersonaManager.shared.effectiveToolOverrides(for: effectiveId)
        let allTools = ToolRegistry.shared.listTools(withOverrides: toolOverrides)

        // Check if there are any capabilities to select
        let catalog = CapabilityCatalogBuilder.build(for: effectiveId)
        let hasCapabilities = !catalog.isEmpty

        // Helper to check if tool is enabled
        func isEnabled(_ tool: ToolRegistry.ToolEntry) -> Bool {
            if let override = toolOverrides?[tool.name] { return override }
            return tool.enabled
        }

        if !capabilitiesSelected {
            // Phase 1: Catalog entries + select_capabilities (if catalog not empty)
            total += allTools.filter(isEnabled).reduce(0) { $0 + $1.catalogEntryTokens }
            if hasCapabilities {
                total += ToolRegistry.shared.estimatedTokens(for: "select_capabilities")
            }
            total += CapabilityService.shared.estimateCatalogSkillTokens(for: effectiveId)
        } else {
            // Phase 2: Selected tools + select_capabilities + skill instructions
            total += selectedToolNames.reduce(0) { $0 + ToolRegistry.shared.estimatedTokens(for: $1) }
            if hasCapabilities {
                total += ToolRegistry.shared.estimatedTokens(for: "select_capabilities")
            }
            if !selectedSkillInstructions.isEmpty {
                total += max(1, selectedSkillInstructions.count / 4)
            }
        }

        // All turns - use cached lengths to avoid forcing lazy string joins
        for turn in turns {
            if !turn.contentIsEmpty {
                total += max(1, turn.contentLength / 4)
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
            // Thinking content - use cached length
            if turn.hasThinking {
                total += max(1, turn.thinkingLength / 4)
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

        // Update cache
        _cachedEstimatedTokens = total
        _tokenCacheValid = true
        _lastTokenTurnsCount = turns.count

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
        // Keep current personaId - don't reset when creating new chat within same persona

        // Clear caches
        blockMemoizer.clear()
        _tokenCacheValid = false

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
    }

    /// Reset for a specific persona
    func reset(for newPersonaId: UUID?) {
        personaId = newPersonaId
        reset()
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
        voiceInputState = .idle
        showVoiceOverlay = false
        input = ""
        pendingImages = []
        isDirty = false  // Fresh load, not dirty
        // Reset capability selection for loaded conversation
        // (capabilities will be re-selected on next message if skills are enabled)
        resetCapabilitySelection()
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

        // Get persona-level overrides for validation
        let effectivePersonaId = personaId ?? Persona.defaultId
        let toolOverrides = PersonaManager.shared.effectiveToolOverrides(for: effectivePersonaId)

        // Validate and collect tools (respecting persona overrides)
        let enabledToolNames = Set(
            ToolRegistry.shared.listTools(withOverrides: toolOverrides)
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

        // Validate and collect skills (respecting persona overrides)
        // Filter requested skills to only those enabled for this persona
        let enabledRequestedSkills = requestedSkills.filter { skillName in
            CapabilityService.shared.isSkillEnabled(skillName, for: effectivePersonaId)
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
    private func buildSystemPrompt(base: String, personaId: UUID, needsSelection: Bool) -> String {
        if needsSelection {
            // Phase 1: Include full capability catalog for selection
            return CapabilityService.shared.buildSystemPromptWithCatalog(
                basePrompt: base,
                personaId: personaId
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
            let catalog = CapabilityCatalogBuilder.build(for: personaId)
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
            var specs = ToolRegistry.shared.specs(withOverrides: overrides)
            if hasCapabilities && !specs.contains(where: { $0.function.name == "select_capabilities" }) {
                specs.append(contentsOf: ToolRegistry.shared.selectCapabilitiesSpec())
            }
            return specs
        }
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
            }

            var assistantTurn = ChatTurn(role: .assistant, content: "")
            turns.append(assistantTurn)
            do {
                let engine = ChatEngine(source: .chatUI)
                let chatCfg = ChatConfigurationStore.load()

                // MARK: - Two-Phase Capability Selection
                let effectivePersonaId = personaId ?? Persona.defaultId
                let effectiveToolOverrides = PersonaManager.shared.effectiveToolOverrides(for: effectivePersonaId)

                // Check if there are any capabilities to select
                let catalog = CapabilityCatalogBuilder.build(for: effectivePersonaId)
                let hasCapabilities = !catalog.isEmpty
                let needsCapabilitySelection = !capabilitiesSelected && hasCapabilities

                let baseSystemPrompt = PersonaManager.shared.effectiveSystemPrompt(for: effectivePersonaId)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                // Build system prompt and tool specs based on capability selection state
                var sys = buildSystemPrompt(
                    base: baseSystemPrompt,
                    personaId: effectivePersonaId,
                    needsSelection: needsCapabilitySelection
                )
                var toolSpecs = buildToolSpecs(
                    needsSelection: needsCapabilitySelection,
                    hasCapabilities: hasCapabilities,
                    overrides: effectiveToolOverrides
                )

                let effectiveMaxTokensForPersona = PersonaManager.shared.effectiveMaxTokens(for: effectivePersonaId)

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
                        if t.hasImages {
                            return ChatMessage(role: "user", text: t.content, imageData: t.attachedImages)
                        } else {
                            return ChatMessage(role: t.role.rawValue, content: t.content)
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
                let effectiveTemp = PersonaManager.shared.effectiveTemperature(for: effectivePersonaId)

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

                            // Simple tuning based on content size - avoid overly complex backpressure
                            switch totalChars {
                            case 0 ..< 2_000:
                                flushIntervalMs = 50
                                maxBufferSize = 256
                            case 2_000 ..< 8_000:
                                flushIntervalMs = 75
                                maxBufferSize = 512
                            case 8_000 ..< 20_000:
                                flushIntervalMs = 100
                                maxBufferSize = 768
                            default:
                                flushIntervalMs = 150
                                maxBufferSize = 1024
                            }

                            // Light backpressure - don't skip flushes, just slow down slightly
                            if longestFlushMs > 50 {
                                flushIntervalMs = min(200, flushIntervalMs * 1.5)
                            }
                        }

                        // Thinking tag parsing state
                        var isInsideThinking = false
                        var pendingTagBuffer = ""  // Buffer for partial tag detection

                        // Track when we last synced to the turn (to batch UI updates)
                        var lastSyncTime = Date()
                        // Track if we have pending content to sync
                        var hasPendingContent = false
                        // Debug: track sync count
                        var syncCount = 0

                        @MainActor
                        func appendContent(_ s: String) {
                            guard !s.isEmpty else { return }
                            // Use ChatTurn's efficient O(1) append method
                            assistantTurn.appendContent(s)
                            assistantContentLen += s.count
                            hasPendingContent = true
                        }

                        @MainActor
                        func appendThinking(_ s: String) {
                            guard !s.isEmpty else { return }
                            // Use ChatTurn's efficient O(1) append method
                            assistantTurn.appendThinking(s)
                            assistantThinkingLen += s.count
                            hasPendingContent = true
                        }

                        /// Sync pending content to the turn and trigger UI update
                        @MainActor
                        func syncChunksToTurn() {
                            guard hasPendingContent else { return }
                            syncCount += 1
                            assistantTurn.notifyContentChanged()
                            hasPendingContent = false
                            lastSyncTime = Date()
                            objectWillChange.send()
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
                            }
                            // Always sync any remaining chunks to the turn
                            syncChunksToTurn()
                        }

                        let stream = try await engine.streamChat(request: req)
                        for try await delta in stream {
                            if Task.isCancelled {
                                flushBuffer()  // Flush remaining before breaking
                                syncChunksToTurn()  // Sync any accumulated chunks
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

                                    // Sync interval - paragraph-based rendering allows more frequent updates
                                    // since only the last paragraph needs to update
                                    let totalChars = assistantContentLen + assistantThinkingLen
                                    let syncIntervalMs: Double = {
                                        switch totalChars {
                                        case 0 ..< 2_000:
                                            return 100  // Small: ~10 updates/sec
                                        case 2_000 ..< 5_000:
                                            return 150  // Medium: ~7 updates/sec
                                        case 5_000 ..< 10_000:
                                            return 200  // Large: ~5 updates/sec
                                        default:
                                            return 250  // Very large: ~4 updates/sec
                                        }
                                    }()

                                    let timeSinceSync = now.timeIntervalSince(lastSyncTime) * 1000

                                    // Always sync immediately for first content (syncCount == 0)
                                    // to ensure content appears without delay
                                    let shouldSync =
                                        (syncCount == 0 && hasPendingContent)
                                        || (timeSinceSync >= syncIntervalMs && hasPendingContent)

                                    if shouldSync {
                                        syncChunksToTurn()
                                    }
                                }
                            }
                        }

                        // Flush any remaining buffered content (including partial tags)
                        finalFlush()

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

                            // Handle select_capabilities specially for two-phase loading
                            if inv.toolName == "select_capabilities" {
                                resultText = try await handleSelectCapabilities(argumentsJSON: inv.jsonArguments)

                                // Rebuild system prompt and tool specs using helper methods
                                sys = buildSystemPrompt(
                                    base: baseSystemPrompt,
                                    personaId: effectivePersonaId,
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
    @ObservedObject private var windowState: ChatWindowState

    // MARK: - Environment & State

    @Environment(\.colorScheme) private var colorScheme

    @State private var focusTrigger: Int = 0
    @State private var isPinnedToBottom: Bool = true
    @State private var hostWindow: NSWindow?
    @State private var keyMonitor: Any?

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
        initialPersonaId: UUID? = nil,
        initialSessionData: ChatSessionData? = nil
    ) {
        let personaId = initialSessionData?.personaId ?? initialPersonaId ?? Persona.defaultId
        let state = ChatWindowState(
            windowId: windowId,
            personaId: personaId,
            sessionData: initialSessionData
        )
        _windowState = ObservedObject(wrappedValue: state)
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
        _windowState = ObservedObject(wrappedValue: state)
        _observedSession = ObservedObject(wrappedValue: state.session)
    }

    var body: some View {
        Group {
            // Switch between Chat and Agent modes
            if windowState.mode == .agent, let agentSession = windowState.agentSession {
                AgentView(windowState: windowState, session: agentSession)
            } else {
                chatModeContent
            }
        }
        .themedAlert(
            "Agent Task Running",
            isPresented: agentCloseConfirmationPresented,
            message:
                "This agent task is still active. You can keep it running in the background (with a live toast), or stop it and close this window.",
            buttons: [
                .primary("Run in Background") {
                    if let session = windowState.agentSession {
                        BackgroundTaskManager.shared.detachWindow(
                            windowState.windowId,
                            session: session,
                            windowState: windowState
                        )
                    }
                    ChatWindowManager.shared.closeWindow(id: windowState.windowId)
                },
                .destructive("Stop Task & Close") {
                    windowState.agentSession?.stopExecution()
                    ChatWindowManager.shared.closeWindow(id: windowState.windowId)
                },
                .cancel("Cancel"),
            ]
        )
        .themedAlertScope(.chat(windowState.windowId))
        .overlay(ThemedAlertHost(scope: .chat(windowState.windowId)))
    }

    private var agentCloseConfirmationPresented: Binding<Bool> {
        Binding(
            get: { windowState.agentCloseConfirmation != nil },
            set: { newValue in
                if !newValue {
                    windowState.agentCloseConfirmation = nil
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
                                    personaId: sessionData.personaId,
                                    sessionData: sessionData
                                )
                            }
                        )
                    }
                    .frame(width: 240, alignment: .top)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 8)
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
                                    personas: windowState.personas,
                                    activePersonaId: windowState.personaId,
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
                                    onSelectPersona: { newPersonaId in
                                        windowState.switchPersona(to: newPersonaId)
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
                                pendingImages: $observedSession.pendingImages,
                                isContinuousVoiceMode: $observedSession.isContinuousVoiceMode,
                                voiceInputState: $observedSession.voiceInputState,
                                showVoiceOverlay: $observedSession.showVoiceOverlay,
                                modelOptions: observedSession.modelOptions,
                                isStreaming: observedSession.isStreaming,
                                supportsImages: observedSession.selectedModelSupportsImages,
                                estimatedContextTokens: observedSession.estimatedContextTokens,
                                onSend: { observedSession.sendCurrent() },
                                onStop: { observedSession.stop() },
                                focusTrigger: focusTrigger,
                                personaId: windowState.personaId,
                                windowId: windowState.windowId
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
                                onUseFoundation: windowState.foundationModelAvailable
                                    ? {
                                        session.selectedModel = session.modelOptions.first?.id ?? "foundation"
                                    } : nil,
                                onQuickAction: { _ in },
                                onSelectPersona: { newPersonaId in
                                    windowState.switchPersona(to: newPersonaId)
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
        .compositingGroup()
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .ignoresSafeArea()
        .animation(theme.animationMedium(), value: session.turns.isEmpty)
        .animation(theme.springAnimation(responseMultiplier: 0.9), value: windowState.showSidebar)
        .background(WindowAccessor(window: $hostWindow))
        .onReceive(NotificationCenter.default.publisher(for: .chatOverlayActivated)) { _ in
            // Lightweight state updates only - refreshAll() removed to prevent excessive re-renders
            focusTrigger &+= 1
            isPinnedToBottom = true
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
        let displayName = windowState.cachedPersonaDisplayName
        let lastAssistantTurnId = session.turns.last { $0.role == .assistant }?.id

        return ZStack {
            MessageThreadView(
                blocks: blocks,
                width: width,
                personaName: displayName,
                isStreaming: session.isStreaming,
                scrollTrigger: session.turns.count,
                lastAssistantTurnId: lastAssistantTurnId,
                onCopy: copyTurnContent,
                onRegenerate: regenerateTurn,
                onScrolledToBottom: { isPinnedToBottom = true },
                onScrolledAwayFromBottom: { isPinnedToBottom = false }
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
                        onTap: { isPinnedToBottom = true }
                    )
                }
            }
        }
    }

    /// Stable callback for copy action - prevents closure recreation
    private func copyTurnContent(turnId: UUID) {
        guard let turn = session.turns.first(where: { $0.id == turnId }) else { return }

        // Build copyable text: thinking + content
        var textToCopy = ""

        if turn.hasThinking {
            textToCopy += turn.thinking
        }

        if !turn.contentIsEmpty {
            if !textToCopy.isEmpty {
                textToCopy += "\n\n"
            }
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

    // MARK: - Helpers

    private func displayModelName(_ raw: String?) -> String {
        guard let raw else { return "Model" }
        if raw.lowercased() == "foundation" { return "Foundation" }
        if let last = raw.split(separator: "/").last { return String(last) }
        return raw
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
        // Capture session to check overlay state
        let capturedSession = windowState.session

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

                // Check if voice input is active AND overlay is visible
                // We check overlay visibility to avoid trapping Esc if recording is stuck/zombie but UI is hidden
                if WhisperKitService.shared.isRecording && capturedSession.showVoiceOverlay {
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

                    // Also ensure we cleanup any zombie recording if it exists (hidden but recording)
                    if WhisperKitService.shared.isRecording {
                        print("[ChatView] Cleaning up zombie voice recording on window close")
                        Task {
                            _ = await WhisperKitService.shared.stopStreamingTranscription()
                            WhisperKitService.shared.clearTranscription()
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
