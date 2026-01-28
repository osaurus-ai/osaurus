//
//  AgentEngine.swift
//  osaurus
//
//  Main coordinator for Osaurus Agents execution flow.
//  Orchestrates IssueManager, ExecutionEngine, and DiscoveryDetector.
//

import Foundation

/// Main coordinator for agent execution
public actor AgentEngine {
    /// Shared singleton instance
    public static let shared = AgentEngine()

    /// The execution engine
    private let executionEngine: AgentExecutionEngine

    /// The discovery detector
    private let discoveryDetector: DiscoveryDetector

    /// Current execution state
    private var isExecuting = false
    private var currentIssueId: String?

    /// Error states by issue ID
    private var errorStates: [String: IssueErrorState] = [:]

    /// Retry configuration
    private var retryConfig = RetryConfiguration.default

    /// Delegate for execution events
    public nonisolated(unsafe) weak var delegate: AgentEngineDelegate?

    /// Flag to track if streaming callback is setup
    private var isStreamingSetup = false

    private init() {
        self.executionEngine = AgentExecutionEngine()
        self.discoveryDetector = DiscoveryDetector()
    }

    /// Sets the retry configuration
    public func setRetryConfiguration(_ config: RetryConfiguration) {
        self.retryConfig = config
    }

    /// Gets the error state for an issue
    public func errorState(for issueId: String) -> IssueErrorState? {
        return errorStates[issueId]
    }

    /// Clears the error state for an issue
    public func clearErrorState(for issueId: String) {
        errorStates.removeValue(forKey: issueId)
    }

    /// Ensures streaming callback is configured
    private func ensureStreamingSetup() async {
        guard !isStreamingSetup else { return }
        isStreamingSetup = true

        await executionEngine.setStreamingCallback { [weak self] (delta: String, stepIndex: Int) in
            guard let self = self else { return }
            self.delegate?.agentEngine(self, didReceiveStreamingDelta: delta, forStep: stepIndex)
        }
    }

    /// Sets the delegate for receiving execution events
    public nonisolated func setDelegate(_ delegate: AgentEngineDelegate?) {
        self.delegate = delegate
    }

    // MARK: - Entry Points

    /// Creates and executes a task from a user query
    /// - Parameters:
    ///   - query: The user's query/request
    ///   - personaId: Optional persona ID
    ///   - model: Model to use for execution
    ///   - systemPrompt: System prompt to use
    ///   - tools: Available tools
    ///   - toolOverrides: Per-session tool overrides
    /// - Returns: The execution result
    func run(
        query: String,
        personaId: UUID? = nil,
        model: String?,
        systemPrompt: String,
        tools: [Tool],
        toolOverrides: [String: Bool]? = nil
    ) async throws -> ExecutionResult {
        guard !isExecuting else {
            throw AgentEngineError.alreadyExecuting
        }

        // Create task and initial issue (IssueManager is @MainActor)
        let task = await IssueManager.shared.createTaskSafe(query: query, personaId: personaId)
        guard let task = task else {
            throw AgentEngineError.noIssueCreated
        }

        // Get the initial issue
        let issues = try IssueStore.listIssues(forTask: task.id)

        guard let issue = issues.first else {
            throw AgentEngineError.noIssueCreated
        }

        return try await execute(
            issue: issue,
            model: model,
            systemPrompt: systemPrompt,
            tools: tools,
            toolOverrides: toolOverrides
        )
    }

    /// Resumes execution of an existing issue
    func resume(
        issueId: String,
        model: String?,
        systemPrompt: String,
        tools: [Tool],
        toolOverrides: [String: Bool]? = nil
    ) async throws -> ExecutionResult {
        guard !isExecuting else {
            throw AgentEngineError.alreadyExecuting
        }

        guard let issue = try IssueStore.getIssue(id: issueId) else {
            throw AgentEngineError.issueNotFound(issueId)
        }

        return try await execute(
            issue: issue,
            model: model,
            systemPrompt: systemPrompt,
            tools: tools,
            toolOverrides: toolOverrides
        )
    }

    /// Executes the next ready issue (highest priority, oldest)
    func next(
        taskId: String? = nil,
        model: String?,
        systemPrompt: String,
        tools: [Tool],
        toolOverrides: [String: Bool]? = nil
    ) async throws -> ExecutionResult? {
        guard !isExecuting else {
            throw AgentEngineError.alreadyExecuting
        }

        let readyIssues = try IssueStore.readyIssues(forTask: taskId)

        guard let issue = readyIssues.first else {
            return nil  // No ready issues
        }

        return try await execute(
            issue: issue,
            model: model,
            systemPrompt: systemPrompt,
            tools: tools,
            toolOverrides: toolOverrides
        )
    }

    /// Creates an issue without executing it
    public func create(
        taskId: String,
        title: String,
        description: String? = nil,
        priority: IssuePriority = .p2,
        type: IssueType = .task
    ) async throws -> Issue {
        let issue = await IssueManager.shared.createIssueSafe(
            taskId: taskId,
            title: title,
            description: description,
            priority: priority,
            type: type
        )
        guard let issue = issue else {
            throw AgentEngineError.noIssueCreated
        }
        return issue
    }

    /// Manually closes an issue
    public func close(issueId: String, reason: String) async throws {
        let success = await IssueManager.shared.closeIssueSafe(issueId, result: reason)
        if !success {
            throw AgentEngineError.issueNotFound(issueId)
        }
    }

    /// Cancels the current execution
    public func cancel() async {
        isExecuting = false
        currentIssueId = nil
        await executionEngine.reset()
    }

    // MARK: - Main Execution Flow

    /// Executes an issue through the complete agent flow
    private func execute(
        issue: Issue,
        model: String?,
        systemPrompt: String,
        tools: [Tool],
        toolOverrides: [String: Bool]?
    ) async throws -> ExecutionResult {
        // Ensure streaming is setup before execution
        await ensureStreamingSetup()

        isExecuting = true
        currentIssueId = issue.id

        defer {
            isExecuting = false
            currentIssueId = nil
        }

        // Mark issue as in progress
        _ = await IssueManager.shared.startIssueSafe(issue.id)

        await delegate?.agentEngine(self, didStartIssue: issue)

        // Generate plan
        let planResult = try await executionEngine.generatePlan(
            for: issue,
            systemPrompt: systemPrompt,
            model: model,
            tools: tools
        )

        switch planResult {
        case .needsDecomposition(let steps, let chunks):
            // Decompose the issue
            return try await decomposeIssue(
                issue: issue,
                steps: steps,
                chunks: chunks
            )

        case .ready(let plan):
            // Log plan creation
            try IssueStore.createEvent(
                IssueEvent.withPayload(
                    issueId: issue.id,
                    eventType: .planCreated,
                    payload: EventPayload.StepCount(stepCount: plan.steps.count)
                )
            )

            await delegate?.agentEngine(self, didCreatePlan: plan, forIssue: issue)

            // Execute the plan
            return try await executePlan(
                plan: plan,
                issue: issue,
                model: model,
                systemPrompt: systemPrompt,
                tools: tools,
                toolOverrides: toolOverrides
            )
        }
    }

    /// Decomposes an issue into child issues
    private func decomposeIssue(
        issue: Issue,
        steps: [PlanStep],
        chunks: [[PlanStep]]
    ) async throws -> ExecutionResult {
        // Create child issues from chunks
        let children = chunks.enumerated().map { index, chunk -> (title: String, description: String?) in
            let title = "Part \(index + 1): \(chunk.first?.description ?? "Execute steps")"
            let description = chunk.map { "- \($0.description)" }.joined(separator: "\n")
            return (title, description)
        }

        let childIssues = await IssueManager.shared.decomposeIssueSafe(issue.id, into: children)

        await delegate?.agentEngine(self, didDecomposeIssue: issue, into: childIssues)

        return ExecutionResult(
            issue: issue,
            success: true,
            message: "Decomposed into \(childIssues.count) child issues",
            discoveries: [],
            childIssues: childIssues
        )
    }

    /// Executes a plan step by step
    private func executePlan(
        plan: ExecutionPlan,
        issue: Issue,
        model: String?,
        systemPrompt: String,
        tools: [Tool],
        toolOverrides: [String: Bool]?
    ) async throws -> ExecutionResult {
        var messages: [ChatMessage] = []
        var allDiscoveries: [Discovery] = []

        // Execute each step
        for stepIndex in 0 ..< plan.steps.count {
            guard isExecuting else {
                throw AgentExecutionError.executionCancelled
            }

            let step = plan.steps[stepIndex]
            await delegate?.agentEngine(self, willExecuteStep: stepIndex, step: step, forIssue: issue)

            do {
                let stepResult = try await executionEngine.executeStep(
                    stepIndex: stepIndex,
                    issue: issue,
                    messages: &messages,
                    systemPrompt: systemPrompt,
                    model: model,
                    tools: tools,
                    toolOverrides: toolOverrides
                )

                await delegate?.agentEngine(self, didCompleteStep: stepIndex, result: stepResult, forIssue: issue)

                // Analyze tool output for discoveries
                if let toolResult = stepResult.toolCallResult {
                    let context = DiscoveryContext(
                        issueId: issue.id,
                        taskId: issue.taskId,
                        currentStep: stepIndex
                    )
                    let discoveries = await discoveryDetector.analyze(
                        toolOutput: toolResult.result,
                        toolName: toolResult.toolCall.function.name,
                        context: context
                    )
                    allDiscoveries.append(contentsOf: discoveries)
                }

                // Analyze LLM response for discoveries
                if !stepResult.responseContent.isEmpty {
                    let context = DiscoveryContext(
                        issueId: issue.id,
                        taskId: issue.taskId,
                        currentStep: stepIndex
                    )
                    let discoveries = await discoveryDetector.analyzeResponse(
                        response: stepResult.responseContent,
                        context: context
                    )
                    allDiscoveries.append(contentsOf: discoveries)
                }

            } catch {
                await delegate?.agentEngine(self, didEncounterError: error, forStep: stepIndex, issue: issue)
                throw error
            }
        }

        // Verify goal achievement
        let verification = try await executionEngine.verifyGoal(
            issue: issue,
            messages: messages,
            systemPrompt: systemPrompt,
            model: model
        )

        await delegate?.agentEngine(self, didVerifyGoal: verification, forIssue: issue)

        // Create discovered issues
        var createdDiscoveries: [Issue] = []
        for discovery in allDiscoveries {
            if let discoveryIssue = await IssueManager.shared.createIssueSafe(
                taskId: issue.taskId,
                title: discovery.title,
                description: discovery.description,
                priority: discovery.suggestedPriority,
                type: .discovery
            ) {
                _ = await IssueManager.shared.linkDiscoverySafe(
                    sourceIssueId: issue.id,
                    discoveredIssueId: discoveryIssue.id
                )
                createdDiscoveries.append(discoveryIssue)
            }
        }

        // Close or update issue based on verification
        let success: Bool
        let resultMessage: String

        switch verification.status {
        case .achieved:
            success = true
            resultMessage = verification.summary
            _ = await IssueManager.shared.closeIssueSafe(issue.id, result: verification.summary)

        case .partial:
            success = true
            resultMessage = verification.summary
            // Create follow-up issue for remaining work
            if let remaining = verification.remainingWork {
                if let followUp = await IssueManager.shared.createIssueSafe(
                    taskId: issue.taskId,
                    title: "Follow-up: \(remaining.prefix(50))",
                    description: remaining,
                    priority: issue.priority,
                    type: .task
                ) {
                    createdDiscoveries.append(followUp)
                }
            }
            _ = await IssueManager.shared.closeIssueSafe(
                issue.id,
                result: "Partially completed: \(verification.summary)"
            )

        case .notAchieved:
            success = false
            resultMessage = "Goal not achieved: \(verification.summary)"
            // Re-open issue for retry
            _ = await IssueManager.shared.updateIssueStatusSafe(issue.id, to: .open)
        }

        // Log execution completed
        try IssueStore.createEvent(
            IssueEvent.withPayload(
                issueId: issue.id,
                eventType: .executionCompleted,
                payload: EventPayload.ExecutionCompleted(success: success, discoveries: allDiscoveries.count)
            )
        )

        await delegate?.agentEngine(self, didCompleteIssue: issue, success: success)

        return ExecutionResult(
            issue: issue,
            success: success,
            message: resultMessage,
            discoveries: allDiscoveries,
            childIssues: createdDiscoveries
        )
    }

    // MARK: - Retry Logic

    /// Executes an issue with automatic retry on transient failures
    func executeWithRetry(
        issueId: String,
        model: String?,
        systemPrompt: String,
        tools: [Tool],
        toolOverrides: [String: Bool]? = nil
    ) async throws -> ExecutionResult {
        guard let issue = try IssueStore.getIssue(id: issueId) else {
            throw AgentEngineError.issueNotFound(issueId)
        }

        var lastError: Error?

        for attempt in 0 ..< retryConfig.maxAttempts {
            // Check for cancellation
            guard isExecuting || attempt == 0 else {
                throw AgentEngineError.cancelled
            }

            // Wait before retry (skip delay on first attempt)
            if attempt > 0 {
                let delay = retryConfig.delay(forAttempt: attempt)
                await delegate?.agentEngine(self, willRetryIssue: issue, attempt: attempt + 1, afterDelay: delay)
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }

            do {
                let result = try await execute(
                    issue: issue,
                    model: model,
                    systemPrompt: systemPrompt,
                    tools: tools,
                    toolOverrides: toolOverrides
                )

                // Success - clear any error state
                errorStates.removeValue(forKey: issueId)
                return result

            } catch let error as AgentExecutionError where error.isRetriable {
                lastError = error
                // Track error state
                errorStates[issueId] = IssueErrorState(
                    issueId: issueId,
                    error: error,
                    attemptCount: attempt + 1,
                    lastAttempt: Date(),
                    canRetry: attempt + 1 < retryConfig.maxAttempts
                )
                continue

            } catch {
                // Non-retriable error - fail immediately
                errorStates[issueId] = IssueErrorState(
                    issueId: issueId,
                    error: error,
                    attemptCount: attempt + 1,
                    lastAttempt: Date(),
                    canRetry: false
                )
                throw error
            }
        }

        // Max retries exceeded
        let finalError = AgentEngineError.maxRetriesExceeded(
            underlying: lastError ?? AgentExecutionError.unknown("Unknown error"),
            attempts: retryConfig.maxAttempts
        )
        errorStates[issueId] = IssueErrorState(
            issueId: issueId,
            error: finalError,
            attemptCount: retryConfig.maxAttempts,
            lastAttempt: Date(),
            canRetry: false
        )
        throw finalError
    }

    // MARK: - State

    /// Whether the engine is currently executing
    public func isCurrentlyExecuting() -> Bool {
        isExecuting
    }

    /// Gets the ID of the currently executing issue
    public func getCurrentIssueId() -> String? {
        currentIssueId
    }
}

