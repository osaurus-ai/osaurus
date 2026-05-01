//
//  ChatView.swift
//  osaurus
//
//  Created by Terence on 10/26/25.
//

import AppKit
import Combine
import LocalAuthentication
@preconcurrency import MLXLMCommon
import SwiftUI

/// Holds the derived, streaming-mutated `[ContentBlock]` list for the chat
/// thread. Kept as a separate `ObservableObject` so that per-token visibleBlocks
/// updates don't fire `ChatSession.objectWillChange` — that would force
/// `ChatView`'s entire body (and every sibling, notably `FloatingInputCard`
/// with its expensive glass/gradient chrome) to re-evaluate several times per
/// second during streaming. Only the message-thread subtree observes this
/// store, so streaming re-renders stay localized to the table.
@MainActor
final class VisibleBlocksStore: ObservableObject {
    @Published var blocks: [ContentBlock] = []
    @Published var groupHeaderMap: [UUID: UUID] = [:]
}

@MainActor
final class ChatSession: ObservableObject {
    @Published var turns: [ChatTurn] = []
    @Published var isStreaming: Bool = false {
        didSet {
            guard isStreaming != oldValue else { return }
            if isStreaming {
                ChatPerfTrace.shared.begin("stream-\(Int(Date().timeIntervalSince1970))")
            } else {
                ChatPerfTrace.shared.end()
            }
        }
    }
    @Published var lastStreamError: String?

    /// Single-slot FIFO queue for in-chat prompt overlays (secrets,
    /// clarify, …). Both prompt types share the same on-screen real
    /// estate (bottom-pinned card above the input bar), so they MUST be
    /// mutually exclusive — the queue ensures arrival order is honored
    /// without two cards stacking. See `PromptQueue.swift`.
    @Published var promptQueue: PromptQueue = PromptQueue()
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

    /// Origin of this session — populated by `ExecutionContext` for headless
    /// (plugin / HTTP / scheduler / watcher) runs, defaults to `.chat` for
    /// user-driven UI sessions.
    var source: SessionSource = .chat
    var sourcePluginId: String?
    var externalSessionKey: String?
    var dispatchTaskId: UUID?

    /// Tracks if session has unsaved content changes
    private var isDirty: Bool = false

    // MARK: - Memoization Cache
    private let blockMemoizer = BlockMemoizer()
    private var cachedContext: ComposedContext?
    /// Estimated memory-section token cost for the next send. Populated by
    /// `refreshMemoryTokens` and surfaced through `estimatedContextBreakdown`
    /// so the Context Budget popover shows a "Memory" line even before the
    /// first send (when `cachedContext` is still nil).
    private var cachedMemoryTokens: Int = 0
    private let budgetTracker = ContextBudgetTracker()

    /// Per-session preflight + capabilities_load tool kit lives in the
    /// process-wide `SessionToolStateStore` so chat sessions and the
    /// HTTP/plugin path share one cache. Keyed by `sessionId.uuidString`.
    private var sessionStateKey: (UUID) -> String { { $0.uuidString } }

    // MARK: - Agent Loop State (Chat-as-Agent)

    /// The agent's current todo for this chat, mirrored from
    /// `AgentTodoStore` via `.agentTodoChanged`. Read-only from the UI's
    /// perspective — only the `todo` tool writes to it.
    @Published var currentTodo: AgentTodo?

    /// Last `complete(summary)` payload from the agent. Populated when
    /// the engine intercepts `complete` and breaks the loop. The chat
    /// view renders it as a "Completed" banner inline.
    @Published var lastCompletionSummary: String?

    /// Notification observer for AgentTodoStore updates. Removed in deinit.
    nonisolated(unsafe) private var agentTodoObserver: NSObjectProtocol?

    /// Bridges `PromptQueue.objectWillChange` (a nested `ObservableObject`)
    /// up to `ChatSession.objectWillChange`. SwiftUI's `@ObservedObject`
    /// only re-renders on the outer object's emissions, so without this
    /// forward the prompt overlay wouldn't appear/disappear when the
    /// inner queue mutates `current`.
    nonisolated(unsafe) private var promptQueueCancellable: AnyCancellable?

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

        // Forward nested PromptQueue changes up so SwiftUI re-renders
        // when the queue mounts or advances. See the property comment
        // for why the explicit bridge is needed.
        promptQueueCancellable = promptQueue.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
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

