//
//  AgentSession.swift
//  osaurus
//
//  Observable state manager for agent mode execution.
//  Tracks current task, active issue, and execution progress.
//

import Combine
import Foundation
import SwiftUI

/// Input state for agent mode - determines input behavior and placeholder text
public enum AgentInputState: Equatable {
    /// No active task - input creates new task
    case noTask
    /// Task is executing - input will be queued for injection at next step
    case executing
    /// Task open but not executing - input creates follow-up issue
    case idle
}

/// Observable session state for agent mode
@MainActor
public final class AgentSession: ObservableObject {
    // MARK: - Task State

    /// Current active task
    @Published public var currentTask: AgentTask?

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

    /// Content blocks for the selected issue - computed from current turns
    var issueBlocks: [ContentBlock] {
        let isStreamingThisIssue = isExecuting && activeIssue?.id == selectedIssueId
        return ContentBlock.generateBlocks(
            from: currentTurns,
            streamingTurnId: isStreamingThisIssue ? currentTurns.last?.id : nil,
            personaName: windowState?.cachedPersonaDisplayName ?? "Agent"
        )
    }

    /// Returns the appropriate turns based on current state
    private var currentTurns: [ChatTurn] {
        // Use live data if viewing the actively executing issue
        if let activeId = activeIssue?.id, selectedIssueId == activeId {
            return liveExecutionTurns
        }
        return selectedIssueTurns
    }

    // MARK: - Turns Management

    /// Preserves live execution turns to selected turns (call before clearing activeIssue)
    private func preserveLiveExecutionTurns() {
        selectedIssueTurns = liveExecutionTurns
        notifyTurnsChanged()
    }

