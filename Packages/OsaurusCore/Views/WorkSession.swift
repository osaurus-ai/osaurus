//
//  WorkSession.swift
//  osaurus
//
//  Observable state manager for work mode execution.
//  Tracks current task, active issue, and execution progress.
//

import Combine
import Foundation
import SwiftUI

// MARK: - Work Activity Events (for background toast mini-log)

public enum WorkActivityEvent: Equatable, Sendable {
    case startedIssue(title: String)
    case willExecuteStep(index: Int, total: Int?, description: String)
    case completedStep(index: Int, total: Int?)
    case toolExecuted(name: String)
    case needsClarification
    case retrying(attempt: Int, waitSeconds: Int)
    case generatedArtifact(filename: String, isFinal: Bool)
    case completedIssue(success: Bool)
}

/// Input state for work mode - determines input behavior and placeholder text
public enum WorkInputState: Equatable {
    /// No active task - input creates new task
    case noTask
    /// Task is executing - input will be queued and sent as follow-up after completion
    case executing
    /// Task open but not executing - input creates follow-up issue
    case idle
}

/// Observable session state for work mode
@MainActor
public final class WorkSession: ObservableObject {
    // MARK: - Task State

    /// Current active task
    @Published public var currentTask: WorkTask?

    /// Tracks expand/collapse state for tool calls, thinking blocks, etc.
    let expandedBlocksStore = ExpandedBlocksStore()

    /// Issues for the current task
    @Published public var issues: [Issue] = []

    /// Currently executing issue
    @Published public var activeIssue: Issue?

    // MARK: - Issue Detail State

    /// Currently selected issue for viewing (distinct from active/executing)
    @Published public var selectedIssueId: String?

    /// Turns for the actively executing issue (live data)
    private var liveExecutionTurns: [ChatTurn] = []

    /// Turns for the selected issue (may be live or historical)
    private var selectedIssueTurns: [ChatTurn] = []

    /// Trigger for UI updates when turns change (needed because turns arrays are not @Published)
    @Published private var turnsVersion: Int = 0

    // MARK: - Streaming Delta Processing

    /// Shared processor for delta buffering, thinking tag parsing, and throttled UI updates.
    private var deltaProcessor: StreamingDeltaProcessor?

    // MARK: - Block Caching

    private let blockMemoizer = BlockMemoizer()

    /// Content blocks for the selected issue, with incremental streaming updates via BlockMemoizer.
    var issueBlocks: [ContentBlock] {
        let isStreamingThisIssue = isExecuting && activeIssue?.id == selectedIssueId
        let displayName = windowState?.cachedAgentDisplayName ?? "Work"
        let streamingTurnId = isStreamingThisIssue ? currentTurns.last?.id : nil

        return blockMemoizer.blocks(
            from: currentTurns,
            streamingTurnId: streamingTurnId,
            agentName: displayName,
            version: turnsVersion  // Ensures cache invalidation on issue switch
        )
    }

    /// Precomputed group header map from BlockMemoizer.
    var issueBlocksGroupHeaderMap: [UUID: UUID] {
        blockMemoizer.groupHeaderMap
    }

    /// Returns the appropriate turns based on current state
    private var currentTurns: [ChatTurn] {
        // Use live data if viewing the actively executing issue
        if let activeId = activeIssue?.id, selectedIssueId == activeId {
            return liveExecutionTurns
        }
        return selectedIssueTurns
    }

    /// Find a turn by ID in the currently visible turns (for copy, etc.)
    func turn(withId id: UUID) -> ChatTurn? {
        currentTurns.first(where: { $0.id == id })
    }

    // MARK: - Turns Management

    /// Preserves live execution turns to selected turns (call before clearing activeIssue)
    private func preserveLiveExecutionTurns() {
        selectedIssueTurns = liveExecutionTurns
        // Cancel any pending debounced write and flush immediately so
        // the final state is guaranteed to be persisted.
        persistDebounceTask?.cancel()
        persistDebounceTask = nil
        persistCurrentTurns()
        notifyTurnsChanged()
    }

    /// Persists the current live execution turns to the database
    private func persistCurrentTurns() {
        guard let issueId = activeIssue?.id ?? selectedIssueId else { return }
        let turns = liveExecutionTurns
        guard !turns.isEmpty else { return }
        do {
            try IssueStore.saveConversationTurns(issueId: issueId, turns: turns)
        } catch {
            print("[WorkSession] Failed to persist conversation turns: \(error)")
        }
    }