        // Mirror AgentTodoStore -> currentTodo so the inline UI block
        // updates whenever the agent calls `todo`. Filter by this window's
        // current sessionId so cross-window writes don't leak across.
        agentTodoObserver = NotificationCenter.default.addObserver(
            forName: .agentTodoChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let sid = note.userInfo?["sessionId"] as? String else { return }
            Task { @MainActor in
                guard let self, sid == self.expectedTodoSessionId else { return }
                self.currentTodo = await AgentTodoStore.shared.todo(for: sid)
            }
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

        // Always reconcile on init: the cache may already be loaded with a
        // snapshot taken before remote providers finished connecting (or
        // before this window's notification observer was registered, in
        // which case we'd otherwise miss the .remoteProviderModelsChanged
        // notification entirely). `refreshPickerItems` short-circuits when
        // nothing changed, so this is cheap on the happy path.
        Task { [weak self] in
            await self?.refreshPickerItems()
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
        if let observer = agentTodoObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        modelSelectionCancellable = nil
        promptQueueCancellable = nil
    }

    /// Stable session id used as the AgentTodoStore key. Falls back to a
    /// per-window sentinel when no session has been created yet so brand-new
    /// chats still have a place to write their todo.
    var expectedTodoSessionId: String {
        sessionId?.uuidString ?? "chatwindow-\(ObjectIdentifier(self).hashValue)"
    }

    /// Pull `summary` out of a `complete(...)` tool call's JSON body.
    /// Returns nil when the JSON is malformed; the caller falls back to
    /// the raw tool result string.
    static func parseCompleteSummary(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let summary = dict["summary"] as? String
        else { return nil }
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Parse a `clarify(...)` tool call into a structured payload
    /// (question + optional options + allowMultiple). Delegated to
    /// `ClarifyTool.parse` so the schema lives in one place.
    static func parseClarifyPayload(from json: String) -> ClarifyPayload? {
        ClarifyTool.parse(argumentsJSON: json)
    }

    /// Apply initial model selection after agentId is set (for cached picker items)
    func applyInitialModelSelection() {
        guard selectedModel == nil, !pickerItems.isEmpty else { return }
        isLoadingModel = true
        let effectiveModel = AgentManager.shared.effectiveModel(for: agentId ?? Agent.defaultId)
        if let model = effectiveModel, pickerItems.contains(where: { $0.id == model }) {
            selectedModel = model
        } else {
            selectedModel = pickerItems.firstChatCapable?.id
        }
        isLoadingModel = false
        Task { [weak self] in await self?.refreshContextEstimates() }
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
            newSelected = newOptions.firstChatCapable?.id
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

    /// Backing store for the streaming-mutated `visibleBlocks` / group-header map.
    /// Deliberately NOT `@Published` — mutations go through the store's own
    /// `objectWillChange`, not the session's, so ChatView's body + every sibling
    /// view stay static during streaming. The message thread subtree observes
    /// this store directly.
    let visibleBlocksStore = VisibleBlocksStore()

    /// Flattened content blocks for NSTableView rendering.
    /// Read-through to `visibleBlocksStore.blocks` so existing call sites
    /// (helpers, checks that don't need to drive re-renders) keep working.
    var visibleBlocks: [ContentBlock] { visibleBlocksStore.blocks }

    /// Precomputed group header map. Read-through to the store.
    var visibleBlocksGroupHeaderMap: [UUID: UUID] { visibleBlocksStore.groupHeaderMap }

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
        ChatPerfTrace.shared.count("rebuildVisibleBlocks")
        ChatPerfTrace.shared.time("rebuildVisibleBlocks.total") {
            rebuildVisibleBlocksImpl()
        }
    }

    private func rebuildVisibleBlocksImpl() {
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
                visibleBlocksStore.blocks = newBlocks
                visibleBlocksStore.groupHeaderMap = newHeaderMap
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
            visibleBlocksStore.blocks = newBlocks
            visibleBlocksStore.groupHeaderMap = newHeaderMap
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

        // Mirror what `composeChatContext` will emit on the next send so
        // the welcome-screen popover lists the same sections (Agent Loop,
        // Capability Discovery, Skills, model family, …) instead of the
        // base+sandbox-only stub. Preflight tool delta and Plugin
        // Companions are query-dependent and stay deferred — the
        // auto-mode `Tools` row can under-count by that delta on turn 1.
        let preview = SystemPromptComposer.composePreviewContext(
            agentId: effectiveId,
            executionMode: executionMode,
            model: selectedModel
        )
        return .from(
            manifest: preview.manifest,
            toolTokens: preview.toolTokens,
            memoryTokens: cachedMemoryTokens,
            conversationTokens: conversationTokens,
            inputTokens: inputTokens,
            outputTokens: outputTokens
        )
    }

    /// Builds the full user message text, prepending any attached document contents wrapped in XML tags.
    ///
    /// Filenames are reduced to their basename and both the name and the body are
    /// XML-entity-escaped so that a hostile document cannot forge a closing
    /// `</attached_document>` tag or inject bracketed pseudo-tool markers that
    /// would otherwise reach the model as control text.
    static func buildUserMessageText(content: String, attachments: [Attachment]) -> String {
        let docs = attachments.filter(\.isDocument)
        guard !docs.isEmpty else { return content }

        var parts: [String] = []
        for doc in docs {
            if let name = doc.filename, let text = doc.documentContent {
                let safeName = escapeAttachmentName(name)
                let safeText = xmlEscape(text)
                parts.append("<attached_document name=\"\(safeName)\">\n\(safeText)\n</attached_document>")
            }
        }

        if !content.isEmpty {
            parts.append(content)
        }

        return parts.joined(separator: "\n\n")
    }

    private static func escapeAttachmentName(_ raw: String) -> String {
        let basename = (raw as NSString).lastPathComponent
        let trimmed = basename.trimmingCharacters(in: .whitespacesAndNewlines)
        return xmlEscape(trimmed.isEmpty ? "attachment" : trimmed)
    }

    private static func xmlEscape(_ s: String) -> String {
        s
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
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
        if let prev = sessionId {
            let key = sessionStateKey(prev)
            Task { await SessionToolStateStore.shared.invalidate(key) }
        }
        sessionId = nil
        title = "New Chat"
        createdAt = Date()
        updatedAt = Date()
        isDirty = false

        // Reset agent-loop UI state.
        currentTodo = nil
        lastCompletionSummary = nil
        promptQueue.drainAll()
        let oldSid = expectedTodoSessionId
        Task { await AgentTodoStore.shared.clear(for: oldSid) }
        // Keep current agentId - don't reset when creating new chat within same agent

        // Clear caches
        blockMemoizer.clear()
        cachedContext = nil
        visibleBlocksStore.blocks = []
        visibleBlocksStore.groupHeaderMap = [:]

        // Apply model from agent or global config (don't auto-persist, it's already saved)
        isLoadingModel = true
        let effectiveModel = AgentManager.shared.effectiveModel(for: agentId ?? Agent.defaultId)
        if let defaultModel = effectiveModel,
            pickerItems.contains(where: { $0.id == defaultModel })
        {
            selectedModel = defaultModel
        } else {
            selectedModel = pickerItems.firstChatCapable?.id
        }
        isLoadingModel = false

        rebuildVisibleBlocks()
    }

    /// Reset for a specific agent
    func reset(for newAgentId: UUID?) {
        agentId = newAgentId
        reset()
        Task { [weak self] in await self?.refreshContextEstimates() }
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
            agentId: agentId,
            source: source,
            sourcePluginId: sourcePluginId,
            externalSessionKey: externalSessionKey,
            dispatchTaskId: dispatchTaskId
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
        source = data.source
        sourcePluginId = data.sourcePluginId
        externalSessionKey = data.externalSessionKey
        dispatchTaskId = data.dispatchTaskId

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
                selectedModel = pickerItems.firstChatCapable?.id
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

        Task { [weak self] in await self?.refreshContextEstimates() }
    }

    private func refreshMemoryTokens() async {
        let effectiveAgentId = agentId ?? Agent.defaultId
        guard !AgentManager.shared.effectiveMemoryDisabled(for: effectiveAgentId) else {
            if cachedMemoryTokens != 0 {
                cachedMemoryTokens = 0
                objectWillChange.send()
            }
            return
        }
        let context = await MemoryContextAssembler.assembleContext(
            agentId: effectiveAgentId.uuidString,
            config: MemoryConfigurationStore.load()
        )
        let newTokens = ContextBudgetManager.estimateTokens(for: context)
        guard newTokens != cachedMemoryTokens else { return }
        cachedMemoryTokens = newTokens
        objectWillChange.send()
    }

    /// Re-resolve every async input the welcome-screen preview composer
    /// needs. Currently only memory tokens, but kept as a single entry
    /// point so future async preview inputs land in one place instead of
    /// being scattered across the trigger sites (agent change, session
    /// reset, session load, capability config update).
    private func refreshContextEstimates() async {
        await refreshMemoryTokens()
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
    ///
    /// `toolResult` is the new `ToolEnvelope.success` shape whose
    /// `result.text` carries the marker-delimited artifact blob. We
    /// extract the text, run the marker pipeline, and re-wrap the
    /// enriched marker block back into a success envelope. When marker
    /// parsing or file resolution fails we surface a structured
    /// `ToolEnvelope.failure(...)` so the model is told the truth instead
    /// of seeing a bogus "success" envelope.
    private func processShareArtifactResult(
        toolResult: String,
        executionMode: ExecutionMode
    ) -> String {
        guard let sessionId else { return toolResult }
        let agentName = SandboxAgentProvisioner.linuxName(
            for: (agentId ?? Agent.defaultId).uuidString
        )

        // Extract the marker block from the envelope. Older shapes (raw
        // marker-only string from before the envelope migration) are
        // accepted too so plugin authors who emit raw markers keep working.
        let markerText: String
        if let payload = ToolEnvelope.successPayload(toolResult) as? [String: Any],
            let text = payload["text"] as? String
        {
            markerText = text
        } else {
            markerText = toolResult
        }

        guard
            let processed = SharedArtifact.processToolResult(
                markerText,
                contextId: sessionId.uuidString,
                contextType: .chat,
                executionMode: executionMode,
                sandboxAgentName: agentName
            )
        else {
            // Surface the failure so the model knows the artifact did NOT
            // make it into chat. Without this, sharing a non-existent path
            // looked like success — model moved on assuming the user could
            // see the file.
            return ToolEnvelope.failure(
                kind: .executionError,
                message:
                    "share_artifact failed: could not resolve or copy the artifact source. "
                    + "Check the `path` is correct and readable, then retry.",
                tool: "share_artifact",
                retryable: true
            )
        }
        return ToolEnvelope.success(tool: "share_artifact", text: processed.enrichedToolResult)
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

    /// Best-effort estimate of the execution mode the next send will use.
    /// Prefers the registry's actual registered state (matches what
    /// `prepareChatExecutionMode` would resolve) so the token-budget preview
    /// doesn't disagree with the prompt that's actually sent. Falls back to
    /// the autonomous flag when sandbox tools have not yet been registered
    /// (first send of a session before any tool call has provisioned the
    /// container). When the user has a host folder mounted but sandbox is
    /// off, that wins — folder tools must enter the schema or
    /// `excludedToolNames(.none)` will hide them entirely.
    private func estimatedChatExecutionMode(agentId: UUID) -> ExecutionMode {
        let folder = FolderContextService.shared.currentContext
        let autonomous = AgentManager.shared.effectiveAutonomousExec(for: agentId)?.enabled == true
        let resolved = ToolRegistry.shared.resolveExecutionMode(
            folderContext: folder,
            autonomousEnabled: autonomous
        )
        // Optimistic estimate: when autonomous is on but sandbox tools haven't
        // registered yet, report `.sandbox` so the budget preview matches what
        // the next send will most likely produce after `registerTools` runs.
        if autonomous && resolved.usesSandboxTools == false { return .sandbox }
        return resolved
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
            let userChunkIndex = chunkIdx - 1
            let conversationTitle = title
            let userContent = context.userContent
            let userTokenCount = max(1, userContent.count / 4)

            // Move the SQL insert + Vectura indexing off the main
            // actor. Previously `db.insertTranscriptTurn` was called
            // synchronously here (against the database's serial
            // queue), which blocked the chat view's main-thread
            // post-stream cleanup. The companion Vectura calls were
            // already detached.
            Task.detached {
                let db = MemoryDatabase.shared
                do {
                    try db.insertTranscriptTurn(
                        agentId: aid,
                        conversationId: convId,
                        chunkIndex: userChunkIndex,
                        role: "user",
                        content: userContent,
                        tokenCount: userTokenCount,
                        title: conversationTitle
                    )
                } catch {
                    MemoryLogger.database.warning("Failed to insert user transcript turn: \(error)")
                }
                let userTurn = TranscriptTurn(
                    conversationId: convId,
                    chunkIndex: userChunkIndex,
                    role: "user",
                    content: userContent,
                    tokenCount: userTokenCount,
                    agentId: aid
                )
                await MemorySearchService.shared.indexTranscriptTurn(userTurn)
            }

            if let assistantContent, !assistantContent.isEmpty {
                let assistantTokenCount = max(1, assistantContent.count / 4)
                Task.detached {
                    let db = MemoryDatabase.shared
                    do {
                        try db.insertTranscriptTurn(
                            agentId: aid,
                            conversationId: convId,
                            chunkIndex: chunkIdx,
                            role: "assistant",
                            content: assistantContent,
                            tokenCount: assistantTokenCount,
                            title: conversationTitle
                        )
                    } catch {
                        MemoryLogger.database.warning("Failed to insert assistant transcript turn: \(error)")
                    }
                    let assistantTurn = TranscriptTurn(
                        conversationId: convId,
                        chunkIndex: chunkIdx,
                        role: "assistant",
                        content: assistantContent,
                        tokenCount: assistantTokenCount,
                        agentId: aid
                    )
                    await MemorySearchService.shared.indexTranscriptTurn(assistantTurn)
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
                await MemoryService.shared.bufferTurn(
                    userMessage: context.userContent,
                    assistantMessage: assistantContent,
                    agentId: context.memoryAgentId,
                    conversationId: context.memoryConversationId,
                    sessionDate: today
                )
            }
        }
    }

    /// Resolve the execution mode for the next send. When sandbox is on we
    /// `await registerTools` so the registry reflects the post-provision
    /// state before `resolveExecutionMode` reads it. The single resolver on
    /// `ToolRegistry` then applies the priority rule (sandbox > folder >
    /// none) and decides whether sandbox tools actually came online.
    func prepareChatExecutionMode(agentId: UUID) async -> ExecutionMode {
        let autonomous = AgentManager.shared.effectiveAutonomousExec(for: agentId)?.enabled == true
        if autonomous {
            await SandboxToolRegistrar.shared.registerTools(for: agentId)
        }
        return ToolRegistry.shared.resolveExecutionMode(
            folderContext: FolderContextService.shared.currentContext,
            autonomousEnabled: autonomous
        )
    }

    // MARK: - Private Helpers

    /// Processes the streaming delta loop from the chat engine, updating the given
    /// assistant turn and UI state. Returns any parsed tool invocations and the
    /// final updated assistant turn.
    private func processStreamDeltas(
        stream: AsyncThrowingStream<String, Error>,
        assistantTurn: ChatTurn,
        runId: UUID,
        streamStartTime: Date,
        ttftTrace: TTFTTrace?,
        selectedModel: String?
    ) async throws -> (invocations: [ServiceToolInvocation], finalTurn: ChatTurn) {
        var currentTurn = assistantTurn
        var uiDeltaCount = 0
        var firstDeltaTime: Date?
        // Track the wall-clock time of the last non-empty delta so
        // the fallback tok/s calculation uses the actual last-token
        // moment as the denominator, not the stream's close time
        // (which is after cancellation / teardown).
        var lastDeltaTime: Date?
        // Throttle key for streaming tool-call argument rebuilds.
        var lastToolArgRebuildAt: Date = .distantPast
        // Throttle key to ensure the MainActor runloop gets a turn
        // to render SwiftUI updates even if the AsyncStream buffer
        // is saturated by a fast producer.
        var lastRunloopYieldAt: Date = .distantPast

        // Reasoning text arrives as `StreamingReasoningHint` sentinel deltas
        // emitted by `GenerationEventMapper` (local MLX) or
        // `RemoteProviderService` (remote providers). The processor's
        // `receiveReasoning` routes it into the Think panel.
        var processor = StreamingDeltaProcessor(turn: currentTurn) { [weak self] in
            self?.rebuildVisibleBlocks()
        }

        // The engine surfaces parsed tool calls by *throwing* a
        // `ServiceToolInvocation` (or `ServiceToolInvocations`) at end-of-
        // stream. Catch them so this function can return them as data —
        // letting the throw escape would surface as an "Error: …
        // ServiceToolInvocation error 1" string in the UI.
        var capturedInvocations: [ServiceToolInvocation] = []

        debugLog("send: got stream, entering delta loop")
        do {
            for try await delta in stream {
                if !isRunActive(runId) {
                    processor.finalize()
                    return ([], currentTurn)
                }
                // Server-side tool call complete: add the call card + result turn to the chat log
                if let done = StreamingToolHint.decodeDone(delta) {
                    processor.finalize()
                    let call = ToolCall(
                        id: done.callId,
                        type: "function",
                        function: ToolCallFunction(name: done.name, arguments: done.arguments)
                    )
                    currentTurn.pendingToolName = nil
                    currentTurn.clearPendingToolArgs()
                    if currentTurn.toolCalls == nil { currentTurn.toolCalls = [] }
                    currentTurn.toolCalls!.append(call)
                    currentTurn.toolResults[done.callId] = done.result
                    let toolTurn = ChatTurn(role: .tool, content: done.result)
                    toolTurn.toolCallId = done.callId
                    let newAssistantTurn = ChatTurn(role: .assistant, content: "")
                    turns.append(contentsOf: [toolTurn, newAssistantTurn])
                    currentTurn = newAssistantTurn
                    processor = StreamingDeltaProcessor(
                        turn: newAssistantTurn
                    ) { [weak self] in self?.rebuildVisibleBlocks() }
                    rebuildVisibleBlocks()
                    continue
                }
                if let toolName = StreamingToolHint.decode(delta) {
                    currentTurn.pendingToolName = toolName.isEmpty ? nil : toolName
                    rebuildVisibleBlocks()
                    continue
                }
                if let argFragment = StreamingToolHint.decodeArgs(delta) {
                    currentTurn.appendToolArgFragment(argFragment)
                    // Always rebuild for the first few fragments so the chip
                    // appears immediately; afterwards cap at ~12 rebuilds/sec
                    // so the table stays responsive during long arg streams
                    // without hiding chunky provider deltas.
                    let count = currentTurn.pendingToolArgFragmentCount
                    let now = Date()
                    if count <= 3 || now.timeIntervalSince(lastToolArgRebuildAt) >= 0.08 {
                        lastToolArgRebuildAt = now
                        rebuildVisibleBlocks()
                    }
                } else if let stats = StreamingStatsHint.decode(delta) {
                    currentTurn.generationTokenCount = stats.tokenCount
                    currentTurn.generationTokensPerSecond = stats.tokensPerSecond
                    // Vmlx tells us the model never closed `</think>` before
                    // EOS / max_tokens. Persist on the turn so the bubble
                    // renderer can surface a one-line banner suggesting
                    // the user toggle Disable Thinking for this prompt class.
                    currentTurn.unclosedReasoning = stats.unclosedReasoning
                } else if let reasoning = StreamingReasoningHint.decode(delta) {
                    processor.receiveReasoning(reasoning)
                } else if !delta.isEmpty {
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

                // Hand the main run loop a turn so SwiftUI can actually paint
                // any @Published mutations we just performed. Without this,
                // when many deltas land back-to-back (e.g. Venice tool args or
                // fast text streams) the consumer task monopolises the MainActor
                // and the render pass never fires — the UI appears to stall
                // mid-stream until the loop finishes. Gated to ~12 yields/sec
                // to avoid slowing down the stream with excessive 1ms sleeps.
                let now = Date()
                if now.timeIntervalSince(lastRunloopYieldAt) >= 0.08 {
                    lastRunloopYieldAt = now
                    try? await Task.sleep(nanoseconds: 1_000_000)
                }
            }
        } catch let invs as ServiceToolInvocations {
            capturedInvocations = invs.invocations
        } catch let inv as ServiceToolInvocation {
            capturedInvocations = [inv]
        }

        // Flush any remaining buffered content (including partial tags)
        processor.finalize()

        if let first = firstDeltaTime {
            currentTurn.timeToFirstToken = first.timeIntervalSince(streamStartTime)
            // Fall back to estimated tok/s when MLX stats weren't propagated (remote APIs).
            // Use the codebase's chars/4 heuristic to approximate tokens from generated text
            // rather than raw delta count, which doesn't map 1:1 to tokens for most providers.
            if currentTurn.generationTokensPerSecond == nil,
                !currentTurn.contentIsEmpty || !currentTurn.thinkingIsEmpty
            {
                let endTime = lastDeltaTime ?? Date()
                let genTime = endTime.timeIntervalSince(first)
                // Reasoning tokens are generated on the same clock as the
                // answer; leaving them out of the numerator while keeping
                // them in the denominator under-reports throughput on
                // thinking models. Count both.
                let answerTokens = ContextBudgetManager.estimateTokens(for: currentTurn.content)
                let reasoningTokens =
                    currentTurn.thinkingIsEmpty
                    ? 0
                    : ContextBudgetManager.estimateTokens(for: currentTurn.thinking)
                let estimatedTokens = answerTokens + reasoningTokens
                if genTime > 0 && estimatedTokens > 0 {
                    currentTurn.generationTokenCount = estimatedTokens
                    currentTurn.generationTokensPerSecond = Double(estimatedTokens) / genTime
                }
            }
        }

        let totalTime = Date().timeIntervalSince(streamStartTime)
        print(
            "[Osaurus][UI] Stream consumption completed: \(uiDeltaCount) deltas in \(String(format: "%.2f", totalTime))s, final contentLen=\(currentTurn.contentLength)"
        )

        return (capturedInvocations, currentTurn)
    }

    func send(_ text: String, attachments: [Attachment] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasContent = !trimmed.isEmpty || !attachments.isEmpty
        let isRegeneration = !hasContent && !turns.isEmpty
        guard hasContent || isRegeneration else { return }

        // Any new user input clears a prior completion banner — we're
        // moving on to a follow-up. Clarify prompts (when active) live
        // in the bottom-pinned overlay with their own embedded input;
        // the main input bar is dimmed while a prompt is mounted, so
        // the user can't normally reach this path with a clarify
        // pending. The `drainAll()` here is defensive: if a prompt is
        // somehow still queued, dismiss it before sending so the new
        // turn doesn't race a stale overlay resolution.
        lastCompletionSummary = nil
        if promptQueue.current != nil {
            promptQueue.drainAll()
        }

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

                let priorUserMessages: [ChatMessage] = turns.compactMap { t in
                    guard t.role == .user, !t.contentIsEmpty else { return nil }
                    return ChatMessage(role: "user", content: t.content)
                }

                // Reuse the per-session preflight + capabilities_load union
                // on subsequent sends so we skip the LLM-based selection.
                // First, ask the store to drop the cache if the
                // (executionMode, toolMode) fingerprint flipped since the
                // last turn — otherwise stale dynamically-loaded tools or
                // an empty manual-mode preflight would leak into the new
                // mode's schema.
                let liveToolMode = AgentManager.shared.effectiveToolSelectionMode(for: effectiveAgentId)
                let liveFingerprint = SessionToolState.fingerprint(
                    executionMode: executionMode,
                    toolMode: liveToolMode
                )
                let cachedSession: SessionToolState?
                if let sid = sessionId {
                    let key = sessionStateKey(sid)
                    await SessionToolStateStore.shared.invalidateIfFingerprintChanged(
                        key,
                        liveFingerprint: liveFingerprint
                    )
                    cachedSession = await SessionToolStateStore.shared.get(key)
                } else {
                    cachedSession = nil
                }
                let context = await SystemPromptComposer.composeChatContext(
                    agentId: effectiveAgentId,
                    executionMode: executionMode,
                    model: selectedModel,
                    query: trimmed,
                    messages: priorUserMessages,
                    toolsDisabled: chatCfg.disableTools,
                    cachedPreflight: cachedSession?.initialPreflight,
                    additionalToolNames: cachedSession?.loadedToolNames ?? [],
                    frozenAlwaysLoadedNames: cachedSession?.initialAlwaysLoadedNames,
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
                let isManualTools = liveToolMode == .manual
                cachedContext = context

                // Persist the (possibly fresh) preflight + always-loaded
                // snapshot back onto the session so the next send reuses
                // both — preflight skips the LLM call, the always-loaded
                // snapshot freezes the schema against tools that register
                // mid-session. Preserves any capabilities_load names
                // already accumulated this session. Stamp the live
                // fingerprint so the invalidation rule above can detect
                // a flip on the next turn.
                if let sid = sessionId, cachedSession == nil {
                    await SessionToolStateStore.shared.setInitial(
                        sessionStateKey(sid),
                        preflight: context.preflight,
                        alwaysLoadedNames: context.alwaysLoadedNames,
                        fingerprint: liveFingerprint
                    )
                }

                // Manual mode ignores the preflight in `resolveTools`, so
                // surfacing a preflight panel from a stale auto-mode cache
                // would lie to the user about which tools the model is
                // actually getting. Gate on the live tool mode.
                if !isManualTools, !context.preflightItems.isEmpty {
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
                // Transient stream errors (e.g. provider closes connection
                // mid-tool-args, see `RemoteProviderService` truncation
                // detection) shouldn't immediately surface to the user — they
                // tend to retry cleanly. We retry the same iteration up to
                // `maxTransientRetries` times before giving up. The counter
                // is reset whenever a stream finishes naturally so unrelated
                // future failures get a fresh budget.
                let maxTransientRetries = 2
                var transientRetries = 0
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
                                    promptDump += "  - \(t.function.name): \(t.function.description ?? "")\n"
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

                    // Memory now lives on the latest user message instead of
                    // the system prompt — keeps the system prefix byte-stable
                    // across turns so the MLX paged KV cache can reuse the
                    // entire conversation prefix.
                    SystemPromptComposer.injectMemoryPrefix(context.memorySection, into: &msgs)

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
                    req.ttftTrace = ttftTrace
                    debugLog(
                        "send: attempt=\(attempts) model=\(req.model) tools=\(req.tools?.count ?? 0) sessionId=\(req.session_id ?? "nil")"
                    )
                    // Cache-fingerprint diagnostic: one `[Cache]` log line +
                    // matching TTFT fields per send so we can audit KV reuse
                    // without instrumenting MLX. Helper lives on the store
                    // so the turn counter + previous-hint comparison sit
                    // next to the state they describe.
                    if let sid = sessionId {
                        await SessionToolStateStore.shared.recordSend(
                            sessionId: sessionStateKey(sid),
                            cacheHint: context.cacheHint,
                            trace: ttftTrace
                        )
                    }
                    // Tool calls parsed from this completion. Populated by
                    // either the single-throw or batch-throw catch below; the
                    // shared per-tool block then iterates through it.
                    var pendingInvocations: [ServiceToolInvocation] = []
                    do {
                        let streamStartTime = Date()
                        let (invocations, finalTurn) = try await processStreamDeltas(
                            stream: try await engine.streamChat(request: req),
                            assistantTurn: assistantTurn,
                            runId: runId,
                            streamStartTime: streamStartTime,
                            ttftTrace: ttftTrace,
                            selectedModel: selectedModel
                        )
                        assistantTurn = finalTurn
                        pendingInvocations = invocations

                        // Stream finished naturally without a tool call — reset
                        // the transient-retry budget so a future, unrelated
                        // failure later in the conversation gets a fresh
                        // allowance.
                        if pendingInvocations.isEmpty {
                            transientRetries = 0
                            break  // finished normally
                        }
                    } catch let error as RemoteProviderServiceError {
                        // Transient provider-side stream errors — most commonly
                        // mid-tool-args truncation flagged by
                        // `RemoteProviderService.makeToolInvocation`'s
                        // `wasRepaired` guard. Silently retry the same
                        // iteration up to `maxTransientRetries` times before
                        // surfacing to the user; the model can't see what it
                        // actually streamed last time so it would just retry
                        // with the same broken args.
                        if transientRetries < maxTransientRetries {
                            transientRetries += 1
                            attempts -= 1  // don't charge this against the tool-iteration budget
                            print(
                                "[Osaurus] Transient stream error (retry \(transientRetries)/\(maxTransientRetries)): \(error.localizedDescription)"
                            )
                            // Roll back any partial UI state from the failed
                            // attempt so the retry starts clean.
                            assistantTurn.pendingToolName = nil
                            assistantTurn.clearPendingToolArgs()
                            rebuildVisibleBlocks()
                            continue outer
                        }
                        throw error
                    }

                    // Shared per-tool processing for both single and batched
                    // catches. Iterates through every parsed tool call in
                    // order; on any execution rejection we break the outer
                    // loop just like the original single-tool code did.
                    if pendingInvocations.isEmpty {
                        break  // stream finished without surfacing any tool call
                    }

                    var rejectedDuringBatch = false
                    invocations: for inv in pendingInvocations {
                        guard isRunActive(runId) else { break outer }

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

                        // Build the matching tool-result turn for this call.
                        // Every assistant `tool_use` MUST be paired with a
                        // tool turn before the loop yields control —
                        // Anthropic's Messages API rejects subsequent sends
                        // otherwise ("tool_use ids were found without
                        // tool_result blocks immediately after"). This helper
                        // is shared by the agent-loop intercepts (`complete`,
                        // `clarify`) and the normal post-execution path so
                        // there's only one place that gets the pairing right.
                        @discardableResult
                        func recordToolTurn(_ result: String) -> ChatTurn {
                            assistantTurn.toolResults[callId] = result
                            let toolTurn = ChatTurn(role: .tool, content: result)
                            toolTurn.toolCallId = callId
                            return toolTurn
                        }

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

                            // Bind the session id so the unified Chat agent
                            // tools (`todo`, etc.) can address per-session
                            // state in their stores. Falls back to a stable
                            // string when no session has been created yet so
                            // brand-new chats still get a todo store entry.
                            let sessionIdForTools =
                                sessionId?.uuidString ?? "chatwindow-\(ObjectIdentifier(self).hashValue)"
                            resultText = try await ChatExecutionContext.$currentAgentId.withValue(effectiveAgentId) {
                                try await ChatExecutionContext.$currentSessionId.withValue(sessionIdForTools) {
                                    try await ChatExecutionContext.$currentAssistantTurnId.withValue(assistantTurn.id) {
                                        try await ChatExecutionContext.$currentToolCallId.withValue(callId) {
                                            try await ToolRegistry.shared.execute(
                                                name: inv.toolName,
                                                argumentsJSON: inv.jsonArguments
                                            )
                                        }
                                    }
                                }
                            }
                            if !isRunActive(runId) { break outer }

                            // Agent-loop intercepts: `complete` and `clarify`
                            // end the iteration loop. `todo` already wrote
                            // into AgentTodoStore via TaskLocal; the session
                            // observer mirrors it into the inline UI block.
                            //
                            // CRITICAL: gate the inline UI on whether the
                            // tool result is a success envelope. The previous
                            // implementation pulled `summary` straight from
                            // the JSON arguments and surfaced it regardless
                            // of whether `CompleteTool.execute` rejected it
                            // for being a placeholder ("done", "looks good").
                            // That let the inline completion banner show a
                            // rejected summary as if the loop had ended
                            // cleanly. We now only intercept when the result
                            // is a success envelope; on rejection the loop
                            // continues so the model sees the failure and
                            // retries with a real summary.
                            if inv.toolName == "complete" {
                                if !ToolEnvelope.isError(resultText) {
                                    self.lastCompletionSummary =
                                        Self.parseCompleteSummary(from: inv.jsonArguments) ?? resultText
                                    // Drain any pending prompts so a stale
                                    // clarify card doesn't sit on top of the
                                    // completion banner.
                                    self.promptQueue.drainAll()
                                    turns.append(recordToolTurn(resultText))
                                    rebuildVisibleBlocks()
                                    break outer
                                }
                                // Fall through — let the model see the
                                // failure envelope and try again with a
                                // proper summary.
                            }
                            if inv.toolName == "clarify" {
                                if !ToolEnvelope.isError(resultText),
                                    let payload = Self.parseClarifyPayload(from: inv.jsonArguments)
                                {
                                    // Build a ClarifyPromptState bound to
                                    // `self.send(...)` so the user's answer
                                    // dispatches as the next user turn
                                    // through the existing chat send path.
                                    // The agent loop ends here; the model
                                    // resumes on the next send with the
                                    // answer in history.
                                    turns.append(recordToolTurn(resultText))
                                    rebuildVisibleBlocks()
                                    let clarifyState = ClarifyPromptState(
                                        question: payload.question,
                                        options: payload.options,
                                        allowMultiple: payload.allowMultiple,
                                        onSubmit: { [weak self] answer in
                                            self?.send(answer)
                                        }
                                    )
                                    self.promptQueue.enqueue(.clarify(clarifyState))
                                    self.lastCompletionSummary = nil
                                    break outer
                                }
                                // Fall through on failure (empty question,
                                // etc.) so the model sees the rejection.
                            }

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
                                // Persist names into the session's tool union
                                // so they survive the next compose call
                                // without re-running preflight.
                                if let sid = sessionId {
                                    let names = newTools.map { $0.function.name }
                                    let preflight = context.preflight
                                    let snapshot = context.alwaysLoadedNames
                                    await SessionToolStateStore.shared.appendLoadedTools(
                                        sessionStateKey(sid),
                                        names: names,
                                        fallbackPreflight: preflight,
                                        fallbackAlwaysLoadedNames: snapshot
                                    )
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
                                    // Route through the shared queue so
                                    // a clarify can't pop on top of a
                                    // pending secret (and vice versa).
                                    self.promptQueue.enqueue(.secret(promptState))
                                }
                                // The overlay's dismiss closure already
                                // called `promptQueue.advance()` once
                                // the user resolved; nothing to clean
                                // up here.
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
                            // Store rejection/error as the result so UI shows "Rejected" instead of hanging.
                            // The structured envelope replaces the legacy `[REJECTED] …` string so
                            // local models read a clear `{ok, kind, message, retryable}` rather than
                            // a marker they misinterpret as a sticky policy refusal. `fromError`
                            // maps FolderToolError + registry permission codes to the right `kind`
                            // so user denials, missing files, and bad arguments don't all get the
                            // same opaque `executionError` treatment.
                            let rejectionMessage = ToolEnvelope.fromError(error, tool: inv.toolName)
                            turns.append(recordToolTurn(rejectionMessage))
                            rejectedDuringBatch = true
                            break invocations  // Stop processing remaining tools in batch
                        }
                        guard isRunActive(runId) else { break outer }
                        let toolTurn = recordToolTurn(resultText)

                        // Create a new assistant turn for subsequent content
                        // This ensures tool calls and text are rendered sequentially
                        let newAssistantTurn = ChatTurn(role: .assistant, content: "")

                        // Batch both appends into a single mutation to reduce
                        // the number of @Published change signals and SwiftUI layout passes.
                        turns.append(contentsOf: [toolTurn, newAssistantTurn])
                        assistantTurn = newAssistantTurn
                        rebuildVisibleBlocks()
                    }

                    // Per-iteration budget bookkeeping (one decrement per outer
                    // iteration regardless of how many tools the batch ran).
                    if rejectedDuringBatch {
                        break outer
                    }
                    let remaining = maxAttempts - attempts
                    if remaining <= 0 {
                        reachedToolLimit = true
                    } else if remaining <= toolBudgetWarningThreshold {
                        pendingBudgetNotice =
                            "[System Notice] Tool call budget: \(remaining) of \(maxAttempts) remaining. Wrap up your current work and provide a summary."
                    }
                    continue
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
                            turn: assistantTurn
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
    // Minimap
    @State private var activeMinimapTurnId: UUID?
    @State private var scrollToTurnId: UUID?
    @State private var scrollToTurnTrigger: Int = 0
    // What's New modal
    @State private var pendingWhatsNew: WhatsNewRelease? = nil

    /// Convenience accessor for the window's theme
    private var theme: ThemeProtocol { windowState.theme }

    /// Convenience accessor for the window ID
    private var windowId: UUID { windowState.windowId }

    /// True while any prompt overlay (secret, clarify) is mounted.
    /// Drives the dim/blur on the message thread + main input bar so
    /// the prompt visibly takes the foreground. Single source of truth
    /// is `session.promptQueue.current`.
    private var isPromptOverlayActive: Bool {
        session.promptQueue.current != nil
    }

    /// Picker items filtered to the active Bonjour provider's models when a
    /// remote agent is selected, or ALL models (local + user-configured
    /// remote providers) when no remote agent is active.
    ///
    /// Prior to this fix, the no-agent branch hid every `.remote` model
    /// from the picker — which was correct for keeping Bonjour-discovered
    /// models from leaking into the local-only view, but also suppressed
    /// manually-configured remote providers (Ollama, custom OpenAI
    /// endpoints, etc.). Since user-configured providers are always
    /// intentional, they should be visible regardless of Bonjour state.
    private var filteredPickerItems: [ModelPickerItem] {
        if let providerId = windowState.selectedDiscoveredAgentProviderId {
            // Bonjour agent active: show only that agent's models.
            return session.pickerItems.filter {
                if case .remote(_, let id) = $0.source { return id == providerId }
                return false
            }
        }
        // No Bonjour agent: show everything — local, foundation, and
        // user-configured remote providers.
        return session.pickerItems
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
        let _ = ChatPerfTrace.shared.count("body.ChatView")
        chatModeContent
            .themedAlertScope(.chat(windowState.windowId))
            .overlay(ThemedAlertHost(scope: .chat(windowState.windowId)))
            .overlay { promptOverlayLayer }
    }

    /// Shared overlay layer for in-chat prompts (secrets + clarify).
    /// Renders a subtle backdrop scrim behind the prompt card and
    /// switches between concrete overlays based on the current item in
    /// `session.promptQueue`. Keyed off `current?.id` so consecutive
    /// prompts crossfade in place rather than the new card snapping in.
    /// The scrim is intentionally non-dismissive (these are deliberate
    /// pauses, not modals); ESC still cancels via the card.
    @ViewBuilder
    private var promptOverlayLayer: some View {
        let current = session.promptQueue.current
        ZStack {
            if current != nil {
                Color.black
                    .opacity(theme.isDark ? 0.28 : 0.18)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .allowsHitTesting(true)
            }

            Group {
                switch current {
                case .secret(let s):
                    SecretPromptOverlay(state: s) {
                        session.promptQueue.advance()
                    }
                case .clarify(let c):
                    ClarifyPromptOverlay(state: c) {
                        session.promptQueue.advance()
                    }
                case .none:
                    EmptyView()
                }
            }
            .id(current?.id)
            .transition(.opacity)
        }
        .animation(theme.springAnimation(), value: current?.id)
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
                                            session.selectedModel =
                                                session.pickerItems.firstChatCapable?.id
                                                ?? "foundation"
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
                                // Message thread. While a prompt
                                // overlay is mounted, blur the thread
                                // and stop hit-testing so the prompt
                                // visibly takes the foreground without
                                // letting taps leak through.
                                messageThread(effectiveContentWidth)
                                    .blur(radius: isPromptOverlayActive ? 1.5 : 0)
                                    .allowsHitTesting(!isPromptOverlayActive)
                                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                                    .animation(theme.springAnimation(), value: isPromptOverlayActive)
                            }

                            // Floating input card. Dimmed and
                            // hit-test-disabled while a prompt overlay
                            // is mounted so the prompt's embedded
                            // input is the obvious place to type, and
                            // accidental sends here can't race the
                            // prompt resolution.
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
                            .opacity(isPromptOverlayActive ? 0.55 : 1.0)
                            .allowsHitTesting(!isPromptOverlayActive)
                            .animation(theme.springAnimation(), value: isPromptOverlayActive)
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
                                        session.selectedModel = session.pickerItems.firstChatCapable?.id ?? "foundation"
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

            // Compute the conditional flags so we don't surface the
            // "restart sandbox" / "review paired devices" pages to users
            // who would have nothing to do on them.
            let hasSandbox: Bool = {
                #if os(macOS)
                    if #available(macOS 26, *) {
                        return SandboxConfigurationStore.load().setupComplete
                    }
                #endif
                return false
            }()
            let knownAgentAddrs = Set(
                AgentManager.shared.agents.compactMap { $0.agentAddress }
            )
            let hasLegacyPairedKeys = !APIKeyManager.shared
                .legacyMasterScopedKeys(knownAgentAddresses: knownAgentAddrs)
                .isEmpty
            pendingWhatsNew = WhatsNewGate.pendingAutoShowRelease(
                hasSandbox: hasSandbox,
                hasLegacyPairedKeys: hasLegacyPairedKeys
            )
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
            guard let firstItem = providerItems.firstChatCapable else { return }
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
                session.selectedModel = session.pickerItems.firstChatCapable?.id
            }
        }
        .environment(\.theme, windowState.theme)
        .tint(theme.accentColor)
        .sheet(item: $pendingWhatsNew) { release in
            WhatsNewModal(
                release: release,
                onClose: {
                    WhatsNewGate.markShown(version: release.version)
                    pendingWhatsNew = nil
                },
                onAction: { action in
                    // Mark the release seen first so the user can't loop
                    // back into it if they reopen the chat window quickly.
                    WhatsNewGate.markShown(version: release.version)
                    pendingWhatsNew = nil
                    switch action {
                    case .openSandboxSettings:
                        AppDelegate.shared?.showManagementWindow(initialTab: .sandbox)
                    case .openAPIKeysSettings:
                        AppDelegate.shared?.showManagementWindow(initialTab: .server)
                    case .openSecurityDoc(let url):
                        NSWorkspace.shared.open(url)
                    case .openStorageSettings, .exportPlaintextBackup:
                        // Both actions land on the Storage panel.
                        // `exportPlaintextBackup` doesn't auto-open
                        // the file picker — the user clicks
                        // "Export plaintext backup…" once they're
                        // there, which is the safer flow because it
                        // forces them to pick a destination.
                        AppDelegate.shared?.showManagementWindow(initialTab: .storage)
                    }
                }
            )
            .environment(\.theme, windowState.theme)
        }
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
        ChatPerfTrace.shared.count("body.messageThread")
        // do not read `session.visibleBlocks` here as that would
        // subscribe this enclosing body to per-sync changes (via ChatSession's
        // objectWillChange, if visibleBlocks were @Published) and/or delay the
        // reactivity needed by the table. `IsolatedThreadView` observes the
        // store directly, so only *its* body re-runs on per-token updates
        let displayName = windowState.cachedAgentDisplayName
        let lastAssistantTurnId = session.lastAssistantTurnIdForThread
        let blocks = session.visibleBlocks
        let minimapMarkers = buildMinimapMarkers(from: blocks)

        return ZStack {
            VStack(spacing: 8) {
                agentInlineBlocks
                IsolatedThreadView(
                    store: session.visibleBlocksStore,
                    width: width,
                    agentName: displayName,
                    agentAvatar: windowState.cachedActiveAgent.avatar,
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
                    onSpeak: speakTurnContent,
                    editingTurnId: editingTurnId,
                    editText: $editText,
                    onConfirmEdit: confirmEditAndRegenerate,
                    onCancelEdit: cancelEditing,
                    onUserImagePreview: openUserAttachmentPreview(attachmentId:),
                    onVisibleTopUserTurnChanged: { turnId in
                        activeMinimapTurnId = turnId
                    },
                    scrollToTurnId: scrollToTurnId,
                    scrollToTurnTrigger: scrollToTurnTrigger
                )
            }

            // Minimap overlay — sits at vertical center, right edge
            if minimapMarkers.count >= 2 {
                HStack {
                    Spacer()
                    ChatMinimap(
                        markers: minimapMarkers,
                        activeMarkerId: activeMinimapTurnId,
                        onSelect: { turnId in
                            scrollToTurnId = turnId
                            scrollToTurnTrigger &+= 1
                        }
                    )
                    .padding(.trailing, 22)
                }
                .allowsHitTesting(true)
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
        // re-pin to bottom when any in-chat prompt overlay opens. previously
        // wired on the MessageThreadView itself. hoisted here after the store
        // isolation so only ChatView's @State pin toggles, not the thread's
        // per-sync data path
        .onReceive(NotificationCenter.default.publisher(for: .chatOverlayActivated)) { _ in
            isPinnedToBottom = true
        }
    }

    /// Inline agent-loop blocks rendered above the message thread. Each
    /// is gated on the corresponding `@Published` state on
    /// `ChatSession`; nothing renders when the state is nil/empty.
    /// Order: completion banner first (most recent terminal event),
    /// then todo (ongoing state).
    ///
    /// `clarify` used to live here too but has been promoted to a
    /// bottom-pinned overlay (see `promptOverlayLayer`) so the question
    /// stays anchored above the input bar instead of floating above the
    /// thread.
    @ViewBuilder
    private var agentInlineBlocks: some View {
        if let summary = session.lastCompletionSummary {
            InlineCompleteBlock(summary: summary)
                .padding(.top, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
        if let todo = session.currentTodo {
            InlineTodoBlock(todo: todo)
                .padding(.top, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

}

/// Isolates the streaming-driven `visibleBlocks` observation from `ChatView`'s
/// body. This view is the only place `VisibleBlocksStore.objectWillChange`
/// propagates into SwiftUI; ChatView and its other children (FloatingInputCard,
/// toolbar, sidebar) stay outside the subscription and do not re-evaluate on
/// every streaming sync.
private struct IsolatedThreadView: View {
    @ObservedObject var store: VisibleBlocksStore
    let width: CGFloat
    let agentName: String
    let agentAvatar: String?
    let isStreaming: Bool
    let lastAssistantTurnId: UUID?
    let expandedBlocksStore: ExpandedBlocksStore
    let scrollToBottomTrigger: Int
    let onScrolledToBottom: () -> Void
    let onScrolledAwayFromBottom: () -> Void
    let onCopy: (UUID) -> Void
    let onRegenerate: ((UUID) -> Void)?
    let onEdit: ((UUID) -> Void)?
    let onDelete: ((UUID) -> Void)?
    let onSpeak: ((UUID) -> Void)?
    let editingTurnId: UUID?
    let editText: Binding<String>?
    let onConfirmEdit: (() -> Void)?
    let onCancelEdit: (() -> Void)?
    let onUserImagePreview: ((String) -> Void)?
    var onVisibleTopUserTurnChanged: ((UUID?) -> Void)? = nil
    var scrollToTurnId: UUID? = nil
    var scrollToTurnTrigger: Int = 0

    var body: some View {
        let _ = ChatPerfTrace.shared.count("body.IsolatedThreadView")
        MessageThreadView(
            blocks: store.blocks,
            groupHeaderMap: store.groupHeaderMap,
            width: width,
            agentName: agentName,
            agentAvatar: agentAvatar,
            isStreaming: isStreaming,
            lastAssistantTurnId: lastAssistantTurnId,
            expandedBlocksStore: expandedBlocksStore,
            scrollToBottomTrigger: scrollToBottomTrigger,
            onScrolledToBottom: onScrolledToBottom,
            onScrolledAwayFromBottom: onScrolledAwayFromBottom,
            onCopy: onCopy,
            onRegenerate: onRegenerate,
            onEdit: onEdit,
            onDelete: onDelete,
            onSpeak: onSpeak,
            editingTurnId: editingTurnId,
            editText: editText,
            onConfirmEdit: onConfirmEdit,
            onCancelEdit: onCancelEdit,
            onUserImagePreview: onUserImagePreview,
            onVisibleTopUserTurnChanged: onVisibleTopUserTurnChanged,
            scrollToTurnId: scrollToTurnId,
            scrollToTurnTrigger: scrollToTurnTrigger
        )
    }
}

// Reopen ChatView's declaration for the remaining methods (threadCore was
// inlined into `messageThread` via `IsolatedThreadView` above)
extension ChatView {

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

    /// Build minimap markers from the current block stream (one per user message)
    private func buildMinimapMarkers(from blocks: [ContentBlock]) -> [ChatMinimap.Marker] {
        var markers: [ChatMinimap.Marker] = []
        markers.reserveCapacity(8)
        for block in blocks {
            if case let .userMessage(text, _) = block.kind {
                markers.append(ChatMinimap.Marker(id: block.turnId, preview: text))
            }
        }
        return markers
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

    /// Read the assistant turn aloud via PocketTTS. If the model isn't downloaded,
    /// TTSService posts a notification that opens the TTS settings tab.
    private func speakTurnContent(turnId: UUID) {
        guard let turn = session.turns.first(where: { $0.id == turnId }) else { return }
        guard !turn.contentIsEmpty else { return }
        TTSService.shared.toggleSpeak(text: turn.visibleContent, messageId: turnId)
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

            SecureField(L("Server token (optional)"), text: $token)
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
                Button {
                    onCancel()
                } label: {
                    Text("Cancel", bundle: .module)
                }
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