// MARK: - Delegate Protocol

/// Delegate for receiving agent execution events
@MainActor
public protocol AgentEngineDelegate: AnyObject {
    func agentEngine(_ engine: AgentEngine, didStartIssue issue: Issue)
    func agentEngine(_ engine: AgentEngine, didCreatePlan plan: ExecutionPlan, forIssue issue: Issue)
    func agentEngine(_ engine: AgentEngine, willExecuteStep stepIndex: Int, step: PlanStep, forIssue issue: Issue)
    func agentEngine(_ engine: AgentEngine, didReceiveStreamingDelta delta: String, forStep stepIndex: Int)
    func agentEngine(_ engine: AgentEngine, didCompleteStep stepIndex: Int, result: StepResult, forIssue issue: Issue)
    func agentEngine(_ engine: AgentEngine, didEncounterError error: Error, forStep stepIndex: Int, issue: Issue)
    func agentEngine(_ engine: AgentEngine, didVerifyGoal verification: VerificationResult, forIssue issue: Issue)
    func agentEngine(_ engine: AgentEngine, didDecomposeIssue issue: Issue, into children: [Issue])
    func agentEngine(_ engine: AgentEngine, didCompleteIssue issue: Issue, success: Bool)
    func agentEngine(_ engine: AgentEngine, willRetryIssue issue: Issue, attempt: Int, afterDelay: TimeInterval)
}