    /// Debounced persistence — coalesces rapid tool-call updates into a
    /// single write after 500 ms of inactivity, reducing main-thread I/O
    /// churn during fast tool execution sequences.
    private func schedulePersistence() {
        persistDebounceTask?.cancel()
        persistDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)  // 500 ms
            guard !Task.isCancelled, let self else { return }
            self.persistCurrentTurns()
        }
    }

    /// Clears all turns state and block cache
    private func clearTurns() {
        persistDebounceTask?.cancel()
        persistDebounceTask = nil
        liveExecutionTurns = []
        selectedIssueTurns = []
        clearBlockCache()
        notifyTurnsChanged()
    }

    /// Clears the block cache (call when switching issues or resetting)
    private func clearBlockCache() {
        blockMemoizer.clear()
    }

    /// Notifies observers that turns have changed
    private func notifyTurnsChanged() {
        turnsVersion += 1
    }

    /// Returns the last assistant turn, or creates one if needed
    private func lastAssistantTurn() -> ChatTurn {
        if let turn = liveExecutionTurns.last(where: { $0.role == .assistant }) {
            return turn
        }
        let turn = ChatTurn(role: .assistant, content: "")
        liveExecutionTurns.append(turn)
        return turn
    }

    /// Appends content to the last assistant turn and notifies if viewing this issue
    private func appendToAssistantTurn(_ content: String, forIssue issueId: String? = nil) {
        let turn = lastAssistantTurn()
        turn.appendContent(content)
        turn.notifyContentChanged()
        notifyIfSelected(issueId)
    }

    /// Notifies turns changed if the given issue is selected (or always if issueId is nil)
    private func notifyIfSelected(_ issueId: String?) {
        if issueId == nil || selectedIssueId == issueId {
            notifyTurnsChanged()
        }
    }

    /// Builds context from completed issues and artifacts for follow-up issues
    private func buildContextFromCompletedIssues(taskId: String) -> String? {
        var parts: [String] = []

        // Get recent completed issues (up to 3, chronological order)
        if let issues = try? IssueStore.listIssues(forTask: taskId)
            .filter({ $0.status == .closed })
            .sorted(by: { $0.updatedAt > $1.updatedAt })
            .prefix(3)
            .reversed()
        {
            for issue in issues {
                var part = "[Task]: \(issue.title)"
                if let result = issue.result, !result.isEmpty {
                    let truncated = result.count > 1500 ? String(result.prefix(1500)) + "..." : result
                    part += "\n[Result]: \(truncated)"
                }
                parts.append(part)
            }
        }

        // Include final artifact if available
        if let artifact = try? IssueStore.getFinalArtifact(forTask: taskId) {
            let content =
                artifact.content.count > 2000 ? String(artifact.content.prefix(2000)) + "..." : artifact.content
            parts.append("[Artifact - \(artifact.filename)]:\n\(content)")
        }

        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    // MARK: - Execution State

    /// Whether execution is in progress
    @Published public var isExecuting: Bool = false

    /// Current step/iteration being executed
    @Published public var currentStep: Int = 0

    /// Current loop state for reasoning loop execution (new)
    @Published public var loopState: LoopState?

    /// Current iteration number (alias for currentStep, for reasoning loop)
    public var currentIteration: Int {
        get { currentStep }
        set { currentStep = newValue }
    }

    /// Streaming response content (internal bookkeeping, not observed by views)
    public var streamingContent: String = ""

    /// Error message if execution failed
    @Published public var errorMessage: String?

    /// Current retry attempt (0 = first attempt)
    @Published public var retryAttempt: Int = 0

    /// Whether a retry is in progress (waiting for delay)
    @Published public var isRetrying: Bool = false

    /// Issue that failed and can be retried
    @Published public var failedIssue: Issue?

    // MARK: - Clarification State

    /// Pending clarification request (execution paused)
    @Published public var pendingClarification: ClarificationRequest?

    /// Issue ID awaiting clarification
    @Published public var clarificationIssueId: String?

    /// Flag indicating we're resuming from clarification (don't reset turns)
    private var isResumingFromClarification: Bool = false

    // MARK: - Artifact State

    /// All artifacts generated during execution
    @Published public var artifacts: [Artifact] = []

    /// The final completion artifact (from complete_task)
    @Published public var finalArtifact: Artifact?

    // MARK: - Input State

    /// User input for new tasks
    @Published public var input: String = ""

    /// Pending attachments for the next message
    @Published public var pendingAttachments: [Attachment] = []

    /// Message queued to be sent as follow-up after execution completes
    @Published public var pendingQueuedMessage: String?

    /// Attachments queued alongside the pending queued message
    @Published public var pendingQueuedAttachments: [Attachment] = []

    /// Selected model
    @Published var selectedModel: String?

    /// When true, voice input auto-restarts after AI responds (continuous conversation mode)
    @Published var isContinuousVoiceMode: Bool = false
    /// Active state of the voice input overlay
    @Published var voiceInputState: VoiceInputState = .idle
    /// Whether the voice input overlay is currently visible
    @Published var showVoiceOverlay: Bool = false

    // MARK: - Memory State

    /// Raw user message stored for memory extraction after execution completes
    private var pendingUserMessage: String?

    /// Model options
    @Published var modelOptions: [ModelOption] = []

    /// Whether the currently selected model supports image attachments
    var selectedModelSupportsImages: Bool {
        guard let model = selectedModel else { return false }
        if model.lowercased() == "foundation" { return false }
        guard let option = modelOptions.first(where: { $0.id == model }) else { return false }
        if case .remote = option.source { return true }
        return option.isVLM
    }

    /// Estimated context tokens (synced from chat session for consistency)
    var estimatedContextTokens: Int {
        windowState?.session.estimatedContextTokens ?? 0
    }

    /// Per-category context token breakdown (synced from chat session)
    var estimatedContextBreakdown: ContextTokenBreakdown {
        windowState?.session.estimatedContextBreakdown ?? .zero
    }

    // MARK: - Cumulative Token Usage

    /// Cumulative input tokens consumed across all API calls in this task
    @Published public var cumulativeInputTokens: Int = 0

    /// Cumulative output tokens consumed across all API calls in this task
    @Published public var cumulativeOutputTokens: Int = 0

    /// Total cumulative tokens (input + output) for cost prediction
    public var cumulativeTokens: Int {
        cumulativeInputTokens + cumulativeOutputTokens
    }

    /// Current input state - determines input behavior
    public var inputState: WorkInputState {
        if currentTask == nil {
            return .noTask
        } else if isExecuting {
            return .executing
        } else {
            return .idle
        }
    }

    // MARK: - Session Config

    /// Agent ID for this session
    let agentId: UUID

    /// Reference to window state (internal access for ExecutionContext back-reference)
    weak var windowState: ChatWindowState?

    // MARK: - Private

    private var executionTask: Task<Void, Never>?
    private var persistDebounceTask: Task<Void, Never>?
    nonisolated(unsafe) private var modelOptionsCancellable: AnyCancellable?

    /// The work engine instance for this session (each session owns its own engine)
    private let engine: WorkEngine

    // MARK: - Activity Feed (for background task toasts)

    private let activitySubject = PassthroughSubject<WorkActivityEvent, Never>()

    public var activityPublisher: AnyPublisher<WorkActivityEvent, Never> {
        activitySubject.eraseToAnyPublisher()
    }

    private func emitActivity(_ event: WorkActivityEvent) {
        activitySubject.send(event)
    }

    // MARK: - Initialization

    init(agentId: UUID, windowState: ChatWindowState? = nil) {
        self.agentId = agentId
        self.windowState = windowState
        self.engine = WorkEngine()

        // Initialize model options from ChatSession and subscribe to keep in sync
        // after provider changes (add/remove/enable/disable)
        if let windowState = windowState {
            self.modelOptions = windowState.session.modelOptions
            self.selectedModel = windowState.session.selectedModel

            modelOptionsCancellable = windowState.session.$modelOptions
                .dropFirst()
                .receive(on: RunLoop.main)
                .sink { [weak self] updatedOptions in
                    guard let self = self else { return }
                    self.modelOptions = updatedOptions
                    if let selected = self.selectedModel,
                        !updatedOptions.contains(where: { $0.id == selected })
                    {
                        self.selectedModel = updatedOptions.first?.id
                    }
                }
        }

        // Initialize database and issue manager
        Task { [weak self] in
            await self?.initialize()
        }
    }

    deinit {
        print("[WorkSession] deinit – agentId: \(agentId)")
        modelOptionsCancellable?.cancel()
        executionTask?.cancel()
        persistDebounceTask?.cancel()
        let engineToCancel = engine
        Task { await engineToCancel.cancel() }
    }

    private func initialize() async {
        do {
            try await IssueManager.shared.initialize()
            await IssueManager.shared.refreshTasks(agentId: agentId)

            // Set self as delegate on WorkEngine to receive updates
            engine.setDelegate(self)

            // Refresh window state's task list now that database is ready
            windowState?.refreshWorkTasks()
        } catch {
            errorMessage = "Failed to initialize work: \(error.localizedDescription)"
        }
    }

    // MARK: - Task Management

    /// Programmatic entry point for dispatched tasks (used by TaskDispatcher).
    /// Creates a new task and begins execution without touching the input field.
    public func dispatch(query: String) async throws {
        streamingContent = ""
        try await startNewTask(query: query)
    }

    /// Handles user input based on current input state
    public func handleUserInput() async {
        let rawQuery = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawQuery.isEmpty || !pendingAttachments.isEmpty else { return }

        let attachments = pendingAttachments
        input = ""
        pendingAttachments = []
        errorMessage = nil

        if !rawQuery.isEmpty {
            pendingUserMessage = rawQuery
            ActivityTracker.shared.recordActivity(agentId: agentId.uuidString)
        }

        let query = ChatSession.buildUserMessageText(content: rawQuery, attachments: attachments)
        let images = attachments.images

        do {
            switch inputState {
            case .noTask:
                streamingContent = ""
                try await startNewTask(query: query, images: images)

            case .executing:
                pendingQueuedMessage = query
                pendingQueuedAttachments = attachments

            case .idle:
                guard let task = currentTask else { return }
                streamingContent = ""
                try await addIssueToTask(query: query, images: images, task: task)
            }
        } catch {
            errorMessage = "Failed: \(error.localizedDescription)"
        }
    }

    /// Clears the queued message (user dismissed it)
    public func clearQueuedMessage() {
        pendingQueuedMessage = nil
        pendingQueuedAttachments = []
    }

    /// Creates and starts a new task
    private func startNewTask(query: String, images: [Data] = []) async throws {
        let task = try await IssueManager.shared.createTask(query: query, agentId: agentId)
        currentTask = task

        // Clear artifacts for new task
        artifacts = []
        finalArtifact = nil

        // Reset cumulative token usage for new task
        cumulativeInputTokens = 0
        cumulativeOutputTokens = 0

        // Refresh UI (windowState is nil for headless/background execution)
        await refreshIssues()
        windowState?.refreshWorkTasks()

        // Start execution
        await executeNextIssue(images: images)
    }

    /// Adds a new issue to an existing task
    private func addIssueToTask(query: String, images: [Data] = [], task: WorkTask) async throws {
        // Build context from completed issues in this task
        let context = buildContextFromCompletedIssues(taskId: task.id)

        // Create issue on the current task with context
        guard
            let issue = await IssueManager.shared.createIssueSafe(
                taskId: task.id,
                title: query,
                description: query,
                context: context,
                priority: .p2,
                type: .task
            )
        else {
            throw WorkEngineError.noIssueCreated
        }

        // Refresh issues list
        await refreshIssues()

        // Execute the new issue
        await executeIssue(issue, images: images)
    }

    /// Loads an existing task
    public func loadTask(_ task: WorkTask) async {
        currentTask = task
        await IssueManager.shared.setActiveTask(task)

        // Load artifacts for the task
        loadArtifacts(forTask: task.id)

        // Reset cumulative tokens when switching tasks (usage isn't persisted)
        cumulativeInputTokens = 0
        cumulativeOutputTokens = 0

        // Refresh issues (this also ensures an issue is selected)
        await refreshIssues()
    }

    /// Refreshes the issues list for current task
    public func refreshIssues() async {
        guard let taskId = currentTask?.id else {
            issues = []
            return
        }

        await IssueManager.shared.loadIssues(forTask: taskId)
        issues = IssueManager.shared.issues

        // Ensure an issue is always selected if there are issues
        ensureIssueSelected()
    }

    /// Ensures an issue is selected when issues exist
    private func ensureIssueSelected() {
        // Skip if already have a valid selection
        if let selectedId = selectedIssueId,
            issues.contains(where: { $0.id == selectedId })
        {
            return
        }

        // Skip if actively executing (will be selected automatically)
        if isExecuting, let activeId = activeIssue?.id {
            selectedIssueId = activeId
            return
        }

        // Prioritize in-progress issues (interrupted executions that can be resumed)
        if let inProgressIssue = issues.first(where: { $0.status == .inProgress }) {
            selectIssue(inProgressIssue)
            return
        }

        // Select the most recent completed issue, or first issue
        if let completedIssue = issues.filter({ $0.status == .closed }).last {
            selectIssue(completedIssue)
        } else if let firstIssue = issues.first {
            selectIssue(firstIssue)
        }
    }

    // MARK: - Execution

    /// Executes the next ready issue in the current task
    public func executeNextIssue(images: [Data] = []) async {
        guard let taskId = currentTask?.id else { return }
        guard !isExecuting else { return }

        do {
            // Get next ready issue
            guard let issue = try await IssueManager.shared.nextReadyIssue(forTask: taskId) else {
                // No more ready issues - task might be complete
                await refreshIssues()
                return
            }

            await executeIssue(issue, images: images)
        } catch {
            errorMessage = "Failed to get next issue: \(error.localizedDescription)"
        }
    }

    /// Executes a specific issue
    public func executeIssue(_ issue: Issue, withRetry: Bool = true, images: [Data] = []) async {
        guard !isExecuting else { return }

        resetExecutionState(for: issue)

        let config = await buildExecutionConfig()
        let tools = ToolRegistry.shared.specs(withOverrides: config.toolOverrides)
        let skillCatalog = buildSkillCatalog()

        executionTask = Task { [weak self, engine] in
            do {
                let result =
                    if withRetry {
                        try await engine.executeWithRetry(
                            issueId: issue.id,
                            model: config.model,
                            systemPrompt: config.systemPrompt,
                            tools: tools,
                            toolOverrides: config.toolOverrides,
                            skillCatalog: skillCatalog,
                            images: images
                        )
                    } else {
                        try await engine.resume(
                            issueId: issue.id,
                            model: config.model,
                            systemPrompt: config.systemPrompt,
                            tools: tools,
                            toolOverrides: config.toolOverrides,
                            skillCatalog: skillCatalog
                        )
                    }
                await MainActor.run { self?.handleExecutionResult(result) }
            } catch {
                await MainActor.run { self?.handleExecutionError(error, issue: issue) }
            }
        }
    }

    /// Resets execution state for a new issue
    private func resetExecutionState(for issue: Issue) {
        isExecuting = true
        activeIssue = issue
        streamingContent = ""
        deltaProcessor?.finalize()
        deltaProcessor = nil
        currentStep = 0
        loopState = LoopState()
        retryAttempt = 0
        isRetrying = false
        errorMessage = nil
        failedIssue = nil
        pendingClarification = nil
        clarificationIssueId = nil
        isResumingFromClarification = false
    }

    /// Builds execution configuration from current state
    private func buildExecutionConfig() async -> (model: String, systemPrompt: String, toolOverrides: [String: Bool]?) {
        let baseSystemPrompt =
            windowState?.cachedSystemPrompt
            ?? AgentManager.shared.effectiveSystemPrompt(for: agentId)

        let memoryConfig = MemoryConfigurationStore.load()
        let memoryContext = await MemoryContextAssembler.assembleContext(
            agentId: agentId.uuidString,
            config: memoryConfig
        )
        let systemPrompt =
            memoryContext.isEmpty
            ? baseSystemPrompt
            : memoryContext + "\n\n" + baseSystemPrompt

        // Model priority: selectedModel > windowState model > agent default
        let model =
            if let selected = selectedModel, !selected.isEmpty {
                selected
            } else if let wsModel = windowState?.session.selectedModel, !wsModel.isEmpty {
                wsModel
            } else {
                AgentManager.shared.agent(for: agentId)?.defaultModel ?? "default"
            }

        var toolOverrides = AgentManager.shared.effectiveToolOverrides(for: agentId)

        // Disable plugin tools that duplicate built-in work folder/git tools
        let conflicting = ToolRegistry.shared.workConflictingToolNames
        if !conflicting.isEmpty {
            if toolOverrides == nil { toolOverrides = [:] }
            for name in conflicting {
                toolOverrides?[name] = false
            }
        }

        return (model, systemPrompt, toolOverrides)
    }

    /// Handles the result of an execution
    private func handleExecutionResult(_ result: ExecutionResult) {
        // Check if we're awaiting clarification (don't finish execution yet)
        if result.isAwaitingInput, let clarification = result.awaitingClarification {
            // Clarification already handled by delegate, but ensure state is set
            if pendingClarification == nil {
                pendingClarification = clarification
                clarificationIssueId = result.issue.id
            }
            // Don't finish execution - we're paused waiting for input
            isExecuting = false
            return
        }

        finishExecution()

        if result.success {
            streamingContent = result.message
        } else {
            errorMessage = result.message
            failedIssue = result.issue
        }

        // Store artifact if present
        if let artifact = result.artifact {
            addArtifact(artifact, isFinal: true)
        }

        Task { [weak self] in
            await self?.refreshIssues()
            self?.windowState?.refreshWorkTasks()
            if result.success {
                await self?.executeNextIssue()

                // After all issues are done, auto-send queued message as follow-up
                if let self, !self.isExecuting, let queued = self.pendingQueuedMessage {
                    let queuedImages = self.pendingQueuedAttachments.images
                    self.pendingQueuedMessage = nil
                    self.pendingQueuedAttachments = []
                    guard let task = self.currentTask else { return }
                    self.streamingContent = ""
                    try? await self.addIssueToTask(query: queued, images: queuedImages, task: task)
                }
            }
        }
    }

    /// Handles execution errors
    private func handleExecutionError(_ error: Error, issue: Issue) {
        finishExecution()
        clearQueuedMessage()
        errorMessage = error.localizedDescription

        if isRetriableError(error) {
            failedIssue = issue
        }

        Task { [weak self] in await self?.refreshIssues() }
    }

    /// Stops the current execution
    public func stopExecution() {
        executionTask?.cancel()
        executionTask = nil
        Task { [engine] in await engine.cancel() }
        finishExecution()
        clearQueuedMessage()
    }

    /// Cleans up execution state after completion/error/stop
    private func finishExecution() {
        preserveLiveExecutionTurns()
        isExecuting = false
        activeIssue = nil
        loopState = nil
        retryAttempt = 0
        isRetrying = false
        failedIssue = nil
    }

    /// Ends the current task and resets to empty state
    public func endTask() {
        executionTask?.cancel()
        executionTask = nil
        Task { [engine] in await engine.cancel() }

        currentTask = nil
        issues = []
        activeIssue = nil
        clearSelection()
        clearTurns()
        artifacts = []
        finalArtifact = nil
        clearQueuedMessage()
        isExecuting = false
        loopState = nil
        errorMessage = nil
        streamingContent = ""
        retryAttempt = 0
        isRetrying = false
        failedIssue = nil
        pendingClarification = nil
        clarificationIssueId = nil
    }

    /// Checks if an error can be retried
    private func isRetriableError(_ error: Error) -> Bool {
        if let agentError = error as? WorkEngineError {
            return agentError.isRetriable
        }
        if let execError = error as? WorkExecutionError {
            return execError.isRetriable
        }
        return true  // Unknown errors might be retriable
    }

    /// Adds an artifact to the collection
    private func addArtifact(_ artifact: Artifact, isFinal: Bool) {
        if !artifacts.contains(where: { $0.id == artifact.id }) {
            artifacts.append(artifact)
        }
        if isFinal {
            finalArtifact = artifact
        }
    }

    // MARK: - Issue Actions

    /// Manually closes an issue
    public func closeIssue(_ issueId: String, reason: String) async {
        do {
            try await IssueManager.shared.closeIssue(issueId, result: reason)
            await refreshIssues()
        } catch {
            errorMessage = "Failed to close issue: \(error.localizedDescription)"
        }
    }

    /// Retries a failed issue
    public func retryIssue(_ issue: Issue) async {
        await executeIssue(issue)
    }

    // MARK: - Clarification

    /// Whether there's a pending clarification
    public var hasPendingClarification: Bool {
        pendingClarification != nil
    }

    /// Submits a clarification response and resumes execution
    public func submitClarification(_ response: String) async {
        guard let issueId = clarificationIssueId, let request = pendingClarification else { return }

        // Clear UI state and prepare for execution
        clearClarificationState()
        isExecuting = true
        errorMessage = nil

        // Update turns: remove empty assistant turn, add clarification exchange
        removeEmptyAssistantTurn()
        addClarificationTurns(question: request.question, response: response)

        // Resume execution with the clarification context
        isResumingFromClarification = true

        do {
            let result = try await engine.provideClarification(
                issueId: issueId,
                response: response
            )
            handleExecutionResult(result)
        } catch {
            let fallbackIssue = activeIssue ?? issues.first { $0.id == issueId }
            handleExecutionError(error, issue: fallbackIssue ?? Issue(taskId: "", title: ""))
        }
    }

    /// Clears the clarification UI state
    private func clearClarificationState() {
        pendingClarification = nil
        clarificationIssueId = nil
    }

    /// Removes the last assistant turn if it has no meaningful content
    private func removeEmptyAssistantTurn() {
        guard let index = liveExecutionTurns.lastIndex(where: { $0.role == .assistant }) else { return }

        let turn = liveExecutionTurns[index]
        turn.pendingClarification = nil

        let hasContent =
            !turn.contentIsEmpty
            || !(turn.toolCalls?.isEmpty ?? true)
            || !turn.thinkingIsEmpty

        if hasContent {
            turn.notifyContentChanged()
        } else {
            liveExecutionTurns.remove(at: index)
        }
    }

    /// Adds clarification question and response as new turns
    private func addClarificationTurns(question: String, response: String) {
        liveExecutionTurns.append(ChatTurn(role: .user, content: "**\(question)**\n\n\(response)"))
        liveExecutionTurns.append(ChatTurn(role: .assistant, content: ""))
        notifyTurnsChanged()
    }

    // MARK: - Issue Selection & History

    /// Selects an issue for viewing its history/details
    /// - Parameter issue: The issue to select, or nil to clear selection
    public func selectIssue(_ issue: Issue?) {
        guard let issue = issue else {
            selectedIssueId = nil
            selectedIssueTurns = []
            clearBlockCache()
            notifyTurnsChanged()
            return
        }

        // Already viewing this issue with loaded turns — nothing to do.
        // Prevents refreshIssues() -> selectIssue() -> loadIssueHistory()
        // from overwriting good in-memory turns after task completion.
        if selectedIssueId == issue.id, !selectedIssueTurns.isEmpty {
            return
        }

        // Clear cache when switching issues for clean regeneration
        if selectedIssueId != issue.id {
            clearBlockCache()
        }

        selectedIssueId = issue.id

        // If this issue is currently executing, use live data (currentTurns handles this)
        if activeIssue?.id == issue.id {
            notifyTurnsChanged()
            return
        }

        // Otherwise, load historical events into selectedIssueTurns
        loadIssueHistory(for: issue)
    }

    /// Loads persisted conversation turns for an issue
    private func loadIssueHistory(for issue: Issue) {
        do {
            let turns = try IssueStore.loadConversationTurns(issueId: issue.id)
            if !turns.isEmpty {
                selectedIssueTurns = turns
            } else {
                // No persisted turns - show issue description as a minimal user turn
                let content = issue.description ?? issue.title
                let userTurn = ChatTurn(role: .user, content: content)
                let assistantTurn = ChatTurn(role: .assistant, content: issue.result ?? "")
                selectedIssueTurns = [userTurn, assistantTurn]
            }
            notifyTurnsChanged()
        } catch {
            selectedIssueTurns = []
            notifyTurnsChanged()
            print("[WorkSession] Failed to load conversation turns: \(error)")
        }
    }

    /// Loads artifacts from the database for a task
    private func loadArtifacts(forTask taskId: String) {
        do {
            artifacts = try IssueStore.listArtifacts(forTask: taskId)
            finalArtifact = try IssueStore.getFinalArtifact(forTask: taskId)
        } catch {
            artifacts = []
            finalArtifact = nil
            print("[WorkSession] Failed to load artifacts: \(error)")
        }
    }

    /// Clears the current issue selection
    public func clearSelection() {
        selectedIssueId = nil
        clearTurns()
    }

    /// The currently selected issue object
    public var selectedIssue: Issue? {
        guard let id = selectedIssueId else { return nil }
        return issues.first { $0.id == id }
    }

    // MARK: - Computed Properties

    /// Progress of current task (0.0 to 1.0)
    public var taskProgress: Double {
        guard !issues.isEmpty else { return 0 }
        let completed = issues.filter { $0.status == .closed }.count
        return Double(completed) / Double(issues.count)
    }

    /// Number of completed issues
    public var completedIssueCount: Int {
        issues.filter { $0.status == .closed }.count
    }

    /// Number of ready issues
    public var readyIssueCount: Int {
        issues.filter { $0.status == .open }.count
    }

    /// Number of blocked issues
    public var blockedIssueCount: Int {
        issues.filter { $0.status == .blocked }.count
    }

    /// Whether the selected issue can be resumed (in progress but not currently executing)
    public var canResumeSelectedIssue: Bool {
        !isExecuting && selectedIssue?.status == .inProgress
    }

    /// Resumes execution of the selected in-progress issue
    public func resumeSelectedIssue() async {
        guard canResumeSelectedIssue, let issue = selectedIssue else { return }

        resetExecutionState(for: issue)
        let config = await buildExecutionConfig()
        let tools = ToolRegistry.shared.specs(withOverrides: config.toolOverrides)
        let skillCatalog = buildSkillCatalog()

        executionTask = Task { [weak self, engine] in
            do {
                let result = try await engine.resume(
                    issueId: issue.id,
                    model: config.model,
                    systemPrompt: config.systemPrompt,
                    tools: tools,
                    toolOverrides: config.toolOverrides,
                    skillCatalog: skillCatalog
                )
                await MainActor.run { self?.handleExecutionResult(result) }
            } catch {
                await MainActor.run { self?.handleExecutionError(error, issue: issue) }
            }
        }
    }

    // MARK: - Skill Catalog

    /// Builds the skill catalog for capability selection during planning
    private func buildSkillCatalog() -> [CapabilityEntry] {
        return SkillManager.shared.enabledCatalogEntries(
            withOverrides: AgentManager.shared.effectiveSkillOverrides(for: agentId)
        )
    }
}

