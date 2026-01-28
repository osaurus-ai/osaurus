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

    /// Trigger for UI updates when turns change
    @Published private var turnsVersion: Int = 0

    /// Content blocks for the selected issue - computed from selectedIssueTurns
    /// Uses ContentBlock.generateBlocks() for consistent rendering with ChatView
    var issueBlocks: [ContentBlock] {
        // Use live data if viewing the active issue, otherwise use loaded turns
        let turns: [ChatTurn]
        if let activeId = activeIssue?.id, selectedIssueId == activeId {
            turns = liveExecutionTurns
        } else {
            turns = selectedIssueTurns
        }
        let isStreamingThisIssue = isExecuting && activeIssue?.id == selectedIssueId
        return ContentBlock.generateBlocks(
            from: turns,
            streamingTurnId: isStreamingThisIssue ? turns.last?.id : nil,
            personaName: windowState?.cachedPersonaDisplayName ?? "Agent"
        )
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

    // MARK: - Artifact State

    /// All artifacts generated during execution
    @Published public var artifacts: [Artifact] = []

    /// The final completion artifact (from complete_task)
    @Published public var finalArtifact: Artifact?

    // MARK: - Input State

    /// User input for new tasks
    @Published public var input: String = ""

    /// Selected model
    @Published var selectedModel: String?

    /// Model options
    @Published var modelOptions: [ModelOption] = []

    /// Estimated context tokens (synced from chat session for consistency)
    var estimatedContextTokens: Int {
        windowState?.session.estimatedContextTokens ?? 0
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

    /// Handles user input - creates new task or adds issue to current task
    public func handleUserInput() async {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        input = ""
        errorMessage = nil
        streamingContent = ""

        do {
            if let task = currentTask {
                // Add new issue to existing task
                try await addIssueToTask(query: query, task: task)
            } else {
                // Create new task
                try await startNewTask(query: query)
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

        isExecuting = true
        activeIssue = issue
        streamingContent = ""
        currentStep = 0
        retryAttempt = 0
        isRetrying = false
        errorMessage = nil
        failedIssue = nil

        // Get execution parameters
        let systemPrompt = windowState?.cachedSystemPrompt ?? ""

        // Get the model - prefer selectedModel, fallback to persona's model, then window state's model
        let model: String
        if let selected = selectedModel, !selected.isEmpty {
            model = selected
        } else if let wsModel = windowState?.session.selectedModel, !wsModel.isEmpty {
            model = wsModel
        } else {
            // Get from persona configuration
            let persona = PersonaManager.shared.persona(for: personaId)
            model = persona?.defaultModel ?? "default"
        }

        // Get persona-specific tool overrides
        let toolOverrides = PersonaManager.shared.effectiveToolOverrides(for: personaId)

        // Get tools with persona overrides applied
        let tools = await MainActor.run {
            ToolRegistry.shared.specs(withOverrides: toolOverrides)
        }

        executionTask = Task {
            do {
                let result: ExecutionResult
                if withRetry {
                    result = try await AgentEngine.shared.executeWithRetry(
                        issueId: issue.id,
                        model: model,
                        systemPrompt: systemPrompt,
                        tools: tools,
                        toolOverrides: toolOverrides
                    )
                } else {
                    result = try await AgentEngine.shared.resume(
                        issueId: issue.id,
                        model: model,
                        systemPrompt: systemPrompt,
                        tools: tools,
                        toolOverrides: toolOverrides
                    )
                }

                await MainActor.run {
                    self.handleExecutionResult(result)
                }
            } catch {
                await MainActor.run {
                    self.handleExecutionError(error, issue: issue)
                }
            }
        }
    }

    /// Handles the result of an execution
    private func handleExecutionResult(_ result: ExecutionResult) {
        isExecuting = false
        activeIssue = nil
        currentPlan = nil
        retryAttempt = 0
        isRetrying = false
        failedIssue = nil

        if result.success {
            streamingContent = result.message
        } else {
            errorMessage = result.message
            failedIssue = result.issue
        }

        // Store the final artifact if present
        if let artifact = result.artifact {
            finalArtifact = artifact
            if !artifacts.contains(where: { $0.id == artifact.id }) {
                artifacts.append(artifact)
            }
        }

        // Refresh issues to show updated state
        Task {
            await refreshIssues()
            windowState?.refreshAgentTasks()

            // Check if there are more issues to execute
            if result.success {
                await executeNextIssue()
            }
        }
    }

    /// Handles execution errors
    private func handleExecutionError(_ error: Error, issue: Issue) {
        isExecuting = false
        activeIssue = nil
        isRetrying = false

        // Check if error is retriable
        let canRetry: Bool
        if let agentError = error as? AgentEngineError {
            canRetry = agentError.isRetriable
        } else if let execError = error as? AgentExecutionError {
            canRetry = execError.isRetriable
        } else {
            // Unknown errors might be retriable (network issues, etc.)
            canRetry = true
        }

        errorMessage = error.localizedDescription

        if canRetry {
            failedIssue = issue
        }

        // Refresh issues to show updated state
        Task {
            await refreshIssues()
        }
    }

    /// Stops the current execution
    public func stopExecution() {
        executionTask?.cancel()
        executionTask = nil

        Task {
            await AgentEngine.shared.cancel()
        }

        isExecuting = false
        activeIssue = nil
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

    // MARK: - Issue Selection & History

    /// Selects an issue for viewing its history/details
    /// - Parameter issue: The issue to select, or nil to clear selection
    public func selectIssue(_ issue: Issue?) {
        guard let issue = issue else {
            selectedIssueId = nil
            selectedIssueTurns = []
            turnsVersion += 1
            return
        }

        selectedIssueId = issue.id

        // If this issue is currently executing, use live data (issueBlocks handles this)
        if activeIssue?.id == issue.id {
            // Live execution - issueBlocks will use liveExecutionTurns
            turnsVersion += 1
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
            turnsVersion += 1
        } catch {
            // On error, show basic issue info
            selectedIssueTurns = []
            turnsVersion += 1
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
        selectedIssueTurns = []
        liveExecutionTurns = []
        turnsVersion += 1
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
        self.activeIssue = issue
        self.streamingContent = ""

        // Update the issue status locally for immediate UI feedback
        if let index = issues.firstIndex(where: { $0.id == issue.id }) {
            var updatedIssue = issues[index]
            updatedIssue.status = .inProgress
            issues[index] = updatedIssue
        }

        // Start fresh live execution turns
        liveExecutionTurns = []

        // 1. Create user turn with issue context (shows as "task" from user)
        // Use description if available (it's the full text), otherwise use title
        let displayContent: String
        if let description = issue.description, !description.isEmpty {
            displayContent = description
        } else {
            displayContent = issue.title
        }
        let userTurn = ChatTurn(role: .user, content: displayContent)
        liveExecutionTurns.append(userTurn)

        // 2. Create assistant turn for plan and execution responses
        let assistantTurn = ChatTurn(role: .assistant, content: "")
        liveExecutionTurns.append(assistantTurn)

        // Auto-select the executing issue
        selectedIssueId = issue.id
        turnsVersion += 1
    }

    public func agentEngine(
        _ engine: AgentEngine,
        didCreatePlan plan: ExecutionPlan,
        forIssue issue: Issue
    ) {
        self.currentPlan = plan

        // Store plan on the current assistant turn for PlanBlockView rendering
        if let assistantTurn = liveExecutionTurns.last(where: { $0.role == .assistant }) {
            assistantTurn.plan = plan
            assistantTurn.currentPlanStep = 0
            assistantTurn.notifyContentChanged()
        }

        if selectedIssueId == issue.id {
            turnsVersion += 1
        }
    }

    public func agentEngine(
        _ engine: AgentEngine,
        willExecuteStep stepIndex: Int,
        step: PlanStep,
        forIssue issue: Issue
    ) {
        self.currentStep = stepIndex

        // Update current step on the assistant turn for plan progress
        if let assistantTurn = liveExecutionTurns.last(where: { $0.role == .assistant }) {
            assistantTurn.currentPlanStep = stepIndex
            assistantTurn.notifyContentChanged()
        }

        if selectedIssueId == issue.id {
            turnsVersion += 1
        }
    }

    public func agentEngine(
        _ engine: AgentEngine,
        didReceiveStreamingDelta delta: String,
        forStep stepIndex: Int
    ) {
        // Append streaming content - this is the main streaming path
        self.streamingContent += delta

        // Find the current assistant turn (might not be the last turn if tool turns were added)
        if let assistantTurn = liveExecutionTurns.last(where: { $0.role == .assistant }) {
            assistantTurn.appendContent(delta)
            assistantTurn.notifyContentChanged()
        } else {
            // Create new assistant turn if none exists (shouldn't happen normally)
            let turn = ChatTurn(role: .assistant, content: delta)
            liveExecutionTurns.append(turn)
        }

        if let activeId = activeIssue?.id, selectedIssueId == activeId {
            turnsVersion += 1
        }
    }

    public func agentEngine(
        _ engine: AgentEngine,
        didCompleteStep stepIndex: Int,
        result: StepResult,
        forIssue issue: Issue
    ) {
        // Find or create the current assistant turn
        var assistantTurn: ChatTurn
        if let lastTurn = liveExecutionTurns.last, lastTurn.role == .assistant {
            assistantTurn = lastTurn
        } else if let lastAssistant = liveExecutionTurns.last(where: { $0.role == .assistant }) {
            assistantTurn = lastAssistant
        } else {
            // Create new assistant turn if none exists
            assistantTurn = ChatTurn(role: .assistant, content: "")
            liveExecutionTurns.append(assistantTurn)
        }

        // Add tool call if present - attach to the same assistant turn
        if let toolCallResult = result.toolCallResult {
            // Add tool call to current assistant turn
            if assistantTurn.toolCalls == nil {
                assistantTurn.toolCalls = []
            }
            assistantTurn.toolCalls?.append(toolCallResult.toolCall)
            assistantTurn.toolResults[toolCallResult.toolCall.id] = toolCallResult.result

            // Add a hidden tool turn for proper message flow (required for API)
            let toolTurn = ChatTurn(role: .tool, content: toolCallResult.result)
            toolTurn.toolCallId = toolCallResult.toolCall.id
            liveExecutionTurns.append(toolTurn)

            // Note: We do NOT create a new assistant turn here anymore.
            // The existing assistant turn continues to accumulate content and tool calls.
        }

        // Append response content if present
        if !result.responseContent.isEmpty {
            if assistantTurn.contentIsEmpty {
                assistantTurn.content = result.responseContent
            } else {
                assistantTurn.appendContent("\n\n" + result.responseContent)
            }
            assistantTurn.notifyContentChanged()
        }

        // Update current step for plan progress tracking
        self.currentStep = stepIndex + 1

        if selectedIssueId == issue.id {
            turnsVersion += 1
        }
    }

    public func agentEngine(
        _ engine: AgentEngine,
        didEncounterError error: Error,
        forStep stepIndex: Int,
        issue: Issue
    ) {
        self.errorMessage = error.localizedDescription
    }

    public func agentEngine(
        _ engine: AgentEngine,
        didVerifyGoal verification: VerificationResult,
        forIssue issue: Issue
    ) {
        let emoji = verification.status == .achieved ? "✅" : "❌"
        let verificationContent = "\n\n---\n\(emoji) **Result:** \(verification.summary)"
        self.streamingContent += verificationContent

        // Append to current turn
        if let lastTurn = liveExecutionTurns.last, lastTurn.role == .assistant {
            lastTurn.appendContent(verificationContent)
            lastTurn.notifyContentChanged()
        }

        if selectedIssueId == issue.id {
            turnsVersion += 1
        }
    }

    public func agentEngine(_ engine: AgentEngine, didDecomposeIssue issue: Issue, into children: [Issue]) {
        // Add decomposition info to content
        let decomposeContent = "\n\n🔀 **Decomposed into \(children.count) sub-issues**"
        if let lastTurn = liveExecutionTurns.last, lastTurn.role == .assistant {
            lastTurn.appendContent(decomposeContent)
            lastTurn.notifyContentChanged()
        }
        turnsVersion += 1

        Task {
            await self.refreshIssues()
        }
    }

    public func agentEngine(_ engine: AgentEngine, didGenerateArtifact artifact: Artifact, forIssue issue: Issue) {
        // Ensure UI updates happen on main thread
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Add to artifacts list
            if !self.artifacts.contains(where: { $0.id == artifact.id }) {
                self.artifacts.append(artifact)
            }

            // Track final artifact
            if artifact.isFinalResult {
                self.finalArtifact = artifact
            }
        }
    }

    public func agentEngine(_ engine: AgentEngine, didCompleteIssue issue: Issue, success: Bool) {
        // Consolidate content chunks for final storage
        for turn in liveExecutionTurns where turn.role == .assistant {
            turn.consolidateContent()
        }

        if selectedIssueId == issue.id {
            turnsVersion += 1
        }

        Task {
            await self.refreshIssues()
        }
    }

    public func agentEngine(_ engine: AgentEngine, willRetryIssue issue: Issue, attempt: Int, afterDelay: TimeInterval)
    {
        self.retryAttempt = attempt
        self.isRetrying = true

        let retryContent = "\n\n⚠️ **Retrying...** (attempt \(attempt), waiting \(Int(afterDelay))s)\n"
        self.streamingContent += retryContent

        // Append to current turn
        if let lastTurn = liveExecutionTurns.last, lastTurn.role == .assistant {
            lastTurn.appendContent(retryContent)
            lastTurn.notifyContentChanged()
        }

        if selectedIssueId == issue.id {
            turnsVersion += 1
        }
    }
}