/// Default implementations for optional delegate methods
extension AgentEngineDelegate {
    public func agentEngine(_ engine: AgentEngine, didStartIssue issue: Issue) {}
    public func agentEngine(_ engine: AgentEngine, didCreatePlan plan: ExecutionPlan, forIssue issue: Issue) {}
    public func agentEngine(
        _ engine: AgentEngine,
        willExecuteStep stepIndex: Int,
        step: PlanStep,
        forIssue issue: Issue
    ) {}
    public func agentEngine(_ engine: AgentEngine, didReceiveStreamingDelta delta: String, forStep stepIndex: Int) {}
    public func agentEngine(
        _ engine: AgentEngine,
        didCompleteStep stepIndex: Int,
        result: StepResult,
        forIssue issue: Issue
    ) {}
    public func agentEngine(_ engine: AgentEngine, didEncounterError error: Error, forStep stepIndex: Int, issue: Issue)
    {}
    public func agentEngine(
        _ engine: AgentEngine,
        didVerifyGoal verification: VerificationResult,
        forIssue issue: Issue
    ) {}
    public func agentEngine(_ engine: AgentEngine, didDecomposeIssue issue: Issue, into children: [Issue]) {}
    public func agentEngine(_ engine: AgentEngine, didCompleteIssue issue: Issue, success: Bool) {}
    public func agentEngine(_ engine: AgentEngine, willRetryIssue issue: Issue, attempt: Int, afterDelay: TimeInterval)
    {}
}

