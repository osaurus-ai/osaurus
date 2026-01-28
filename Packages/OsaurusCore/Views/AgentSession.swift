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

    /// Content blocks for the selected issue (for MessageThreadView rendering)
    @Published var issueBlocks: [ContentBlock] = []

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

    /// Content block builder for live execution and history viewing
    private let blockBuilder = AgentContentBlockBuilder()

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

    /// Creates and starts a new task from user input
    public func startNewTask() async {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        input = ""
        errorMessage = nil
        streamingContent = ""

        do {
            // Create task
            let task = try await IssueManager.shared.createTask(query: query, personaId: personaId)
            currentTask = task

            // Refresh UI
            await refreshIssues()
            windowState?.refreshAgentTasks()

            // Start execution
            await executeNextIssue()
        } catch {
            errorMessage = "Failed to create task: \(error.localizedDescription)"
        }
    }

    /// Loads an existing task
    public func loadTask(_ task: AgentTask) async {
        currentTask = task
        await IssueManager.shared.setActiveTask(task)
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
            issueBlocks = []
            return
        }

        selectedIssueId = issue.id

        // If this issue is currently executing, show live blocks
        if activeIssue?.id == issue.id {
            issueBlocks = blockBuilder.blocks
            return
        }

        // Otherwise, load historical events
        loadIssueHistory(for: issue)
    }

    /// Loads the event history for an issue and builds content blocks
    private func loadIssueHistory(for issue: Issue) {
        do {
            let events = try IssueManager.shared.getHistory(issueId: issue.id)
            let personaName = windowState?.cachedPersonaDisplayName ?? "Agent"
            blockBuilder.reset()
            issueBlocks = AgentContentBlockBuilder(personaName: personaName)
                .buildFromHistory(events: events, issue: issue)
        } catch {
            // On error, show basic issue info
            issueBlocks = []
            print("[AgentSession] Failed to load issue history: \(error)")
        }
    }

    /// Clears the current issue selection
    public func clearSelection() {
        selectedIssueId = nil
        issueBlocks = []
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

        // Start building blocks for this execution
        blockBuilder.startExecution(for: issue)

        // Auto-select the executing issue
        selectedIssueId = issue.id
        issueBlocks = blockBuilder.blocks
    }

    public func agentEngine(
        _ engine: AgentEngine,
        didCreatePlan plan: ExecutionPlan,
        forIssue issue: Issue
    ) {
        self.currentPlan = plan

        // Update block builder with plan
        blockBuilder.handlePlanCreated(plan)
        if selectedIssueId == issue.id {
            issueBlocks = blockBuilder.blocks
        }
    }

    public func agentEngine(
        _ engine: AgentEngine,
        willExecuteStep stepIndex: Int,
        step: PlanStep,
        forIssue issue: Issue
    ) {
        self.currentStep = stepIndex
    }

    public func agentEngine(
        _ engine: AgentEngine,
        didReceiveStreamingDelta delta: String,
        forStep stepIndex: Int
    ) {
        // Append streaming content - this is the main streaming path
        self.streamingContent += delta

        // Update block builder
        blockBuilder.appendDelta(delta)
        if let activeId = activeIssue?.id, selectedIssueId == activeId {
            issueBlocks = blockBuilder.blocks
        }
    }

    public func agentEngine(
        _ engine: AgentEngine,
        didCompleteStep stepIndex: Int,
        result: StepResult,
        forIssue issue: Issue
    ) {
        // Step completed - update block builder
        blockBuilder.handleStepCompleted(stepIndex: stepIndex, content: result.responseContent)
        if selectedIssueId == issue.id {
            issueBlocks = blockBuilder.blocks
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
        self.streamingContent += "\n\n---\n✅ **Result:** \(verification.summary)"

        // Update block builder with verification
        let isSuccess = verification.status == .achieved
        blockBuilder.handleVerification(summary: verification.summary, success: isSuccess)
        if selectedIssueId == issue.id {
            issueBlocks = blockBuilder.blocks
        }
    }

    public func agentEngine(_ engine: AgentEngine, didDecomposeIssue issue: Issue, into children: [Issue]) {
        Task {
            await self.refreshIssues()
        }
    }

    public func agentEngine(_ engine: AgentEngine, didCompleteIssue issue: Issue, success: Bool) {
        // Complete the block builder
        blockBuilder.completeExecution(success: success, message: nil)
        if selectedIssueId == issue.id {
            issueBlocks = blockBuilder.blocks
        }

        Task {
            await self.refreshIssues()
        }
    }

    public func agentEngine(_ engine: AgentEngine, willRetryIssue issue: Issue, attempt: Int, afterDelay: TimeInterval)
    {
        self.retryAttempt = attempt
        self.isRetrying = true
        self.streamingContent += "\n\n⚠️ **Retrying...** (attempt \(attempt), waiting \(Int(afterDelay))s)\n"

        // Update block builder
        blockBuilder.appendDelta("\n\n⚠️ **Retrying...** (attempt \(attempt), waiting \(Int(afterDelay))s)\n")
        if selectedIssueId == issue.id {
            issueBlocks = blockBuilder.blocks
        }
    }
}