// MARK: - WorkEngineDelegate Conformance

extension WorkSession: WorkEngineDelegate {
    public func workEngine(_ engine: WorkEngine, didStartIssue issue: Issue) {
        activeIssue = issue
        streamingContent = ""
        updateLocalIssueStatus(issue.id, to: .inProgress)
        emitActivity(.startedIssue(title: issue.title))

        if isResumingFromClarification {
            // Resuming after clarification - preserve existing turns
            isResumingFromClarification = false
            ensureAssistantTurnExists()
        } else {
            // Fresh start - initialize turns with user request
            initializeTurns(for: issue)
        }

        selectedIssueId = issue.id

        // Initialize streaming processor with the assistant turn
        let turn = lastAssistantTurn()
        deltaProcessor = StreamingDeltaProcessor(turn: turn, modelId: selectedModel ?? "default") { [weak self] in
            self?.notifyIfSelected(self?.activeIssue?.id)
        }

        notifyTurnsChanged()
    }

    /// Updates local issue status for immediate UI feedback
    private func updateLocalIssueStatus(_ issueId: String, to status: IssueStatus) {
        guard let index = issues.firstIndex(where: { $0.id == issueId }) else { return }
        issues[index].status = status
    }

    /// Ensures an assistant turn exists for streaming response
    private func ensureAssistantTurnExists() {
        if liveExecutionTurns.last?.role != .assistant {
            liveExecutionTurns.append(ChatTurn(role: .assistant, content: ""))
        }
    }