    /// Clears all turns state
    private func clearTurns() {
        liveExecutionTurns = []
        selectedIssueTurns = []
        notifyTurnsChanged()
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

    // MARK: - Execution State

    /// Whether execution is in progress
    @Published public var isExecuting: Bool = false

    /// Current execution plan
    @Published public var currentPlan: ExecutionPlan?

    /// Current step being executed
    @Published public var currentStep: Int = 0

    /// Streaming response content
    @Published public var streamingContent: String = ""

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

    /// Message queued for injection at next step boundary (during execution)
    @Published public var pendingQueuedMessage: String?

    /// Selected model
    @Published var selectedModel: String?

    /// Model options
    @Published var modelOptions: [ModelOption] = []

    /// Estimated context tokens (synced from chat session for consistency)
    var estimatedContextTokens: Int {
        windowState?.session.estimatedContextTokens ?? 0
    }

    /// Current input state - determines input behavior
    public var inputState: AgentInputState {
        if currentTask == nil {
            return .noTask
        } else if isExecuting {
            return .executing
        } else {
            return .idle
        }
    }

    // MARK: - Session Config

    /// Persona ID for this session
    let personaId: UUID

    /// Reference to window state
    private weak var windowState: ChatWindowState?

    // MARK: - Private

    private var executionTask: Task<Void, Never>?

    // MARK: - Initialization

    init(personaId: UUID, windowState: ChatWindowState? = nil) {
        self.personaId = personaId
        self.windowState = windowState

        // Initialize model options from window state's session
        if let windowState = windowState {
            self.modelOptions = windowState.session.modelOptions
            self.selectedModel = windowState.session.selectedModel
        }

        // Initialize database and issue manager
        Task {
            await initialize()
        }
    }

    private func initialize() async {
        do {
            try await IssueManager.shared.initialize()
            await IssueManager.shared.refreshTasks(personaId: personaId)

            // Set self as delegate on AgentEngine to receive updates
            AgentEngine.shared.setDelegate(self)
        } catch {
            errorMessage = "Failed to initialize agent: \(error.localizedDescription)"
        }
    }

    // MARK: - Task Management

    /// Handles user input based on current input state
    public func handleUserInput() async {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        input = ""
        errorMessage = nil

        do {
            switch inputState {
            case .noTask:
                // Create new task
                streamingContent = ""
                try await startNewTask(query: query)

            case .executing:
                // Queue for injection at next step boundary
                pendingQueuedMessage = query
                if let issueId = activeIssue?.id {
                    await AgentEngine.shared.queueInput(issueId: issueId, message: query)
                }

            case .idle:
                // Create follow-up issue in existing task
                guard let task = currentTask else { return }
                streamingContent = ""
                try await addIssueToTask(query: query, task: task)
            }
        } catch {
            errorMessage = "Failed: \(error.localizedDescription)"
        }
    }

    /// Creates and starts a new task
    private func startNewTask(query: String) async throws {
        let task = try await IssueManager.shared.createTask(query: query, personaId: personaId)
        currentTask = task

        // Clear artifacts for new task
        artifacts = []
        finalArtifact = nil

        // Refresh UI
        await refreshIssues()
        windowState?.refreshAgentTasks()

        // Start execution
        await executeNextIssue()
    }

    /// Adds a new issue to an existing task
    private func addIssueToTask(query: String, task: AgentTask) async throws {
        // Create issue on the current task
        guard
            let issue = await IssueManager.shared.createIssueSafe(
                taskId: task.id,
                title: query,
                description: query,
                priority: .p2,
                type: .task
            )
        else {
            throw AgentEngineError.noIssueCreated
        }

        // Refresh issues list
        await refreshIssues()

        // Execute the new issue
        await executeIssue(issue)
    }

    /// Loads an existing task
    public func loadTask(_ task: AgentTask) async {
        currentTask = task
        await IssueManager.shared.setActiveTask(task)

        // Load artifacts for the task
        loadArtifacts(forTask: task.id)

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

        // Select the most recent completed issue, or first issue
        if let completedIssue = issues.filter({ $0.status == .closed }).last {
            selectIssue(completedIssue)
        } else if let firstIssue = issues.first {
            selectIssue(firstIssue)
        }
    }

    // MARK: - Execution

    /// Executes the next ready issue in the current task
    public func executeNextIssue() async {
        guard let taskId = currentTask?.id else { return }
        guard !isExecuting else { return }

        do {
            // Get next ready issue
            guard let issue = try await IssueManager.shared.nextReadyIssue(forTask: taskId) else {
                // No more ready issues - task might be complete
                await refreshIssues()
                return
            }

            await executeIssue(issue)
        } catch {
            errorMessage = "Failed to get next issue: \(error.localizedDescription)"
        }
    }

    /// Executes a specific issue
    public func executeIssue(_ issue: Issue, withRetry: Bool = true) async {
        guard !isExecuting else { return }

        resetExecutionState(for: issue)

        let config = buildExecutionConfig()
        let tools = ToolRegistry.shared.specs(withOverrides: config.toolOverrides)

        executionTask = Task {
            do {
                let result =
                    if withRetry {
                        try await AgentEngine.shared.executeWithRetry(
                            issueId: issue.id,
                            model: config.model,
                            systemPrompt: config.systemPrompt,
                            tools: tools,
                            toolOverrides: config.toolOverrides
                        )
                    } else {
                        try await AgentEngine.shared.resume(
                            issueId: issue.id,
                            model: config.model,
                            systemPrompt: config.systemPrompt,
                            tools: tools,
                            toolOverrides: config.toolOverrides
                        )
                    }
                await MainActor.run { self.handleExecutionResult(result) }
            } catch {
                await MainActor.run { self.handleExecutionError(error, issue: issue) }
            }
        }
    }

    /// Resets execution state for a new issue
    private func resetExecutionState(for issue: Issue) {
        isExecuting = true
        activeIssue = issue
        streamingContent = ""
        currentStep = 0
        retryAttempt = 0
        isRetrying = false
        errorMessage = nil
        failedIssue = nil
        pendingClarification = nil
        clarificationIssueId = nil
        isResumingFromClarification = false
    }

    /// Builds execution configuration from current state
    private func buildExecutionConfig() -> (model: String, systemPrompt: String, toolOverrides: [String: Bool]?) {
        let systemPrompt = windowState?.cachedSystemPrompt ?? ""

        // Model priority: selectedModel > windowState model > persona default
        let model =
            if let selected = selectedModel, !selected.isEmpty {
                selected
            } else if let wsModel = windowState?.session.selectedModel, !wsModel.isEmpty {
                wsModel
            } else {
                PersonaManager.shared.persona(for: personaId)?.defaultModel ?? "default"
            }

        let toolOverrides = PersonaManager.shared.effectiveToolOverrides(for: personaId)

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

        Task {
            await refreshIssues()
            windowState?.refreshAgentTasks()
            if result.success {
                await executeNextIssue()
            }
        }
    }

    /// Handles execution errors
    private func handleExecutionError(_ error: Error, issue: Issue) {
        finishExecution()
        errorMessage = error.localizedDescription

        if isRetriableError(error) {
            failedIssue = issue
        }

        Task { await refreshIssues() }
    }

    /// Stops the current execution
    public func stopExecution() {
        executionTask?.cancel()
        executionTask = nil
        Task { await AgentEngine.shared.cancel() }
        finishExecution()
    }

    /// Cleans up execution state after completion/error/stop
    private func finishExecution() {
        preserveLiveExecutionTurns()
        isExecuting = false
        activeIssue = nil
        currentPlan = nil
        retryAttempt = 0
        isRetrying = false
        failedIssue = nil
        pendingQueuedMessage = nil  // Clear any queued message
    }

    /// Ends the current task and resets to empty state
    public func endTask() {
        executionTask?.cancel()
        executionTask = nil
        Task { await AgentEngine.shared.cancel() }

        currentTask = nil
        issues = []
        activeIssue = nil
        clearSelection()
        clearTurns()
        artifacts = []
        finalArtifact = nil
        pendingQueuedMessage = nil
        isExecuting = false
        currentPlan = nil
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
        if let agentError = error as? AgentEngineError {
            return agentError.isRetriable
        }
        if let execError = error as? AgentExecutionError {
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
            let result = try await AgentEngine.shared.provideClarification(
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
            || turn.plan != nil
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
            notifyTurnsChanged()
            return
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

    /// Loads the event history for an issue and builds ChatTurns for rendering
    private func loadIssueHistory(for issue: Issue) {
        do {
            let events = try IssueManager.shared.getHistory(issueId: issue.id)
            let personaName = windowState?.cachedPersonaDisplayName ?? "Agent"
            selectedIssueTurns = AgentContentBlockBuilder.buildTurnsFromHistory(
                events: events,
                issue: issue,
                personaName: personaName
            )
            notifyTurnsChanged()
        } catch {
            selectedIssueTurns = []
            notifyTurnsChanged()
            print("[AgentSession] Failed to load issue history: \(error)")
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
            print("[AgentSession] Failed to load artifacts: \(error)")
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
}

// MARK: - AgentEngineDelegate Conformance

extension AgentSession: AgentEngineDelegate {
    public func agentEngine(_ engine: AgentEngine, didStartIssue issue: Issue) {
        activeIssue = issue
        streamingContent = ""
        updateLocalIssueStatus(issue.id, to: .inProgress)

        if isResumingFromClarification {
            // Resuming after clarification - preserve existing turns
            isResumingFromClarification = false
            ensureAssistantTurnExists()
        } else {
            // Fresh start - initialize turns with user request
            initializeTurns(for: issue)
        }

        selectedIssueId = issue.id
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

    public func agentEngine(_ engine: AgentEngine, didCreatePlan plan: ExecutionPlan, forIssue issue: Issue) {
        currentPlan = plan

        let turn = lastAssistantTurn()
        turn.plan = plan
        turn.currentPlanStep = 0
        turn.notifyContentChanged()

        notifyIfSelected(issue.id)
    }

    public func agentEngine(
        _ engine: AgentEngine,
        willExecuteStep stepIndex: Int,
        step: PlanStep,
        forIssue issue: Issue
    ) {
        currentStep = stepIndex

        let turn = lastAssistantTurn()
        turn.currentPlanStep = stepIndex
        turn.notifyContentChanged()

        notifyIfSelected(issue.id)
    }

    public func agentEngine(_ engine: AgentEngine, didReceiveStreamingDelta delta: String, forStep stepIndex: Int) {
        streamingContent += delta

        let turn = lastAssistantTurn()
        turn.appendContent(delta)
        turn.notifyContentChanged()

        notifyIfSelected(activeIssue?.id)
    }

    public func agentEngine(
        _ engine: AgentEngine,
        didCompleteStep stepIndex: Int,
        result: StepResult,
        forIssue issue: Issue
    ) {
        let assistantTurn = lastAssistantTurn()

        // Attach tool call result if present
        if let toolCallResult = result.toolCallResult {
            if assistantTurn.toolCalls == nil {
                assistantTurn.toolCalls = []
            }
            assistantTurn.toolCalls?.append(toolCallResult.toolCall)
            assistantTurn.toolResults[toolCallResult.toolCall.id] = toolCallResult.result

            // Add tool turn for API message flow
            let toolTurn = ChatTurn(role: .tool, content: toolCallResult.result)
            toolTurn.toolCallId = toolCallResult.toolCall.id
            liveExecutionTurns.append(toolTurn)
        }

        // Append response content
        if !result.responseContent.isEmpty {
            if assistantTurn.contentIsEmpty {
                assistantTurn.content = result.responseContent
            } else {
                assistantTurn.appendContent("\n\n" + result.responseContent)
            }
            assistantTurn.notifyContentChanged()
        }

        currentStep = stepIndex + 1
        notifyIfSelected(issue.id)
    }

    public func agentEngine(_ engine: AgentEngine, didEncounterError error: Error, forStep stepIndex: Int, issue: Issue)
    {
        errorMessage = error.localizedDescription
    }

    public func agentEngine(
        _ engine: AgentEngine,
        didVerifyGoal verification: VerificationResult,
        forIssue issue: Issue
    ) {
        let emoji = verification.status == .achieved ? "✅" : "❌"
        let content = "\n\n---\n\(emoji) **Result:** \(verification.summary)"
        streamingContent += content
        appendToAssistantTurn(content, forIssue: issue.id)
    }

    public func agentEngine(_ engine: AgentEngine, didDecomposeIssue issue: Issue, into children: [Issue]) {
        appendToAssistantTurn("\n\n🔀 **Decomposed into \(children.count) sub-issues**")
        Task { await refreshIssues() }
    }

    public func agentEngine(_ engine: AgentEngine, didGenerateArtifact artifact: Artifact, forIssue issue: Issue) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !artifacts.contains(where: { $0.id == artifact.id }) {
                artifacts.append(artifact)
            }
            if artifact.isFinalResult {
                finalArtifact = artifact
            }
        }
    }

    public func agentEngine(_ engine: AgentEngine, didCompleteIssue issue: Issue, success: Bool) {
        // Consolidate content chunks for storage
        liveExecutionTurns.filter { $0.role == .assistant }.forEach { $0.consolidateContent() }
        notifyIfSelected(issue.id)
        Task { await refreshIssues() }
    }

    public func agentEngine(_ engine: AgentEngine, willRetryIssue issue: Issue, attempt: Int, afterDelay: TimeInterval)
    {
        retryAttempt = attempt
        isRetrying = true

        let content = "\n\n⚠️ **Retrying...** (attempt \(attempt), waiting \(Int(afterDelay))s)\n"
        streamingContent += content
        appendToAssistantTurn(content, forIssue: issue.id)
    }

    public func agentEngine(
        _ engine: AgentEngine,
        needsClarification request: ClarificationRequest,
        forIssue issue: Issue
    ) {
        pendingClarification = request
        clarificationIssueId = issue.id
        isExecuting = false  // Pause while waiting for user input

        let turn = lastAssistantTurn()
        turn.pendingClarification = request
        turn.notifyContentChanged()
        notifyIfSelected(issue.id)
    }

    public func agentEngine(_ engine: AgentEngine, didInjectUserInput input: String, forIssue issue: Issue) {
        // Clear the pending queued message since it was injected
        pendingQueuedMessage = nil

        // Add user input turn to live execution
        liveExecutionTurns.append(ChatTurn(role: .user, content: "**[Context]** \(input)"))
        notifyIfSelected(issue.id)
    }
}