// MARK: - Errors

/// Errors that can occur in the agent engine
public enum AgentEngineError: Error, LocalizedError {
    case alreadyExecuting
    case issueNotFound(String)
    case noIssueCreated
    case taskNotFound(String)
    case maxRetriesExceeded(underlying: Error, attempts: Int)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .alreadyExecuting:
            return "Agent is already executing a task"
        case .issueNotFound(let id):
            return "Issue not found: \(id)"
        case .noIssueCreated:
            return "Failed to create initial issue for task"
        case .taskNotFound(let id):
            return "Task not found: \(id)"
        case .maxRetriesExceeded(let underlying, let attempts):
            return "Failed after \(attempts) attempts: \(underlying.localizedDescription)"
        case .cancelled:
            return "Execution was cancelled"
        }
    }

    /// Whether this error is retriable
    public var isRetriable: Bool {
        switch self {
        case .alreadyExecuting, .cancelled:
            return false
        case .issueNotFound, .noIssueCreated, .taskNotFound:
            return false
        case .maxRetriesExceeded:
            return false
        }
    }
}

/// Configuration for retry behavior
public struct RetryConfiguration: Sendable {
    /// Maximum number of retry attempts
    public let maxAttempts: Int
    /// Base delay between retries (seconds)
    public let baseDelay: TimeInterval
    /// Maximum delay between retries (seconds)
    public let maxDelay: TimeInterval
    /// Multiplier for exponential backoff
    public let backoffMultiplier: Double

    public static let `default` = RetryConfiguration(
        maxAttempts: 3,
        baseDelay: 1.0,
        maxDelay: 30.0,
        backoffMultiplier: 2.0
    )

    public static let none = RetryConfiguration(
        maxAttempts: 1,
        baseDelay: 0,
        maxDelay: 0,
        backoffMultiplier: 1.0
    )

    public init(maxAttempts: Int, baseDelay: TimeInterval, maxDelay: TimeInterval, backoffMultiplier: Double) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.backoffMultiplier = backoffMultiplier
    }

    /// Calculates delay for a given attempt number (0-indexed)
    public func delay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        let delay = baseDelay * pow(backoffMultiplier, Double(attempt - 1))
        return min(delay, maxDelay)
    }
}

/// Tracks error state for an issue
public struct IssueErrorState: Sendable {
    public let issueId: String
    public let error: Error
    public let attemptCount: Int
    public let lastAttempt: Date
    public let canRetry: Bool

    public init(issueId: String, error: Error, attemptCount: Int, lastAttempt: Date, canRetry: Bool) {
        self.issueId = issueId
        self.error = error
        self.attemptCount = attemptCount
        self.lastAttempt = lastAttempt
        self.canRetry = canRetry
    }
}