    /// Initializes turns for a fresh issue execution
    private func initializeTurns(for issue: Issue) {
        let displayContent = issueDisplayContent(issue)
        liveExecutionTurns = [
            ChatTurn(role: .user, content: displayContent),
            ChatTurn(role: .assistant, content: ""),
        ]
    }

    /// Gets display content for an issue, stripping internal context
    private func issueDisplayContent(_ issue: Issue) -> String {
        var content = issue.description?.isEmpty == false ? issue.description! : issue.title
        // Strip [Clarification] context (used for LLM, not display)
        if let range = content.range(of: "\n\n[Clarification]") {
            content = String(content[..<range.lowerBound])
        }
        return content
    }

    public func workEngine(_ engine: WorkEngine, didReceiveStreamingDelta delta: String, forStep stepIndex: Int) {
        streamingContent += delta
        deltaProcessor?.receiveDelta(delta)
    }

    public func workEngine(_ engine: WorkEngine, didGenerateArtifact artifact: Artifact, forIssue issue: Issue) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !artifacts.contains(where: { $0.id == artifact.id }) {
                artifacts.append(artifact)
            }
            if artifact.isFinalResult {
                finalArtifact = artifact
            }
        }

        emitActivity(.generatedArtifact(filename: artifact.filename, isFinal: artifact.isFinalResult))
    }

    public func workEngine(_ engine: WorkEngine, didCompleteIssue issue: Issue, success: Bool) {
        // Flush any remaining buffered streaming deltas
        deltaProcessor?.finalize()
        deltaProcessor = nil

        // Consolidate content chunks for storage
        liveExecutionTurns.filter { $0.role == .assistant }.forEach { $0.consolidateContent() }
        emitActivity(.completedIssue(success: success))
        notifyIfSelected(issue.id)
        Task { [weak self] in await self?.refreshIssues() }

        // Memory processing: record conversation turn for post-activity extraction
        let agentStr = agentId.uuidString
        let userMessage = pendingUserMessage ?? ""
        let assistantContent =
            liveExecutionTurns
            .last(where: { $0.role == .assistant })?.content

        if !userMessage.isEmpty {
            let convId = issue.id
            Task.detached {
                await MemoryService.shared.recordConversationTurn(
                    userMessage: userMessage,
                    assistantMessage: assistantContent,
                    agentId: agentStr,
                    conversationId: convId
                )
            }
        }

        pendingUserMessage = nil
        ActivityTracker.shared.recordActivity(agentId: agentStr)
    }

    public func workEngine(_ engine: WorkEngine, willRetryIssue issue: Issue, attempt: Int, afterDelay: TimeInterval) {
        retryAttempt = attempt
        isRetrying = true
        emitActivity(.retrying(attempt: attempt, waitSeconds: Int(afterDelay)))

        let content = "\n\n⚠️ **Retrying...** (attempt \(attempt), waiting \(Int(afterDelay))s)\n"
        streamingContent += content
        appendToAssistantTurn(content, forIssue: issue.id)
    }

    public func workEngine(
        _ engine: WorkEngine,
        needsClarification request: ClarificationRequest,
        forIssue issue: Issue
    ) {
        pendingClarification = request
        clarificationIssueId = issue.id
        isExecuting = false  // Pause while waiting for user input
        emitActivity(.needsClarification)

        let turn = lastAssistantTurn()
        turn.pendingClarification = request
        turn.notifyContentChanged()
        notifyIfSelected(issue.id)
    }

    public func workEngine(_ engine: WorkEngine, didConsumeTokens input: Int, output: Int, forIssue issue: Issue) {
        // Accumulate token usage for cost prediction
        cumulativeInputTokens += input
        cumulativeOutputTokens += output
    }

    // MARK: - Reasoning Loop Delegate Methods

    public func workEngine(_ engine: WorkEngine, didStartIteration iteration: Int, forIssue issue: Issue) {
        // Flush any buffered streaming deltas before starting a new iteration
        deltaProcessor?.flush()

        // Update current iteration for progress tracking
        currentStep = iteration
        loopState?.iteration = iteration
        loopState?.isGenerating = true
        emitActivity(
            .willExecuteStep(index: iteration, total: loopState?.maxIterations, description: "Iteration \(iteration)")
        )

        // Start a fresh assistant turn when the previous one already has content or
        // tool calls. This preserves chronological ordering so text and tool calls
        // from each iteration appear in sequence.
        if let prev = liveExecutionTurns.last(where: { $0.role == .assistant }),
            !prev.contentIsEmpty || !(prev.toolCalls?.isEmpty ?? true)
        {
            let newTurn = ChatTurn(role: .assistant, content: "")
            liveExecutionTurns.append(newTurn)
            // Reset the streaming processor to the new turn so deltas go to the
            // correct turn instead of accumulating in the first one.
            deltaProcessor?.reset(turn: newTurn)
        }

        notifyIfSelected(issue.id)
    }

    public func workEngine(
        _ engine: WorkEngine,
        didCallTool toolName: String,
        withArguments args: String,
        result: String,
        forIssue issue: Issue
    ) {
        // Flush any buffered streaming deltas before processing tool call
        deltaProcessor?.flush()

        // Update loop state with tool call info
        loopState?.toolCallCount += 1
        if let ls = loopState, !ls.toolsUsed.contains(toolName) {
            loopState?.toolsUsed.append(toolName)
        }

        emitActivity(.toolExecuted(name: toolName))

        let assistantTurn = lastAssistantTurn()

        // Clean up any leaked function-call JSON from the assistant turn's content
        // This handles cases where raw function call text was streamed before detection
        assistantTurn.trimTrailingFunctionCallLeakage(toolName: toolName)

        // Create a tool call object for the UI
        let callId = "call_\(UUID().uuidString.prefix(24))"
        let toolCall = ToolCall(
            id: callId,
            type: "function",
            function: ToolCallFunction(
                name: toolName,
                arguments: args
            )
        )

        // Attach tool call to the assistant turn
        if assistantTurn.toolCalls == nil {
            assistantTurn.toolCalls = []
        }
        assistantTurn.toolCalls?.append(toolCall)
        assistantTurn.toolResults[callId] = result

        // Add tool turn for API message flow
        let toolTurn = ChatTurn(role: .tool, content: result)
        toolTurn.toolCallId = callId
        liveExecutionTurns.append(toolTurn)

        assistantTurn.notifyContentChanged()
        notifyIfSelected(issue.id)

        // Debounce persistence so rapid tool calls don't hammer the DB
        schedulePersistence()
    }

    public func workEngine(_ engine: WorkEngine, didUpdateStatus status: String, forIssue issue: Issue) {
        // Update loop state with status message
        loopState?.statusMessage = status
        emitActivity(.willExecuteStep(index: currentStep, total: loopState?.maxIterations, description: status))
    }
}
