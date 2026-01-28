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
    }

    public func agentEngine(
        _ engine: AgentEngine,
        didCreatePlan plan: ExecutionPlan,
        forIssue issue: Issue
    ) {
        self.currentPlan = plan
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
    }

    public func agentEngine(
        _ engine: AgentEngine,
        didCompleteStep stepIndex: Int,
        result: StepResult,
        forIssue issue: Issue
    ) {
        // Step completed - streaming already handled via didReceiveStreamingDelta
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
    }

    public func agentEngine(_ engine: AgentEngine, didDecomposeIssue issue: Issue, into children: [Issue]) {
        Task {
            await self.refreshIssues()
        }
    }

    public func agentEngine(_ engine: AgentEngine, didCompleteIssue issue: Issue, success: Bool) {
        Task {
            await self.refreshIssues()
        }
    }

    public func agentEngine(_ engine: AgentEngine, willRetryIssue issue: Issue, attempt: Int, afterDelay: TimeInterval)
    {
        self.retryAttempt = attempt
        self.isRetrying = true
        self.streamingContent += "\n\n⚠️ **Retrying...** (attempt \(attempt), waiting \(Int(afterDelay))s)\n"
    }
}
